"""G6: organisation comes from the active manifest, not host guesses."""
import asyncio

import pytest

from app.resource_models import KnowledgeSource
from app.resource_service import get_default_resource_service, search_resources
from tests.test_memory_controls import setup, auth

SOURCE_ID = 'swd-community-care-service-voucher'


@pytest.mark.parametrize('role', ['guest', 'elder', 'caregiver'])
def test_public_resource_organisation_is_manifest_bound_even_if_db_authority_drifts(setup, role):
    app, client, accounts = setup
    source = next(r for r in get_default_resource_service().records if r.id == SOURCE_ID)
    with app.state.session_factory() as db:
        row = db.get(KnowledgeSource, SOURCE_ID)
        row.source_authority = 'UNTRUSTED_DATABASE_AUTHORITY'
        db.commit()
    path = '/guest/resources/search' if role == 'guest' else '/resources/search'
    headers = {} if role == 'guest' else auth(accounts[2] if role == 'caregiver' else accounts[0])
    response = client.get(path, headers=headers, params={'query': source.search_terms[0], 'limit': 20})
    assert response.status_code == 200, response.text
    item = next(item for item in response.json()['items'] if item['id'] == SOURCE_ID)
    assert item.get('organisation') == source.source_authority
    assert item['title'] == source.title
    assert item['url'] == source.url
    assert item['verified_at'] == source.verified_at.isoformat()
    assert 'UNTRUSTED_DATABASE_AUTHORITY' not in response.text


def test_extended_resource_dto_preserves_existing_exact_source_bindings():
    source = next(r for r in get_default_resource_service().records if r.id == SOURCE_ID)
    result = asyncio.run(search_resources(None, source.search_terms[0], limit=20))
    item = next(item for item in result['items'] if item['id'] == SOURCE_ID)
    assert item.get('organisation') == source.source_authority
    assert SOURCE_ID in [binding['source_id'] for binding in result['source_bindings']]
