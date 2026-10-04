"""Explicit revision snapshots for sequential memory fixtures; never retry automatically."""

def memory_revision_headers(client, headers, *, idempotency_key=None):
    response = client.get('/memories/control-state', headers=headers)
    assert response.status_code == 200, response.text
    revision = response.json()['revision']
    assert isinstance(revision, int) and not isinstance(revision, bool)
    result = {**headers, 'X-Memory-Revision': str(revision)}
    if idempotency_key is not None:
        result['Idempotency-Key'] = idempotency_key
    return result
