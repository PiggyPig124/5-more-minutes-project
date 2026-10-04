from datetime import datetime, timezone, timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from app.community_search import CommunitySearch, PROVIDERS, CACHE_SECONDS
from app.smartplay_community_search import SmartPlayCommunitySearch
from app.config import Settings
from app.main import create_app


@pytest.mark.parametrize('demo', [True, False])
def test_disabled_sources_have_explicit_reason_without_fetch(monkeypatch, demo):
    def forbidden(*args, **kwargs):
        pytest.fail('Disabled source must not be fetched')
    monkeypatch.setattr(CommunitySearch, '_fetch', forbidden)
    app = create_app(Settings(database_url='sqlite:///:memory:', auth_secret='synthetic-status', demo_mode=demo))
    app.state.community_search = SmartPlayCommunitySearch(enabled=False)
    client = TestClient(app)
    try:
        response = client.get('/community/activities', params={'area': '深水埗'})
        assert response.status_code == 200
        body = response.json()
        assert body['search_reason'] == 'sources_disabled'
        assert body['sources'] == [] and body['items'] == []
        assert body['checked_at'] is None
        assert 'not enabled' in body['message']
    finally:
        client.close()
        app.state.engine.dispose()


@pytest.mark.parametrize('failure, expected', [
    ('timeout', 'source_unavailable'),
    ('http503', 'source_unavailable'),
    ('markup', 'parse_failed'),
    ('content_type', 'parse_failed'),
])
def test_provider_failure_reason_is_structured(failure, expected):
    def handler(request):
        if failure == 'timeout':
            raise httpx.ReadTimeout('synthetic timeout', request=request)
        if failure == 'http503':
            return httpx.Response(503)
        return httpx.Response(200, headers={'content-type': 'application/json' if failure == 'content_type' else 'text/html'}, text='<html>changed structure</html>')
    result = CommunitySearch(providers=(PROVIDERS[0],), transport=httpx.MockTransport(handler)).search(listing_type='activity')
    assert result['search_state'] == 'unavailable'
    assert result['search_reason'] == expected
    assert result['sources'][0]['error_kind'] == expected
    assert result['checked_at'] is None and result['items'] == []


def test_successful_no_match_is_not_source_failure():
    body = '<div class="col-md-offset-1"><h3>合成縫紉班</h3><table><tr><td>日期:</td><td>2099-10-01</td></tr><tr><td>內容:</td><td>sewing</td></tr><tr><td>時間:</td><td>Sham Shui Po</td></tr></table></div>'
    service = CommunitySearch(providers=(PROVIDERS[0],), transport=httpx.MockTransport(lambda request: httpx.Response(200, headers={'content-type': 'text/html'}, text=body)))
    result = service.search(listing_type='activity', topic='health', area='深水埗')
    assert result['search_state'] == 'live'
    assert result['search_reason'] == 'no_matches'
    assert result['sources'][0]['error_kind'] is None
    assert result['checked_at'] is not None and result['items'] == []
    matched = service.search(listing_type='activity', topic='sewing', area='深水埗')
    assert len(matched['items']) == 1
    assert matched['search_reason'] is None


def test_stale_cache_keeps_original_timestamp_and_failure_kind():
    service = CommunitySearch(providers=(PROVIDERS[0],), transport=httpx.MockTransport(lambda request: httpx.Response(503)))
    checked = datetime.now(timezone.utc) - timedelta(seconds=CACHE_SECONDS + 10)
    service._cache[PROVIDERS[0].name] = (checked, [])
    result = service.search(listing_type='activity')
    assert result['search_state'] == 'cache'
    assert result['search_reason'] == 'stale_cache'
    assert result['checked_at'] == checked
    assert result['sources'][0]['error_kind'] == 'source_unavailable'
