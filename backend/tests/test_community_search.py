from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx
from fastapi.testclient import TestClient
from pathlib import Path

from app.community_search import CACHE_SECONDS, CommunitySearch, PROVIDERS, _hkcmis, _jcvt, explicit_community_query, topic_from_query
from app.config import Settings
from app.main import create_app


def test_hkcmis_extracts_visible_dates_filters_expired_and_marks_not_guaranteed() -> None:
    html = """
    <div class="col-md-offset-1"><h3>中心書法班</h3><table>
    <tr><td>日期:</td><td>2026-09-01 至 2026-10-12</td></tr>
    <tr><td>時間:</td><td>灣仔中心</td></tr><tr><td>內容:</td><td>書法練習</td></tr>
    </table></div>
    <div class="col-md-offset-1"><h3>舊活動</h3><table>
    <tr><td>日期:</td><td>2026-07-01 至 2026-08-01</td></tr>
    </table></div>
    """
    rows = _hkcmis(html, datetime(2026, 9, 27, tzinfo=timezone.utc))
    assert [row["title"] for row in rows] == ["中心書法班"]
    assert rows[0]["event_start_at"].isoformat().startswith("2026-09-01T00:00:00+08:00")
    assert rows[0]["verified"] is False
    assert "not guaranteed" in rows[0]["availability_note"]


def test_default_app_does_not_fetch_unapproved_community_sources(tmp_path: Path) -> None:
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path / 'no-sources.db'}", auth_secret="no-sources-test", demo_mode=True))
    assert app.state.community_search.providers == ()
    with TestClient(app) as client:
        response = client.get("/community/activities")
        assert response.status_code == 200
        assert response.json()["search_state"] == "unavailable"
        assert response.json()["items"] == []


def test_jcvt_extracts_visible_cards_and_does_not_execute_embedded_scripts() -> None:
    card = """
    <script>window.fake='ignore'</script>
    <a href="/zh/volunteer-opportunities/latest/01234567-89ab-cdef-0123-456789abcdef">
      <p class="line-clamp-3 body-1-d font-bold">協助烹飪班</p>
      <div class="body-2-d text-black-900 line-clamp-1">社區中心</div>
      <div class="body-2-d text-black-900 line-clamp-1">08/10/2026 - 08/10/2026</div>
      <div class="body-2-d text-black-900 line-clamp-1">灣仔</div>
    </a>
    """
    rows = _jcvt(card, datetime(2026, 9, 27, tzinfo=timezone.utc))
    assert len(rows) == 1
    assert rows[0]["title"] == "協助烹飪班"
    assert rows[0]["organization"] == "社區中心"
    assert rows[0]["area"] == "灣仔"
    assert rows[0]["listing_type"] == "opportunity"
    assert rows[0]["event_end_at"].hour == 23
    assert rows[0]["registration_url"].startswith("https://www.jcvtplatform.hk/zh/volunteer-opportunities/latest/")


def test_bounded_fixed_provider_fetch_cache_and_failure_do_not_advance_checked_time() -> None:
    body = '<div class="col-md-offset-1"><h3>書法活動</h3><table><tr><td>日期:</td><td>2026-09-28</td></tr><tr><td>內容:</td><td>書法練習</td></tr></table></div>'.encode()
    calls: list[str] = []
    unavailable = False

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        if unavailable:
            return httpx.Response(503)
        return httpx.Response(200, headers={"content-type": "text/html; charset=utf-8"}, content=body)

    service = CommunitySearch(providers=(PROVIDERS[0],), transport=httpx.MockTransport(handler))
    live = service.search(listing_type="activity", topic="health")
    assert live["search_state"] == "live"
    assert live["no_results"] is True
    assert live["sources"][0]["state"] == "live"
    cached = service.search(listing_type="activity", topic="health")
    assert cached["search_state"] == "cache"
    assert cached["checked_at"] == live["checked_at"]
    assert len(calls) == 1
    assert "topic" not in calls[0]  # private/user query terms are local filters only
    cached_at = live["checked_at"] - timedelta(seconds=CACHE_SECONDS + 1)
    service._cache[PROVIDERS[0].name] = (cached_at, service._cache[PROVIDERS[0].name][1])
    unavailable = True
    stale = service.search(listing_type="activity")
    assert stale["search_state"] == "cache"
    assert stale["checked_at"] == cached_at
    assert stale["sources"][0]["error"] == "Provider returned HTTP 503"
    assert len(calls) == 2


