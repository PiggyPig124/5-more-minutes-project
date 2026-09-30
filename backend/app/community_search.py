"""Bounded retrieval from public Hong Kong community provider pages.

Only fixed provider URLs are fetched. Page markup is treated as untrusted data;
no scripts, links, instructions, or redirects from a provider are executed.
"""

from __future__ import annotations

import hashlib
import re
import threading
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from typing import Callable
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

import httpx

MAX_BYTES = 700_000
MAX_RESULTS_PER_SOURCE = 80
CACHE_SECONDS = 900
STALE_CACHE_SECONDS = 21_600
MAX_TOTAL_REQUEST_SECONDS = 8.0


@dataclass(frozen=True)
class Provider:
    name: str
    url: str
    host: str
    parser: Callable[[str, datetime], list[dict[str, object]]]
    listing_type: str


class _HkcmisParser(HTMLParser):
    """Extract the provider's visible h3 + table listing cards."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.cards: list[dict[str, str]] = []
        self.in_card = False
        self.in_h3 = False
        self.in_td = False
        self.title: list[str] = []
        self.cell: list[str] = []
        self.cells: list[str] = []

    @staticmethod
    def clean(parts: list[str]) -> str:
        return re.sub(r"\s+", " ", " ".join(parts)).strip()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "div" and "col-md-offset-1" in dict(attrs).get("class", ""):
            if self.in_card:
                self.finish_card()
            self.in_card = True
            self.title, self.cells = [], []
        elif self.in_card and tag == "h3":
            self.in_h3 = True
        elif self.in_card and tag == "td":
            self.in_td = True
            self.cell = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "h3":
            self.in_h3 = False
        elif tag == "td" and self.in_td:
            self.in_td = False
            self.cells.append(self.clean(self.cell))
        elif tag == "div" and self.in_card:
            self.finish_card()

    def handle_data(self, data: str) -> None:
        if self.in_h3:
            self.title.append(data)
        if self.in_td:
            self.cell.append(data)

    def finish_card(self) -> None:
        title = self.clean(self.title)
        if title:
            fields: dict[str, str] = {"title": title}
            for index in range(0, len(self.cells) - 1, 2):
                fields[self.cells[index].rstrip(":：")] = self.cells[index + 1]
            self.cards.append(fields)
        self.in_card = self.in_h3 = self.in_td = False
        self.title, self.cells, self.cell = [], [], []


def _area_match(text: str, requested: str | None) -> bool:
    if requested is None:
        return True
    aliases = {
        "wan chai": ("wan chai", "灣仔"), "灣仔": ("灣仔", "wan chai"),
        "central and western": ("central", "中西區", "中環"), "中西區": ("中西區", "中環", "central"),
        "eastern": ("eastern", "東區"), "東區": ("東區", "eastern"),
        "southern": ("southern", "南區"), "南區": ("南區", "southern"),
        "yau tsim mong": ("yau tsim mong", "油尖旺"), "油尖旺": ("油尖旺", "yau tsim mong"),
        "sham shui po": ("sham shui po", "深水埗"), "深水埗": ("深水埗", "sham shui po"),
        "kowloon city": ("kowloon city", "九龍城"), "九龍城": ("九龍城", "kowloon city"),
        "wong tai sin": ("wong tai sin", "黃大仙"), "黃大仙": ("黃大仙", "wong tai sin"),
        "kwun tong": ("kwun tong", "觀塘"), "觀塘": ("觀塘", "kwun tong"),
        "kwai tsing": ("kwai tsing", "葵青"), "葵青": ("葵青", "kwai tsing"),
        "tsuen wan": ("tsuen wan", "荃灣"), "荃灣": ("荃灣", "tsuen wan"),
        "tuen mun": ("tuen mun", "屯門"), "屯門": ("屯門", "tuen mun"),
        "yuen long": ("yuen long", "元朗"), "元朗": ("元朗", "yuen long"),
        "north": ("north", "北區"), "北區": ("北區", "north"),
        "tai po": ("tai po", "大埔"), "大埔": ("大埔", "tai po"),
        "sha tin": ("sha tin", "沙田"), "沙田": ("沙田", "sha tin"),
        "sai kung": ("sai kung", "西貢"), "西貢": ("西貢", "sai kung"),
        "islands": ("islands", "離島"), "離島": ("離島", "islands"),
    }
    needles = aliases.get(requested.casefold(), (requested,))
    return any(needle.casefold() in text.casefold() for needle in needles)


def _stable_id(source_url: str, title: str, date_text: object) -> str:
    digest = hashlib.sha256(f"{source_url}\n{title}\n{date_text}".encode("utf-8")).hexdigest()[:24]
    return f"public-{digest}"


def _hkcmis(html: str, checked: datetime) -> list[dict[str, object]]:
    parser = _HkcmisParser()
    parser.feed(html[:MAX_BYTES].decode("utf-8", errors="replace") if isinstance(html, bytes) else html[:MAX_BYTES])
    today = checked.astimezone(ZoneInfo("Asia/Hong_Kong")).date()
    results: list[dict[str, object]] = []
    for card in parser.cards[:MAX_RESULTS_PER_SOURCE]:
        dates = re.findall(r"\b(20\d{2}-\d{2}-\d{2})\b", card.get("日期", ""))
        if not dates:
            continue
        try:
            start = date.fromisoformat(dates[0])
            end = date.fromisoformat(dates[-1])
        except ValueError:
            continue
        if end < today:
            continue
        description = card.get("內容", "")
        location = card.get("時間", "")
        combined = " ".join((card["title"], description, location))
        source_url = "https://hkcmis.com/embed?unit_id=3"
        results.append({
            "id": _stable_id(source_url, card["title"], card.get("日期")),
            "title": card["title"][:240],
            "summary": description[:1200],
            "organization": "香港基督教培道聯愛會",
            "area": _detect_area(location),
            "event_start_at": datetime.combine(start, datetime.min.time(), ZoneInfo("Asia/Hong_Kong")),
            "event_end_at": datetime.combine(end, datetime.max.time(), ZoneInfo("Asia/Hong_Kong")),
            "date_text": card.get("日期"),
            "eligibility": "Eligibility details are not consistently provided; check the source.",
            "source_name": "香港基督教培道聯愛會 (HKCMIS)",
            "source_url": source_url,
            "registration_url": None,
            "last_checked_at": checked,
            "listing_type": "activity",
            "verified": False,
            "availability_note": "Listed by the provider; places and current availability are not guaranteed. Contact the provider before attending.",
            "_search_text": combined,
        })
    if not parser.cards:
        raise ValueError("Provider page format changed; no structured activity cards were found")
    return results


def _detect_area(text: str) -> str | None:
    if any(name in text for name in ("銅鑼灣", "渣甸街", "灣仔")):
        return "灣仔"
    if any(name in text for name in ("中環", "上環", "西營盤", "石水渠街")):
        return "中西區"
    districts = (
        "中西區", "灣仔", "東區", "南區", "油尖旺", "深水埗", "九龍城", "黃大仙", "觀塘",
        "葵青", "荃灣", "屯門", "元朗", "北區", "大埔", "沙田", "西貢", "離島",
        "Central and Western", "Wan Chai", "Eastern", "Southern", "Yau Tsim Mong",
        "Sham Shui Po", "Kowloon City", "Wong Tai Sin", "Kwun Tong", "Kwai Tsing",
        "Tsuen Wan", "Tuen Mun", "Yuen Long", "North", "Tai Po", "Sha Tin", "Sai Kung", "Islands",
    )
    return next((district for district in districts if district.casefold() in text.casefold()), None)


def _strip_html(fragment: str) -> str:
    text = re.sub(r"<(script|style)\b[^>]*>.*?</\1\s*>", " ", fragment, flags=re.I | re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    from html import unescape
    return re.sub(r"\s+", " ", unescape(text)).strip()


def _jcvt(html: str, checked: datetime) -> list[dict[str, object]]:
    # Parse only visible anchors for fixed detail path URLs; ignore SSR scripts.
    page = html[:MAX_BYTES]
    results: list[dict[str, object]] = []
    pattern = re.compile(
        r'<a\b[^>]*href=["\'](/zh/volunteer-opportunities/latest/[0-9a-f-]{36})["\'][^>]*>(.*?)</a>',
        re.I | re.S,
    )
    for match in pattern.finditer(page):
        card_html = match.group(2)
        title_match = re.search(r'<p\b[^>]*class=["\'][^"\']*body-1-d font-bold[^"\']*["\'][^>]*>(.*?)</p>', card_html, re.I | re.S)
        row_html = re.findall(r'<div\b[^>]*class=["\'][^"\']*body-2-d text-black-900 line-clamp-1[^"\']*["\'][^>]*>(.*?)</div>', card_html, re.I | re.S)
        values = [_strip_html(fragment) for fragment in row_html]
        text = " ".join(([ _strip_html(title_match.group(1)) ] if title_match else []) + values)
        dates = re.findall(r"\b\d{2}/\d{2}/20\d{2}\b", text)
        if len(dates) < 2:
            continue
        try:
            start, end = (datetime.strptime(value, "%d/%m/%Y").replace(tzinfo=ZoneInfo("Asia/Hong_Kong")) for value in dates[:2])
        except ValueError:
            continue
        if end.date() < checked.astimezone(ZoneInfo("Asia/Hong_Kong")).date():
            continue
        # These are the visible SSR card fields, not values recovered by running
        # the site's Javascript application.
        title = _strip_html(title_match.group(1)) if title_match else ""
        title = re.sub(r"\s+", " ", title)[:240]
        organization = values[0] if values else "Volunteer opportunity provider"
        area_text = values[-1] if values else ""
        if end.date() == start.date():
            end = end.replace(hour=23, minute=59, second=59, microsecond=999999)
        if not title:
            continue
        area = next((district for district in (
            "中西區", "灣仔", "東區", "南區", "油尖旺", "深水埗", "九龍城", "黃大仙", "觀塘",
            "葵青", "荃灣", "屯門", "元朗", "北區", "大埔", "沙田", "西貢", "離島",
            "Central and Western", "Wan Chai", "Eastern", "Southern", "Yau Tsim Mong",
            "Sham Shui Po", "Kowloon City", "Wong Tai Sin", "Kwun Tong", "Kwai Tsing",
            "Tsuen Wan", "Tuen Mun", "Yuen Long", "North", "Tai Po", "Sha Tin", "Sai Kung", "Islands",
        ) if district.casefold() in area_text.casefold()), None)
        detail_url = "https://www.jcvtplatform.hk" + match.group(1)
        source_url = "https://www.jcvtplatform.hk/zh/volunteer-opportunities"
        results.append({
            "id": _stable_id(source_url, title, f"{dates[0]} {dates[1]}"),
            "title": title,
            "summary": "Volunteer opportunity listed on the Jockey Club Volunteer Together Platform. See the provider page for details.",
            "organization": organization[:240],
            "area": area,
            "event_start_at": start,
            "event_end_at": end,
            "date_text": f"{dates[0]} – {dates[1]}",
            "eligibility": "Eligibility and application deadline need confirmation on the provider page.",
            "source_name": "賽馬會眾心行善平台 (JCVTP)",
            "source_url": source_url,
            "registration_url": detail_url,
            "last_checked_at": checked,
            "listing_type": "opportunity",
            "verified": False,
            "availability_note": "Listed by the provider; availability and eligibility are not guaranteed. Review the provider details before applying.",
            "_search_text": text,
        })
        if len(results) >= MAX_RESULTS_PER_SOURCE:
            break
    if not re.search(r"/zh/volunteer-opportunities/latest/[0-9a-f-]{36}", page, re.I):
        raise ValueError("Provider page format changed; no structured opportunity cards were found")
    return results


PROVIDERS = (
    Provider("香港基督教培道聯愛會 (HKCMIS)", "https://hkcmis.com/embed?unit_id=3", "hkcmis.com", _hkcmis, "activity"),
    Provider("賽馬會眾心行善平台 (JCVTP)", "https://www.jcvtplatform.hk/zh/volunteer-opportunities", "www.jcvtplatform.hk", _jcvt, "opportunity"),
)


class CommunitySearch:
    """Small in-memory cache with bounded HTTP and truthful provider states."""

    def __init__(self, providers: tuple[Provider, ...] = PROVIDERS, transport: httpx.BaseTransport | None = None) -> None:
        self.providers = providers
        self.transport = transport
        self._cache: dict[str, tuple[datetime, list[dict[str, object]]]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _url_is_allowed(provider: Provider) -> bool:
        parsed = urlparse(provider.url)
        return parsed.scheme == "https" and parsed.hostname == provider.host and parsed.username is None and parsed.password is None

    def _fetch(self, provider: Provider, checked: datetime) -> list[dict[str, object]]:
        if not self._url_is_allowed(provider):
            raise ValueError("Provider URL is outside the fixed HTTPS allowlist")
        started = time.monotonic()
        with httpx.Client(timeout=httpx.Timeout(6.0, connect=3.0), follow_redirects=False, trust_env=False, transport=self.transport, headers={"Accept": "text/html", "User-Agent": "EchoCommunitySearch/1.0"}) as client:
            with client.stream("GET", provider.url) as response:
                if response.status_code != 200:
                    raise ValueError(f"Provider returned HTTP {response.status_code}")
                final = urlparse(str(response.url))
                if final.scheme != "https" or final.hostname != provider.host:
                    raise ValueError("Provider response host did not match allowlist")
                content_type = response.headers.get("content-type", "").lower()
                if "text/html" not in content_type:
                    raise ValueError("Provider did not return HTML")
                chunks: list[bytes] = []
                total = 0
                for chunk in response.iter_bytes():
                    if time.monotonic() - started > MAX_TOTAL_REQUEST_SECONDS:
                        raise ValueError("Provider request exceeded the total time limit")
                    total += len(chunk)
                    if total > MAX_BYTES:
                        raise ValueError("Provider page exceeded the size limit")
                    chunks.append(chunk)
                if time.monotonic() - started > MAX_TOTAL_REQUEST_SECONDS:
                    raise ValueError("Provider request exceeded the total time limit")
                return provider.parser(b"".join(chunks).decode("utf-8", errors="replace"), checked)

    def search(self, *, listing_type: str, topic: str | None = None, area: str | None = None) -> dict[str, object]:
        now = datetime.now(timezone.utc)
        selected = [p for p in self.providers if p.listing_type == listing_type]
        source_states: list[dict[str, object]] = []
        results: list[dict[str, object]] = []
        any_live = False
        any_cache = False
        for provider in selected:
            key = provider.name
            with self._lock:
                cached = self._cache.get(key)
            if cached and now - cached[0] <= timedelta(seconds=CACHE_SECONDS):
                source_checked, candidates = cached
                any_cache = True
                source_states.append({"name": provider.name, "url": provider.url, "state": "cache", "checked_at": source_checked, "error": None})
            else:
                try:
                    fetched = self._fetch(provider, now)
                    with self._lock:
                        self._cache[key] = (now, fetched)
                    source_states.append({"name": provider.name, "url": provider.url, "state": "live", "checked_at": now, "error": None})
                    candidates = fetched
                    any_live = True
                    source_checked = now
                except Exception as exc:
                    with self._lock:
                        cached = self._cache.get(key)
                    if cached and now - cached[0] <= timedelta(seconds=STALE_CACHE_SECONDS):
                        source_checked, candidates = cached
                        any_cache = True
                        source_states.append({"name": provider.name, "url": provider.url, "state": "cache", "checked_at": source_checked, "error": str(exc)[:180]})
                    else:
                        source_states.append({"name": provider.name, "url": provider.url, "state": "unavailable", "checked_at": None, "error": str(exc)[:180]})
                        continue
            for candidate in candidates:
                if candidate.get("event_end_at") and candidate["event_end_at"].date() < now.astimezone(ZoneInfo("Asia/Hong_Kong")).date():
                    continue
                text = str(candidate.get("_search_text", "")).casefold()
                if topic and not _matches_topic(topic, text):
                    continue
                if area and not _area_match(" ".join(str(candidate.get(key) or "") for key in ("area", "_search_text")), area):
                    continue
                results.append({k: v for k, v in candidate.items() if not k.startswith("_")})
                if len(results) >= MAX_RESULTS_PER_SOURCE:
                    break
        if any_live:
            state = "live"
            message = None if results else "The provider pages were searched, but no current matching listings were found."
        elif any_cache:
            state = "cache"
            message = None if results else "No current matches were found in the saved provider results. Search sources could not be refreshed."
        else:
            state = "unavailable"
            message = "Community sources could not be reached, so no current result can be confirmed."
        retrieval_times = [source.get("checked_at") for source in source_states if source.get("checked_at") is not None]
        return {"items": results, "no_results": not results, "message": message, "search_state": state, "checked_at": max(retrieval_times) if retrieval_times else None, "requested_at": now, "sources": source_states}


_TOPIC_SYNONYMS = {
    "tailoring": ("sew", "tailor", "縫", "裁縫", "車衣"),
    "sewing": ("sew", "tailor", "縫", "裁縫", "車衣"),
    "cooking": ("cook", "bake", "烹飪", "煮餸", "煮菜", "烘焙", "廚藝"),
    "gardening": ("garden", "園藝", "種花", "種菜", "綠化"),
    "teaching": ("teach", "導師", "教學", "教人", "小導師"),
    "knitting": ("knit", "編織", "織冷衫", "毛線"),
    "woodworking": ("woodwork", "carpentry", "木工"),
    "health": ("健康", "health", "保健"),
}

_TOPIC_ALIASES = {
    "縫紉": "sewing", "縫衣": "sewing", "裁縫": "tailoring", "車衣": "tailoring",
    "烹飪": "cooking", "煮餸": "cooking", "煮菜": "cooking", "烘焙": "cooking",
    "園藝": "gardening", "種花": "gardening", "種菜": "gardening",
    "教學": "teaching", "教書": "teaching", "編織": "knitting", "織冷衫": "knitting",
    "木工": "woodworking", "健康": "health",
}


def _matches_topic(topic: str, text: str) -> bool:
    canonical = _TOPIC_ALIASES.get(topic.casefold(), topic.casefold())
    return any(term.casefold() in text for term in _TOPIC_SYNONYMS.get(canonical, (topic,)))


_COMMUNITY_TERMS = r"activities|activity|classes|class|groups|group|events|event|volunteer(?:ing)?|opportunities|community|活動|課程|小組|義工|志願|社區|中心"
_COMMUNITY_INTENT = r"find|show|search|look\s+for|recommend|suggest|join|any|is\s+there|what|where|搵|找|搜尋|有冇|有沒有|想參加|推薦|推荐|有什麼|有甚麼"


def explicit_community_query(text: str) -> bool:
    """Require a clear ask about activities/community participation."""
    return bool(re.search(rf"(?:{_COMMUNITY_INTENT}).{{0,80}}(?:{_COMMUNITY_TERMS})|(?:{_COMMUNITY_TERMS}).{{0,80}}(?:{_COMMUNITY_INTENT})", text, re.I | re.S))


def topic_from_query(text: str) -> str | None:
    lowered = text.casefold()
    if any(x in lowered for x in ("tailor", "sew", "縫紉", "縫衣", "裁縫", "車衣")):
        return "sewing"
    if any(x in lowered for x in ("cook", "bake", "烹飪", "煮餸", "煮菜", "烘焙", "廚藝")):
        return "cooking"
    if any(x in lowered for x in ("garden", "園藝", "種花", "種菜")):
        return "gardening"
    if any(x in lowered for x in ("teach", "teaching", "教學", "教書", "導師")):
        return "teaching"
    if any(x in lowered for x in ("knit", "編織", "織冷衫", "毛線")):
        return "knitting"
    if any(x in lowered for x in ("woodwork", "carpentry", "木工")):
        return "woodworking"
    if any(x in lowered for x in ("health", "健康", "保健")):
        return "health"
    return None


def community_listing_type_from_query(text: str) -> str:
    return "opportunity" if re.search(r"volunteer|volunteering|opportunit|義工|志願|貢獻|服務他人", text, re.I) else "activity"
