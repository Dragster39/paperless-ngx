from errno import EIO
from pathlib import Path

import pytest
import pytest_mock

from documents.utils import QuerySetStream
from documents.utils import get_file_size


class TestFileSize:
    def test_returns_size_including_zero_bytes(self, tmp_path: Path) -> None:
        file = tmp_path / "document.pdf"
        file.write_bytes(b"original")
        assert get_file_size(file) == 8
        file.write_bytes(b"")
        assert get_file_size(file) == 0

    def test_missing_files_and_directories_have_no_size(self, tmp_path: Path) -> None:
        assert get_file_size(tmp_path / "missing.pdf") is None
        assert get_file_size(tmp_path) is None
        assert get_file_size(None) is None

    @pytest.mark.parametrize(
        "error",
        [
            pytest.param(PermissionError("denied"), id="permission"),
            pytest.param(OSError(EIO, "I/O error"), id="io"),
        ],
    )
    def test_inaccessible_files_have_no_size(
        self,
        tmp_path: Path,
        mocker: pytest_mock.MockerFixture,
        error: OSError,
    ) -> None:
        mocker.patch.object(Path, "stat", side_effect=error)

        assert get_file_size(tmp_path / "document.pdf") is None


class TestQuerySetStream:
    def test_len_and_iter_delegate_to_streaming_queryset_methods(
        self,
        mocker: pytest_mock.MockerFixture,
    ) -> None:
        """
        GIVEN:
            - A mock queryset
        WHEN:
            - A QuerySetStream wrapping it is measured and iterated
        THEN:
            - len() uses count() (not a materializing len()), and iteration
              uses .iterator(chunk_size=...) (not plain iteration, which
              would materialize the whole queryset, plus any prefetch
              caches, into Django's own result cache at once)
        """
        mock_queryset = mocker.MagicMock()
        mock_queryset.count.return_value = 42
        mock_queryset.iterator.return_value = iter(["row-1", "row-2"])
        streamed = QuerySetStream(mock_queryset, chunk_size=1000)

        assert len(streamed) == 42
        assert list(streamed) == ["row-1", "row-2"]
        # count.call_count isn't asserted exactly: list()'s own size-hint
        # optimization calls len(streamed) again internally, on top of the
        # explicit len() call above -- both legitimately delegate to
        # count(), so only the delegation itself (not the call count) is
        # the thing being verified here.
        mock_queryset.count.assert_called_with()
        mock_queryset.iterator.assert_called_once_with(chunk_size=1000)
