"""Folder tree: materialized paths, cycles, and delete semantics."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient


async def make_folder(
    client: AsyncClient, headers: dict[str, str], name: str, parent_id: str | None = None
) -> dict[str, Any]:
    response = await client.post(
        "/api/folders",
        headers=headers,
        json={"name": name, "parent_id": parent_id},
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def test_root_folder_gets_a_leading_slash_path(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    folder = await make_folder(client, headers, "Documents")
    assert folder["path"] == "/Documents"
    assert folder["parent_id"] is None


async def test_nested_paths_are_materialized(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    documents = await make_folder(client, headers, "Documents")
    work = await make_folder(client, headers, "Work", documents["id"])
    year = await make_folder(client, headers, "2026", work["id"])

    assert year["path"] == "/Documents/Work/2026"


async def test_moving_a_folder_repaths_every_descendant(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    """The whole point of a materialized path: a move must fix the subtree."""
    documents = await make_folder(client, headers, "Documents")
    work = await make_folder(client, headers, "Work", documents["id"])
    year = await make_folder(client, headers, "2026", work["id"])
    invoices = await make_folder(client, headers, "Invoices", year["id"])
    archive = await make_folder(client, headers, "Archive")

    moved = await client.patch(
        f"/api/folders/{work['id']}",
        headers=headers,
        json={"parent_id": archive["id"]},
    )
    assert moved.status_code == 200
    assert moved.json()["data"]["path"] == "/Archive/Work"

    tree = await client.get("/api/folders?tree=true", headers=headers)
    paths = {f["id"]: f["path"] for f in tree.json()["data"]}
    assert paths[year["id"]] == "/Archive/Work/2026"
    assert paths[invoices["id"]] == "/Archive/Work/2026/Invoices"


async def test_renaming_a_folder_repaths_descendants(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    parent = await make_folder(client, headers, "Photos")
    child = await make_folder(client, headers, "2025", parent["id"])

    await client.patch(
        f"/api/folders/{parent['id']}", headers=headers, json={"name": "Pictures"}
    )

    tree = await client.get("/api/folders?tree=true", headers=headers)
    paths = {f["id"]: f["path"] for f in tree.json()["data"]}
    assert paths[parent["id"]] == "/Pictures"
    assert paths[child["id"]] == "/Pictures/2025"


async def test_a_folder_cannot_be_moved_into_itself(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    folder = await make_folder(client, headers, "Loop")
    response = await client.patch(
        f"/api/folders/{folder['id']}", headers=headers, json={"parent_id": folder["id"]}
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "FOLDER_CYCLE"


async def test_a_folder_cannot_be_moved_into_its_own_descendant(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    """Without this guard the subtree detaches from the root and the path
    rewrite has no terminating condition."""
    parent = await make_folder(client, headers, "Parent")
    child = await make_folder(client, headers, "Child", parent["id"])
    grandchild = await make_folder(client, headers, "Grandchild", child["id"])

    response = await client.patch(
        f"/api/folders/{parent['id']}",
        headers=headers,
        json={"parent_id": grandchild["id"]},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "FOLDER_CYCLE"


async def test_moving_to_null_parent_returns_a_folder_to_the_root(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    parent = await make_folder(client, headers, "Parent")
    child = await make_folder(client, headers, "Child", parent["id"])

    response = await client.patch(
        f"/api/folders/{child['id']}", headers=headers, json={"parent_id": None}
    )
    assert response.status_code == 200
    assert response.json()["data"]["path"] == "/Child"
    assert response.json()["data"]["parent_id"] is None


async def test_sibling_names_must_be_unique(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    await make_folder(client, headers, "Duplicate")
    response = await client.post(
        "/api/folders", headers=headers, json={"name": "Duplicate"}
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "FOLDER_NAME_TAKEN"


async def test_same_name_is_fine_under_different_parents(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    a = await make_folder(client, headers, "A")
    b = await make_folder(client, headers, "B")
    await make_folder(client, headers, "Shared", a["id"])
    second = await client.post(
        "/api/folders", headers=headers, json={"name": "Shared", "parent_id": b["id"]}
    )
    assert second.status_code == 201


async def test_names_with_slashes_are_rejected(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    """A slash in a name would corrupt every materialized path built from it."""
    response = await client.post(
        "/api/folders", headers=headers, json={"name": "bad/name"}
    )
    assert response.status_code == 422


async def test_delete_is_restrict_by_default(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    parent = await make_folder(client, headers, "Parent")
    await make_folder(client, headers, "Child", parent["id"])

    response = await client.delete(f"/api/folders/{parent['id']}", headers=headers)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "FOLDER_NOT_EMPTY"
    assert response.json()["error"]["details"]["subfolder_count"] == 1


async def test_cascade_delete_removes_the_subtree(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    parent = await make_folder(client, headers, "Parent")
    child = await make_folder(client, headers, "Child", parent["id"])

    response = await client.delete(
        f"/api/folders/{parent['id']}?cascade=true", headers=headers
    )
    assert response.status_code == 200

    assert (
        await client.get(f"/api/folders/{child['id']}", headers=headers)
    ).status_code == 404


async def test_breadcrumbs_walk_from_the_root(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    a = await make_folder(client, headers, "A")
    b = await make_folder(client, headers, "B", a["id"])
    c = await make_folder(client, headers, "C", b["id"])

    detail = await client.get(f"/api/folders/{c['id']}", headers=headers)
    trail = [entry["name"] for entry in detail.json()["data"]["breadcrumbs"]]
    assert trail == ["A", "B"]


async def test_listing_defaults_to_the_root_level(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    top = await make_folder(client, headers, "Top")
    await make_folder(client, headers, "Nested", top["id"])

    response = await client.get("/api/folders", headers=headers)
    names = [f["name"] for f in response.json()["data"]]
    assert names == ["Top"]
