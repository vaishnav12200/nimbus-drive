"""Search: name matching, filters, tags."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient

from tests.conftest import file_payload


async def seed(client: AsyncClient, headers: dict[str, str]) -> None:
    rows = [
        {
            "name": "Q1 Report.pdf",
            "mime_type": "application/pdf",
            "size": 5_000,
            "tags": ["work", "finance"],
        },
        {
            "name": "q2-report.pdf",
            "mime_type": "application/pdf",
            "size": 50_000,
            "tags": ["work"],
        },
        {
            "name": "holiday.jpg",
            "mime_type": "image/jpeg",
            "size": 2_000_000,
            "tags": ["personal"],
        },
        {"name": "song.mp3", "mime_type": "audio/mpeg", "size": 8_000_000},
        # Kept under 20 MB: POST /api/files only accepts client-side uploads,
        # and anything larger has to go through the backend upload path.
        {"name": "backup.zip", "mime_type": "application/zip", "size": 15_000_000},
    ]
    for index, row in enumerate(rows):
        response = await client.post(
            "/api/files",
            headers=headers,
            json=file_payload(
                telegram_message_id=index + 1, sha256=f"{index}" * 64, **row
            ),
        )
        assert response.status_code == 201, response.text


async def test_name_search_is_a_case_insensitive_substring(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await seed(client, headers)

    response = await client.get("/api/search?q=report", headers=headers)
    names = sorted(f["name"] for f in response.json()["data"])
    assert names == ["Q1 Report.pdf", "q2-report.pdf"]


async def test_wildcards_in_a_query_are_literal(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """`%` must be escaped, or any query containing one matches everything."""
    headers = bound_user["headers"]
    await seed(client, headers)

    response = await client.get("/api/search?q=%25", headers=headers)
    assert response.json()["data"] == []


async def test_filter_by_type(client: AsyncClient, bound_user: dict[str, Any]) -> None:
    headers = bound_user["headers"]
    await seed(client, headers)

    images = await client.get("/api/search?type=image", headers=headers)
    assert [f["name"] for f in images.json()["data"]] == ["holiday.jpg"]

    documents = await client.get("/api/search?type=document", headers=headers)
    assert len(documents.json()["data"]) == 2

    archives = await client.get("/api/search?type=archive", headers=headers)
    assert [f["name"] for f in archives.json()["data"]] == ["backup.zip"]


async def test_filter_by_size_range(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await seed(client, headers)

    response = await client.get(
        "/api/search?size_min=10000&size_max=3000000", headers=headers
    )
    names = sorted(f["name"] for f in response.json()["data"])
    assert names == ["holiday.jpg", "q2-report.pdf"]


async def test_inverted_size_range_is_rejected(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.get(
        "/api/search?size_min=500&size_max=100", headers=bound_user["headers"]
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_FILTERS"


async def test_tag_filter_requires_every_tag(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """`tags=work,finance` means AND, not OR."""
    headers = bound_user["headers"]
    await seed(client, headers)

    both = await client.get("/api/search?tags=work,finance", headers=headers)
    assert [f["name"] for f in both.json()["data"]] == ["Q1 Report.pdf"]

    one = await client.get("/api/search?tags=work", headers=headers)
    assert len(one.json()["data"]) == 2


async def test_json_filters_blob_is_accepted(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await seed(client, headers)

    response = await client.get('/api/search?filters={"type":["audio"]}', headers=headers)
    assert [f["name"] for f in response.json()["data"]] == ["song.mp3"]


async def test_malformed_filters_blob_is_rejected(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.get(
        "/api/search?filters=not-json", headers=bound_user["headers"]
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_FILTERS"


async def test_search_excludes_the_trash_unless_asked(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await seed(client, headers)

    target = (await client.get("/api/search?q=holiday", headers=headers)).json()["data"][
        0
    ]
    await client.delete(f"/api/files/{target['id']}", headers=headers)

    assert (await client.get("/api/search?q=holiday", headers=headers)).json()[
        "data"
    ] == []
    trashed = await client.get("/api/search?q=holiday&is_deleted=true", headers=headers)
    assert len(trashed.json()["data"]) == 1


async def test_sorting_by_size(client: AsyncClient, bound_user: dict[str, Any]) -> None:
    headers = bound_user["headers"]
    await seed(client, headers)

    response = await client.get("/api/search?sort=size&order=asc", headers=headers)
    sizes = [f["size"] for f in response.json()["data"]]
    assert sizes == sorted(sizes)


async def test_tag_listing_counts_usage(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await seed(client, headers)

    response = await client.get("/api/search/tags", headers=headers)
    counts = {row["tag"]: row["count"] for row in response.json()["data"]}
    assert counts == {"work": 2, "finance": 1, "personal": 1}
