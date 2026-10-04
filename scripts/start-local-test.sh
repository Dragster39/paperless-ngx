#!/usr/bin/env bash
# Disposable local instance: Enter, Ctrl+C, or a startup failure cleans it up.
# Usage: ./scripts/start-local-test.sh [--check]
# Requires .venv, src-ui/node_modules, Redis/Valkey, Tesseract and Ghostscript.
# Reuses installed dependencies; deletes only this run's temporary instance.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -x "$repo_dir/.venv/bin/python" ]]; then
  echo "Missing .venv. Run: uv sync --frozen --no-default-groups --group testing" >&2
  exit 1
fi

exec "$repo_dir/.venv/bin/python" - "$repo_dir" "$@" <<'PY'
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import secrets
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


class StopRequested(Exception):
    pass


class Supervisor:
    def __init__(self, env: dict[str, str], root: Path):
        self.env = env
        self.root = root
        self.children: list[tuple[str, subprocess.Popen, Path]] = []
        self.stopping = False

    def request_stop(self, signum, frame):
        # Do not raise inside Popen: register every child before reacting.
        self.stopping = True

    def check(self):
        if self.stopping:
            raise StopRequested
        for name, process, log in self.children:
            if process.poll() is not None:
                raise RuntimeError(f"{name} exited unexpectedly. Log: {log}")

    def start(self, name: str, command: list[str], cwd: Path):
        self.check()
        log = self.root / f"{name}.log"
        with log.open("wb") as output:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                env=self.env,
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        self.children.append((name, process, log))
        return process

    def run(self, name: str, command: list[str], cwd: Path):
        process = self.start(name, command, cwd)
        while process.poll() is None:
            if self.stopping:
                raise StopRequested
            time.sleep(0.1)
        if process.returncode:
            raise RuntimeError(f"{name} failed; see {self.root / (name + '.log')}")
        self.children = [child for child in self.children if child[1] is not process]

    def wait_for(self, name: str, ready, timeout: float = 180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.check()
            if ready():
                return
            time.sleep(0.25)
        raise RuntimeError(f"Timed out waiting for {name}.")

    def stop(self):
        # A process group also contains OCR tools, Node workers, and other children.
        groups = [process.pid for _, process, _ in reversed(self.children)]

        def send(group, sig):
            try:
                os.killpg(group, sig)
                return True
            except ProcessLookupError:
                return False

        for group in groups:
            send(group, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while groups and time.monotonic() < deadline:
            for _, process, _ in self.children:
                process.poll()  # Reap direct children before checking their groups.
            groups = [group for group in groups if send(group, 0)]
            if groups:
                time.sleep(0.1)
        for group in groups:
            send(group, signal.SIGKILL)
        for _, process, _ in self.children:
            process.wait()


def http_ready(url: str) -> bool:
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=1) as response:
            return response.status < 500
    except urllib.error.HTTPError as error:
        return error.code < 500
    except (OSError, urllib.error.URLError):
        return False


def broker_ready(path: Path) -> bool:
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(1)
            connection.connect(str(path))
            connection.sendall(b"*1\r\n$4\r\nPING\r\n")
            return connection.recv(64).startswith(b"+PONG")
    except OSError:
        return False


def prerequisites(repo: Path):
    broker = shutil.which("valkey-server") or shutil.which("redis-server")
    node = shutil.which("node")
    missing = [name for name in ("tesseract", "gs") if not shutil.which(name)]
    if not broker:
        missing.append("redis-server or valkey-server (macOS: brew install redis)")
    if not node:
        missing.append("Node.js 24+")
    if not (repo / "src-ui/node_modules/@angular/cli/bin/ng.js").is_file():
        missing.append("frontend dependencies (cd src-ui && pnpm install --frozen-lockfile)")
    for module in ("django", "celery", "daphne"):
        if importlib.util.find_spec(module) is None:
            missing.append(f"Python dependency {module} (uv sync --frozen --no-default-groups --group testing)")
    try:
        import magic
    except (ImportError, OSError):
        missing.append("libmagic (macOS: brew install libmagic)")
    if missing:
        raise RuntimeError("Missing prerequisites:\n  - " + "\n  - ".join(missing))
    return broker, node


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="scripts/start-local-test.sh",
        description="Start a disposable local Paperless instance; Enter or Ctrl+C stops and deletes it.",
    )
    parser.add_argument("--check", action="store_true", help="Check prerequisites only; start no services.")
    args = parser.parse_args(sys.argv[2:])
    repo = Path(sys.argv[1])
    try:
        broker, node = prerequisites(repo)
        if args.check:
            print("Prerequisites available. No services started.")
            return 0
        # The heredoc occupies stdin, so read the interactive terminal directly.
        terminal = open("/dev/tty", "r")
        for port in (8000, 4200):
            with socket.socket() as probe:
                try:
                    probe.bind(("127.0.0.1", port))
                except OSError as error:
                    raise RuntimeError(f"Port {port} is already in use; stop that service first.") from error
    except (RuntimeError, OSError) as error:
        print(error, file=sys.stderr)
        return 1

    # /tmp keeps the Unix socket below macOS's socket-path length limit.
    with terminal, tempfile.TemporaryDirectory(prefix="paperless-test-", dir="/tmp") as directory:
        root = Path(directory)
        env = {key: value for key, value in os.environ.items() if not key.startswith("PAPERLESS_")}
        paths = {
            "PAPERLESS_DATA_DIR": root / "data",
            "PAPERLESS_MEDIA_ROOT": root / "media",
            "PAPERLESS_CONSUMPTION_DIR": root / "consume",
            "PAPERLESS_SCRATCH_DIR": root / "scratch",
            "PAPERLESS_LOGGING_DIR": root / "logs",
            "PAPERLESS_STATICDIR": root / "static",
        }
        for key, path in paths.items():
            path.mkdir()
            env[key] = str(path)
        for folder in (
            "data/index",
            "media/documents/originals",
            "media/documents/archive",
            "media/documents/thumbnails",
            "broker",
            "tmp",
        ):
            (root / folder).mkdir(parents=True, exist_ok=True)
        config = root / "paperless.conf"
        config.touch()  # Takes precedence over any existing paperless.conf.
        password = secrets.token_urlsafe(18)
        env.update({
            "PAPERLESS_CONFIGURATION_PATH": str(config),
            "PAPERLESS_DBENGINE": "sqlite",
            "PAPERLESS_DEBUG": "true",
            "PAPERLESS_SECRET_KEY": secrets.token_urlsafe(64),
            "PAPERLESS_REDIS": f"unix://{root / 'redis.sock'}",
            "PAPERLESS_AI_ENABLED": "false",
            "PAPERLESS_CACHE_BACKEND": "django.core.cache.backends.redis.RedisCache",
            "PAPERLESS_TASK_WORKERS": "1",
            "PAPERLESS_THREADS_PER_WORKER": "1",
            "PAPERLESS_OCR_LANGUAGE": "eng",
            "PAPERLESS_CONVERT_TMPDIR": str(root / "scratch"),
            "DJANGO_SETTINGS_MODULE": "paperless.settings",
            "DJANGO_SUPERUSER_USERNAME": "tester",
            "DJANGO_SUPERUSER_EMAIL": "",
            "DJANGO_SUPERUSER_PASSWORD": password,
            "TMPDIR": str(root / "tmp"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
            "NG_CLI_ANALYTICS": "false",
        })
        supervisor = Supervisor(env, root)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, supervisor.request_stop)
        result = 0
        try:
            print(f"Preparing temporary instance: {root}", flush=True)
            # Snapshot the UI source so its generated files/cache also stay temporary.
            ui = root / "ui"
            shutil.copytree(repo / "src-ui", ui, ignore=shutil.ignore_patterns(
                "node_modules", ".angular", ".pnpm-store", ".cache", ".git",
                "dist", "coverage", "e2e",
                "playwright-report", "test-results", "junit.xml",
            ))
            (ui / "node_modules").symlink_to(repo / "src-ui/node_modules", target_is_directory=True)
            angular_path = ui / "angular.json"
            angular = json.loads(angular_path.read_text())
            angular.setdefault("cli", {})["cache"] = {"enabled": True, "path": str(root / "angular-cache")}
            angular_path.write_text(json.dumps(angular))
            python = sys.executable
            source = repo / "src"
            supervisor.start("broker", [
                broker, "--port", "0",
                "--unixsocket", str(root / "redis.sock"), "--unixsocketperm", "700",
                "--save", "", "--appendonly", "no", "--daemonize", "no",
                "--dir", str(root / "broker"),
            ], root)
            supervisor.wait_for("broker", lambda: broker_ready(root / "redis.sock"), timeout=15)
            supervisor.run("migrate", [python, "manage.py", "migrate", "--noinput"], source)
            supervisor.run("create-user", [python, "manage.py", "createsuperuser", "--noinput"], source)
            # No longer expose the login password to the long-running services.
            env.pop("DJANGO_SUPERUSER_PASSWORD")
            supervisor.start("worker", [
                python, "-m", "celery", "--app", "paperless", "worker",
                "--pool", "solo", "--concurrency", "1", "--loglevel", "INFO",
            ], source)
            supervisor.start("backend", [
                python, "-m", "daphne", "--bind", "127.0.0.1", "--port", "8000",
                "paperless.asgi:application",
            ], source)
            supervisor.start("frontend", [
                node, str(ui / "node_modules/@angular/cli/bin/ng.js"),
                "serve", "--host", "127.0.0.1", "--port", "4200",
            ], ui)
            supervisor.wait_for("backend", lambda: http_ready("http://127.0.0.1:8000/api/"))
            supervisor.wait_for("worker", lambda: " ready." in (root / "worker.log").read_text(errors="replace"))
            supervisor.wait_for("frontend", lambda: http_ready("http://127.0.0.1:4200/"))
            print(f"\nOpen http://localhost:4200\nUsername: tester\nPassword: {password}\n\nUpload a document and test the display fields.\nPress Enter or Ctrl+C to stop and DELETE all test data.\nLogs while running: {root}", flush=True)
            while True:
                supervisor.check()
                readable, _, _ = select.select([terminal], [], [], 0.25)
                if readable:
                    terminal.readline()
                    break
        except StopRequested:
            pass
        except Exception as error:
            result = 1
            print(f"\nStartup/session failed: {error}", file=sys.stderr)
            # Show diagnostics before the temporary logs are deleted.
            for log in sorted(root.glob("*.log")):
                lines = log.read_text(errors="replace").splitlines()[-15:]
                if lines:
                    print(f"\n--- {log.name} ---\n" + "\n".join(lines), file=sys.stderr)
        finally:
            print("\nStopping processes and removing temporary data...", flush=True)
            supervisor.stop()
    print("Stopped. Temporary instance and test documents removed.", flush=True)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
PY