def test_redirects_are_not_followed_and_unavailable_cache_has_honest_timestamp() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(302, headers={"location": "http://127.0.0.1/admin"})

    service = CommunitySearch(providers=(PROVIDERS[0],), transport=httpx.MockTransport(handler))
    response = service.search(listing_type="activity")
    assert response["search_state"] == "unavailable"
    assert response["checked_at"] is None
    assert response["sources"][0]["state"] == "unavailable"
    assert calls == 1


def test_conversation_community_trigger_is_explicit_and_topic_is_generalized() -> None:
    assert explicit_community_query("Can you find cooking activities near me?")
    assert topic_from_query("Can you find cooking activities?") == "cooking"
    assert explicit_community_query("幫我搵附近的義工機會")
    assert not explicit_community_query("I used to teach sewing for many years.")


def test_guest_chat_returns_source_metadata_only_for_explicit_search(tmp_path: Path) -> None:
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path / 'chat.db'}", auth_secret="community-chat-test", demo_mode=True))

    class SearchStub:
        calls = 0

        def search(self, *, listing_type: str, topic: str | None = None, area: str | None = None) -> dict:
            self.calls += 1
            return {
                "items": [{
                    "id": "public-test", "title": "社區書法班", "summary": "書法練習", "organization": "社區中心",
                    "area": "灣仔", "event_start_at": "2026-10-01T00:00:00+08:00", "event_end_at": "2026-10-31T23:59:59+08:00",
                    "date_text": "2026-10-01 至 2026-10-31", "eligibility": None, "source_name": "測試來源",
                    "source_url": "https://example.org/activity", "registration_url": None,
                    "last_checked_at": "2026-09-27T00:00:00Z", "listing_type": listing_type,
                    "verified": False, "availability_note": "請向機構查詢名額。",
                }], "no_results": False, "message": None, "search_state": "live",
                "checked_at": "2026-09-27T00:00:00Z", "requested_at": "2026-09-27T00:00:01Z",
                "sources": [{"name": "測試來源", "url": "https://example.org/activity", "state": "live", "checked_at": "2026-09-27T00:00:00Z", "error": None}],
            }

    stub = SearchStub()
    app.state.community_search = stub
    with TestClient(app) as client:
        session = client.post("/guest/sessions").json()["session_id"]
        ordinary = client.post(f"/guest/sessions/{session}/messages", json={"content": "I used to teach sewing."}).json()
        assert "community_sources" not in ordinary
        assert stub.calls == 0
        found = client.post(f"/guest/sessions/{session}/messages", json={"content": "Can you find a cooking class?"})
        assert found.status_code == 200, found.text
        response = found.json()
        assert response["community_search_state"] == "live"
        assert response["community_sources"][0]["name"] == "測試來源"
        assert response["community_results"][0]["verified"] is False
        assert "社區書法班" in response["reply"]
        assert stub.calls == 1


def test_authenticated_community_chat_persists_datetime_provenance(tmp_path: Path) -> None:
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path / 'authenticated.db'}", auth_secret="community-chat-test", demo_mode=True))
    checked_at = datetime.now(timezone.utc)

    class SearchStub:
        def search(self, *, listing_type: str, topic: str | None = None, area: str | None = None) -> dict:
            return {
                "items": [{
                    "id": "public-test", "title": "社區書法班", "summary": "書法練習", "organization": "社區中心",
                    "area": "灣仔", "event_start_at": checked_at, "event_end_at": checked_at,
                    "date_text": "2026-10-01", "eligibility": None, "source_name": "測試來源",
                    "source_url": "https://example.org/activity", "registration_url": None,
                    "last_checked_at": checked_at, "listing_type": listing_type,
                    "verified": False, "availability_note": "請向機構查詢名額。",
                }], "no_results": False, "message": None, "search_state": "live",
                "checked_at": checked_at, "requested_at": checked_at,
                "sources": [{"name": "測試來源", "url": "https://example.org/activity", "state": "live", "checked_at": checked_at, "error": None}],
            }

    app.state.community_search = SearchStub()
    with TestClient(app) as client:
        registered = client.post("/auth/register", json={
            "email": "community-chat@example.test", "password": "correct horse battery", "display_name": "Test", "role": "elder",
        })
        assert registered.status_code == 201
        headers = {"Authorization": f"Bearer {registered.json()['access_token']}"}
        conversation = client.post("/conversations", headers=headers, json={"title": "Community"})
        assert conversation.status_code == 201
        sent = client.post(
            f"/conversations/{conversation.json()['id']}/messages", headers=headers,
            json={"content": "Can you find a community activity?"},
        )
        assert sent.status_code == 200, sent.text
        metadata = sent.json()["assistant_message"]["metadata_json"]
        assert metadata["community_search_state"] == "live"
        assert metadata["community_sources"][0]["checked_at"] is not None
        assert metadata["community_results"][0]["last_checked_at"] is not None
