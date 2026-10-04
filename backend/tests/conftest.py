"""Offline public-source isolation for the entire backend suite."""
import httpx
import pytest

from app.smartplay_community_search import SmartPlayCommunitySearch


@pytest.fixture(autouse=True)
def isolate_default_smartplay_transport(monkeypatch):
    """Default app creation stays enabled but uses a synthetic unavailable feed.

    Explicit MockTransport tests exercise real parsing/cache/HTTP boundaries.
    The fetch guard also protects instances constructed during test collection,
    including app.main's module-global app, before this fixture patches init.
    """
    original_init = SmartPlayCommunitySearch.__init__
    original_fetch = SmartPlayCommunitySearch._fetch

    def offline_init(self, *, enabled=True, transport=None, clock=None):
        if transport is None:
            transport = httpx.MockTransport(lambda request: httpx.Response(503))
        original_init(self, enabled=enabled, transport=transport, clock=clock)

    def offline_fetch(self, checked):
        if self.transport is None:
            raise ValueError('Live SmartPLAY network is disabled in the backend test suite')
        return original_fetch(self, checked)

    monkeypatch.setattr(SmartPlayCommunitySearch, '__init__', offline_init)
    monkeypatch.setattr(SmartPlayCommunitySearch, '_fetch', offline_fetch)
