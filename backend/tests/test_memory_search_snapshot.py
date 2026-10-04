"""Synthetic delayed retrieval must not return withdrawn source snapshots."""
import asyncio
from concurrent.futures import ThreadPoolExecutor

import pytest

from app.routers import memories
from tests.test_memory_controls import setup, auth, enable, save, state


@pytest.mark.parametrize("withdrawal", ["delete", "consent_off"])
def test_search_rejects_source_snapshot_changed_before_return(setup, monkeypatch, withdrawal):
    _, client, (owner, _, _) = setup
    enable(client, owner)
    source = save(client, owner, "Private garden source that must not return")
    revision = state(client, owner)["revision"]
    mutation_headers = {**auth(owner), "X-Memory-Revision": str(revision)}
    mutation_status = []

    def withdraw():
        if withdrawal == "delete":
            response = client.post("/memories/deletions", headers=auth(owner), json={
                "mode": "all", "memory_ids": [], "expected_revision": revision,
                "idempotency_key": "withdraw-during-retrieval"})
        else:
            response = client.put("/memories/consent", headers=mutation_headers,
                                  json={"enabled": False})
        mutation_status.append(response.status_code)

    async def delayed_retrieval(*_args, **_kwargs):
        # The source payload has already been built; withdraw it in an
        # independent request before the search route labels/returns it.
        result = {"items": [{**source, "score": 1.0}], "retrieval_mode": "keyword"}
        with ThreadPoolExecutor(max_workers=1) as pool:
            await asyncio.wrap_future(pool.submit(withdraw))
        return result

    monkeypatch.setattr(memories, "retrieve_for_chat", delayed_retrieval)
    response = client.post("/memories/search", headers=auth(owner),
                           json={"query": "garden"})
    assert mutation_status == [200]
    assert state(client, owner)["revision"] > revision
    assert response.status_code == 409, response.text
    assert source["content"] not in response.text
