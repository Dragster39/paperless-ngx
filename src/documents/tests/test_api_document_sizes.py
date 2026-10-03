from __future__ import annotations

from typing import TYPE_CHECKING

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework import status

from documents.models import Document
from documents.serialisers import DocumentSerializer
from documents.serialisers import SearchResultSerializer
from paperless_testing.factories import DocumentFactory

if TYPE_CHECKING:
    from pytest_mock import MockerFixture
    from rest_framework.test import APIClient


@pytest.mark.django_db
@pytest.mark.usefixtures("paperless_dirs")
class TestDocumentSizes:
    @pytest.mark.parametrize(
        ("original", "archive"),
        [(b"original", b"larger archive"), (b"", b""), (b"original", None)],
    )
    def test_sizes_match_metadata(
        self,
        admin_client: APIClient,
        mocker: MockerFixture,
        original: bytes,
        archive: bytes | None,
    ) -> None:
        doc = DocumentFactory(
            mime_type="application/pdf",
            filename="original.pdf",
            archive_filename="archive.pdf" if archive is not None else None,
        )
        doc.source_path.write_bytes(original)
        if archive is not None:
            assert doc.archive_path is not None
            doc.archive_path.write_bytes(archive)
        mocker.patch("documents.views.DocumentViewSet.get_metadata", return_value=[])

        metadata = admin_client.get(f"/api/documents/{doc.pk}/metadata/")
        detail = admin_client.get(f"/api/documents/{doc.pk}/")
        listing = admin_client.get(
            "/api/documents/?fields=id,original_size,archive_size",
        )

        assert metadata.status_code == status.HTTP_200_OK
        assert detail.status_code == status.HTTP_200_OK
        assert listing.status_code == status.HTTP_200_OK
        for field, expected in (
            ("original_size", len(original)),
            ("archive_size", len(archive) if archive is not None else None),
        ):
            assert metadata.data[field] == expected
            assert detail.data[field] == expected
            assert listing.data["results"][0][field] == expected

    def test_missing_files_return_null(self, admin_client: APIClient) -> None:
        doc = DocumentFactory(filename="missing.pdf", archive_filename="missing.pdf")

        response = admin_client.get(f"/api/documents/{doc.pk}/")

        assert response.status_code == status.HTTP_200_OK
        assert response.data["original_size"] is None
        assert response.data["archive_size"] is None

    def test_sizes_follow_version_index_and_explicit_version(
        self,
        admin_client: APIClient,
        mocker: MockerFixture,
    ) -> None:
        root = DocumentFactory(
            mime_type="application/pdf",
            filename="root.pdf",
            archive_filename="root-archive.pdf",
        )
        newest = DocumentFactory(
            mime_type="application/pdf",
            root_document=root,
            version_index=2,
            filename="newest.pdf",
            archive_filename="newest-archive.pdf",
        )
        older = DocumentFactory(
            mime_type="application/pdf",
            root_document=root,
            version_index=1,
            filename="older.pdf",
            archive_filename=None,
        )
        contents = ((root, b"root"), (newest, b"newest file"), (older, b"old"))
        for doc, content in contents:
            doc.source_path.write_bytes(content)
        assert root.archive_path is not None
        assert newest.archive_path is not None
        root.archive_path.write_bytes(b"root archive")
        newest.archive_path.write_bytes(b"newest archive file")
        mocker.patch("documents.views.DocumentViewSet.get_metadata", return_value=[])

        listing = admin_client.get(
            "/api/documents/?fields=id,original_size,archive_size",
        )
        assert listing.status_code == status.HTTP_200_OK
        assert listing.data["results"] == [
            {"id": root.pk, "original_size": 11, "archive_size": 19},
        ]
        for suffix, expected in (
            ("", (11, 19)),
            (f"?version={root.pk}", (4, 12)),
            (f"?version={older.pk}", (3, None)),
        ):
            detail = admin_client.get(f"/api/documents/{root.pk}/{suffix}")
            metadata = admin_client.get(f"/api/documents/{root.pk}/metadata/{suffix}")
            assert detail.status_code == status.HTTP_200_OK
            assert metadata.status_code == status.HTTP_200_OK
            assert (
                detail.data["original_size"],
                detail.data["archive_size"],
            ) == expected
            assert (
                metadata.data["original_size"],
                metadata.data["archive_size"],
            ) == expected

        # The size-only fieldset must still resolve an explicitly requested version.
        response = admin_client.get(
            f"/api/documents/{root.pk}/?version={older.pk}"
            "&fields=original_size,archive_size",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data == {"original_size": 3, "archive_size": None}

    def test_excluded_sizes_do_not_access_files(
        self,
        admin_client: APIClient,
        mocker: MockerFixture,
    ) -> None:
        doc = DocumentFactory()
        filesize = mocker.patch("documents.serialisers.get_file_size")

        listing = admin_client.get("/api/documents/?fields=id,title")
        detail = admin_client.get(f"/api/documents/{doc.pk}/?fields=id,title")

        assert listing.status_code == status.HTTP_200_OK
        assert detail.status_code == status.HTTP_200_OK
        assert "original_size" not in detail.data
        assert "archive_size" not in detail.data
        filesize.assert_not_called()

    def test_sizes_are_read_only(self, admin_client: APIClient) -> None:
        doc = DocumentFactory(mime_type="application/pdf", filename="original.pdf")
        doc.source_path.write_bytes(b"original")

        response = admin_client.patch(
            f"/api/documents/{doc.pk}/",
            {"original_size": 999, "archive_size": 999},
            format="json",
        )

        assert response.status_code == status.HTTP_200_OK
        assert response.data["original_size"] == 8
        assert response.data["archive_size"] is None

    @pytest.mark.parametrize("search_results", [False, True])
    def test_version_file_queries_are_batched(
        self,
        mocker: MockerFixture,
        search_results: bool,  # noqa: FBT001
    ) -> None:
        roots = [DocumentFactory() for _ in range(3)]
        for root in roots:
            DocumentFactory(root_document=root, version_index=1)
        mocker.patch("documents.serialisers.get_file_size", return_value=123)
        mocker.patch.object(
            DocumentSerializer,
            "get_shared_object_pks",
            return_value=set(),
        )

        def serialize(documents: list[Document]) -> list:
            fields = ["id", "original_size", "archive_size", "content"]
            if search_results:
                hits = [
                    {"id": doc.pk, "score": 1.0, "rank": i}
                    for i, doc in enumerate(documents)
                ]
                return SearchResultSerializer(hits, many=True, fields=fields).data
            queryset = Document.objects.filter(pk__in=[doc.pk for doc in documents])
            return DocumentSerializer(queryset, many=True, fields=fields).data

        with CaptureQueriesContext(connection) as single_queries:
            single = serialize(roots[:1])
        with CaptureQueriesContext(connection) as multiple_queries:
            multiple = serialize(roots)

        assert len(single) == 1
        assert len(multiple) == 3
        assert all(doc["original_size"] == 123 for doc in multiple)
        assert len(multiple_queries) == len(single_queries)

    def test_saved_view_accepts_and_retains_size_fields(
        self,
        admin_client: APIClient,
    ) -> None:
        response = admin_client.post(
            "/api/saved_views/",
            {
                "name": "File sizes",
                "filter_rules": [],
                "display_fields": ["title", "original_size", "archive_size"],
            },
            format="json",
        )

        assert response.status_code == status.HTTP_201_CREATED
        saved = admin_client.get(f"/api/saved_views/{response.data['id']}/")
        assert saved.status_code == status.HTTP_200_OK
        assert saved.data["display_fields"] == [
            "title",
            "original_size",
            "archive_size",
        ]
