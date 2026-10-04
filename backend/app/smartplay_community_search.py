"""Public LCSD SmartPLAY JSON snapshots; queries and identity stay local.

Only the official open-data endpoint is fetched. Detail URLs are displayed from
validated original fields, never fetched or converted into registration links.
"""
from __future__ import annotations

import json
import math
import re
import threading
import time
import zlib
from datetime import date, datetime, timedelta, timezone
from typing import Callable
from urllib.parse import parse_qs, urlsplit

import httpx

from .community_search import ProviderParseError

SNAPSHOT_URL = 'https://data.smartplay.lcsd.gov.hk/rest/cms/api/v1/publ/contents/open-data/activity-prog/file'
SNAPSHOT_HOST = 'data.smartplay.lcsd.gov.hk'
SOURCE_NAME = '香港特別行政區政府康樂及文化事務署（LCSD）／DATA.GOV.HK'
SOURCE_NAME_EN = 'Hong Kong SAR Government, Leisure and Cultural Services Department (LCSD) / DATA.GOV.HK'
MAX_BYTES = 20 * 1024 * 1024
MAX_ROWS = 10_000
CACHE_SECONDS = 600
STALE_CACHE_SECONDS = 21_600
FAILURE_COOLDOWN_SECONDS = 60
MAX_TOTAL_REQUEST_SECONDS = 45.0
HK = timezone(timedelta(hours=8), name='Asia/Hong_Kong')

SPORT_TOPICS = {
    'tai_chi': ('tai chi', 'tai-chi', 'taiji', '太極'),
    'dance': ('dance', 'dancing', '舞'),
    'table_tennis': ('table tennis', 'table-tennis', '乒乓'),
    'badminton': ('badminton', '羽毛球'),
    'swimming': ('swimming', '游泳'),
    'fitness': ('fitness', '健體', '體適能'),
    'yoga': ('yoga', '瑜伽'),
    'hiking': ('hiking', '行山', '遠足'),
    'health': ('healthy', 'health', '健康', '健體'),
    'tailoring': ('tailor', 'sew', '縫紉'),
    'sewing': ('tailor', 'sew', '縫紉'),
    'cooking': ('cook', 'bake', '烹飪'),
    'gardening': ('garden', '園藝'),
    'teaching': ('teaching', '教學'),
    'knitting': ('knit', '編織'),
    'woodworking': ('woodwork', 'carpentry', '木工'),
}


def _text(row: dict, key: str, *, required: bool = False) -> str:
    value = row.get(key)
    if value is None and not required:
        return ''
    if not isinstance(value, str) or len(value) > 12_000:
        raise ProviderParseError(f'Invalid SmartPLAY field: {key}')
    value = value.strip()
    if required and not value:
        raise ProviderParseError(f'Missing SmartPLAY field: {key}')
    return value


def _detail_url(value: str, activity_no: str, lang: str) -> str | None:
    if not value:
        return None
    try:
        parsed = urlsplit(value)
    except ValueError:
        return None
    if (parsed.scheme != 'https' or parsed.netloc != 'www.smartplay.lcsd.gov.hk'
            or parsed.path != '/programme/detail' or parsed.fragment):
        return None
    query = parse_qs(parsed.query, keep_blank_values=True)
    if query != {'activityNo': [activity_no], 'lang': [lang]}:
        return None
    return value


def _notes(row: dict, key: str, separator: str) -> str:
    value = row.get(key)
    if value is None or isinstance(value, str):
        return _text(row, key)
    if not isinstance(value, list) or len(value) > 100:
        raise ProviderParseError(f'Invalid SmartPLAY notes: {key}')
    parts = [_text({'note': part}, 'note') for part in value]
    result = separator.join(filter(None, parts))
    if len(result) > 12_000:
        raise ProviderParseError(f'SmartPLAY notes too long: {key}')
    return result


def _age(row: dict, key: str) -> int | None:
    value = row.get(key)
    if value is None:
        return None
    if type(value) is not int or not 0 <= value <= 199:
        raise ProviderParseError(f'Invalid SmartPLAY age: {key}')
    return value


def parse_snapshot(payload: bytes, checked: datetime) -> list[dict[str, object]]:
    """Validate the entire bounded snapshot before publishing any replacement."""
    try:
        raw = json.loads(payload)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise ProviderParseError('SmartPLAY snapshot is not valid JSON') from exc
    if not isinstance(raw, list) or len(raw) > MAX_ROWS:
        raise ProviderParseError('SmartPLAY snapshot must be a bounded list')
    result = []
    ids = set()
    for row in raw:
        if not isinstance(row, dict) or len(row) > 80:
            raise ProviderParseError('Invalid SmartPLAY record schema')
        activity_no = _text(row, 'ACTIVITY_NO', required=True)
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,40}', activity_no) or activity_no in ids:
            raise ProviderParseError('Invalid or duplicate SmartPLAY activity number')
        ids.add(activity_no)
        try:
            start = date.fromisoformat(_text(row, 'PGM_START_DATE', required=True))
            end = date.fromisoformat(_text(row, 'PGM_END_DATE', required=True))
        except ValueError as exc:
            raise ProviderParseError('Invalid SmartPLAY programme date') from exc
        if start > end or start.year < 2000 or end.year > 2100:
            raise ProviderParseError('Invalid SmartPLAY programme date range')
        tc_title, en_title = _text(row, 'TC_PGM_NAME'), _text(row, 'EN_PGM_NAME')
        if not (tc_title or en_title):
            raise ProviderParseError('Missing SmartPLAY programme name')
        tc_url = _detail_url(_text(row, 'TC_URL'), activity_no, 'tc')
        en_url = _detail_url(_text(row, 'EN_URL'), activity_no, 'en')
        if not (tc_url or en_url):
            raise ProviderParseError('No valid original SmartPLAY programme URL')
        tc_type, en_type = _text(row, 'TC_ACT_TYPE_NAME'), _text(row, 'EN_ACT_TYPE_NAME')
        tc_area, en_area = _text(row, 'TC_DISTRICT'), _text(row, 'EN_DISTRICT')
        tc_target, en_target = _text(row, 'TC_TARGET_GRP'), _text(row, 'EN_TARGET_GRP')
        tc_day, en_day = _text(row, 'TC_DAY'), _text(row, 'EN_DAY')
        minimum, maximum = _age(row, 'MIN_AGE'), _age(row, 'MAX_AGE')
        if minimum is not None and maximum is not None and minimum > maximum:
            raise ProviderParseError('Invalid SmartPLAY age range')
        tc_age, en_age = [], []
        if minimum is not None:
            tc_age.append(f'最低年齡：{minimum}歲')
            en_age.append(f'Minimum age: {minimum}')
        if maximum is not None and maximum != 199:
            tc_age.append(f'最高年齡：{maximum}歲')
            en_age.append(f'Maximum age: {maximum}')
        fee = row.get('FEE')
        fee_text = ''
        if fee is not None:
            if type(fee) not in (int, float) or fee < 0:
                raise ProviderParseError('Invalid SmartPLAY fee')
            try:
                if not math.isfinite(fee):
                    raise ProviderParseError('Invalid SmartPLAY fee')
                fee_text = f'HK${fee:g}'
            except OverflowError as exc:
                raise ProviderParseError('SmartPLAY fee exceeds numeric bounds') from exc
        start_time, end_time = _text(row, 'PGM_START_TIME'), _text(row, 'PGM_END_TIME')
        for value in (start_time, end_time):
            if value and not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d', value):
                raise ProviderParseError('Invalid SmartPLAY programme time')
        date_prefix = f'{start.isoformat()} – {end.isoformat()}'
        time_text = '–'.join(filter(None, (start_time, end_time)))
        result.append({
            'id': f'lcsd-smartplay:{activity_no}',
            'title': tc_title or en_title, 'title_en': en_title or None,
            'summary': '；'.join(filter(None, (tc_type, _text(row, 'TC_VENUE'), f'來源收費：{fee_text}' if fee_text else '', _notes(row, 'TC_NOTES', '；')))),
            'summary_en': '; '.join(filter(None, (en_type, _text(row, 'EN_VENUE'), f'Source fee: {fee_text}' if fee_text else '', _notes(row, 'EN_NOTES', '; ')))) or None,
            'organization': '康樂及文化事務署', 'organization_en': 'Leisure and Cultural Services Department',
            'area': tc_area or en_area or None, 'area_en': en_area or None,
            'event_start_at': datetime.combine(start, datetime.min.time(), HK),
            'event_end_at': datetime.combine(end, datetime.max.time(), HK),
            'date_text': '；'.join(filter(None, (date_prefix, tc_day or en_day, time_text))),
            'date_text_en': '; '.join(filter(None, (date_prefix, en_day, time_text))),
            'eligibility': '；'.join(filter(None, (tc_target or en_target, *tc_age))) or None,
            'eligibility_en': '; '.join(filter(None, (en_target, *en_age))) or None,
            'source_name': SOURCE_NAME, 'source_name_en': SOURCE_NAME_EN,
            'source_url': tc_url or en_url, 'source_url_en': en_url,
            'registration_url': None, 'last_checked_at': checked,
            'listing_type': 'activity', 'verified': False,
            'availability_note': '官方開放資料活動快照，僅按日期篩選；報名資格、名額及安排請以官方活動詳情確認。',
            'availability_note_en': 'Official open-data snapshot, filtered by programme dates only. Confirm eligibility, places and arrangements on the official activity page.',
            '_topic_text': ' '.join((tc_title, en_title, tc_type, en_type)).casefold(),
            '_area_text': (tc_area.casefold(), en_area.casefold()),
            '_elderly': en_target.casefold() == 'elderly' or tc_target == '長者',
        })
    return result


class SmartPlayCommunitySearch:
    """Single-flight snapshots with fresh cache, bounded stale fallback and cooldown."""

    def __init__(self, *, enabled: bool = True, transport: httpx.BaseTransport | None = None,
                 clock: Callable[[], datetime] | None = None) -> None:
        self.enabled = enabled
        self.transport = transport
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self._cache: tuple[datetime, list[dict[str, object]]] | None = None
        self._failure: tuple[datetime, str, str] | None = None
        self._lock = threading.Lock()

    def _fetch(self, checked: datetime) -> list[dict[str, object]]:
        started = time.monotonic()
        timeout = httpx.Timeout(12.0, connect=5.0, write=5.0, pool=5.0)
        with httpx.Client(timeout=timeout, follow_redirects=False, trust_env=False, transport=self.transport,
                          headers={'Accept': 'application/json', 'Accept-Encoding': 'identity', 'User-Agent': 'EchoCommunitySearch/1.0'}) as client:
            with client.stream('GET', SNAPSHOT_URL) as response:
                if response.status_code != 200:
                    raise ValueError(f'SmartPLAY returned HTTP {response.status_code}')
                final = urlsplit(str(response.url))
                if final.scheme != 'https' or final.netloc != SNAPSHOT_HOST or str(response.url) != SNAPSHOT_URL:
                    raise ValueError('SmartPLAY response URL is outside the fixed allowlist')
                if response.headers.get('content-type', '').split(';')[0].strip().lower() != 'application/json':
                    raise ProviderParseError('SmartPLAY did not return JSON')
                chunks = []
                total = 0
                raw_total = 0
                encoding = response.headers.get('content-encoding', 'identity').strip().lower()
                if encoding not in ('identity', 'gzip', 'deflate'):
                    raise ValueError('Unsupported SmartPLAY content encoding')
                decoder = zlib.decompressobj(16 + zlib.MAX_WBITS if encoding == 'gzip' else zlib.MAX_WBITS) if encoding != 'identity' else None
                # Check every received raw chunk. Decoded chunk buffering can
                # hide a slow drip and eagerly allocate a gzip expansion.
                for raw in response.iter_raw():
                    if time.monotonic() - started > MAX_TOTAL_REQUEST_SECONDS:
                        raise ValueError('SmartPLAY request exceeded total time limit')
                    raw_total += len(raw)
                    if raw_total > MAX_BYTES:
                        raise ValueError('SmartPLAY compressed snapshot exceeded size limit')
                    try:
                        chunk = decoder.decompress(raw, MAX_BYTES - total + 1) if decoder else raw
                    except zlib.error as exc:
                        raise ProviderParseError('Invalid SmartPLAY compressed snapshot') from exc
                    total += len(chunk)
                    if total > MAX_BYTES:
                        raise ValueError('SmartPLAY decompressed snapshot exceeded size limit')
                    chunks.append(chunk)
                if decoder and (not decoder.eof or decoder.unused_data):
                    raise ProviderParseError('Incomplete or concatenated SmartPLAY compressed snapshot')
                if time.monotonic() - started > MAX_TOTAL_REQUEST_SECONDS:
                    raise ValueError('SmartPLAY request exceeded total time limit')
                parsed = parse_snapshot(b''.join(chunks), checked)
                if time.monotonic() - started > MAX_TOTAL_REQUEST_SECONDS:
                    raise ValueError('SmartPLAY snapshot processing exceeded total time limit')
                return parsed

    def search(self, *, listing_type: str, topic: str | None = None, area: str | None = None,
               target_group: str = 'all', offset: int = 0, limit: int = 20) -> dict[str, object]:
        if target_group not in ('all', 'elderly') or offset < 0 or not 1 <= limit <= 40:
            raise ValueError('Invalid community pagination or target group')
        now = self.clock()
        if listing_type != 'activity' or not self.enabled:
            return self._result([], [], now, 'unavailable', 'sources_disabled', offset, limit)
        # The bounded fetch is inside the lock so waiting requests recheck cache
        # or cooldown and never launch concurrent downloads of the same snapshot.
        with self._lock:
            now = self.clock()
            state = 'cache'
            if not self._cache or now - self._cache[0] > timedelta(seconds=CACHE_SECONDS):
                if not self._failure or now - self._failure[0] >= timedelta(seconds=FAILURE_COOLDOWN_SECONDS):
                    try:
                        fetched = self._fetch(now)
                        checked = self.clock()  # successful completion, never an attempted fetch
                        for candidate in fetched:
                            candidate['last_checked_at'] = checked
                        self._cache = checked, fetched
                        self._failure = None
                        state = 'live'
                    except (httpx.HTTPError, ValueError, OSError) as exc:
                        kind = 'parse_failed' if isinstance(exc, ProviderParseError) else 'source_unavailable'
                        self._failure = self.clock(), kind, str(exc)[:180]
            cached = self._cache
            failure = self._failure
            now = self.clock()  # refresh may cross a date or stale-cache boundary
        valid_cache = cached is not None and now - cached[0] <= timedelta(seconds=STALE_CACHE_SECONDS)
        if not valid_cache:
            state = 'unavailable'
        checked, candidates = cached if valid_cache else (None, [])
        reason = ('stale_cache' if valid_cache else failure[1]) if failure else None
        source = {'name': SOURCE_NAME, 'url': SNAPSHOT_URL, 'state': state, 'checked_at': checked,
                  'error': failure[2] if failure else None, 'error_kind': failure[1] if failure else None}
        today = now.astimezone(HK).date()
        matches = []
        for candidate in candidates:
            if candidate['event_end_at'].date() < today:
                continue
            if target_group == 'elderly' and not candidate['_elderly']:
                continue
            if topic and not any(term in candidate['_topic_text'] for term in SPORT_TOPICS.get(topic.casefold(), ())):
                continue
            if area and not self._matches_area(candidate['_area_text'], area):
                continue
            matches.append({key: value for key, value in candidate.items() if not key.startswith('_')})
        if not matches and reason is None:
            reason = 'no_matches'
        return self._result(matches, [source], now, state, reason, offset, limit)

    @staticmethod
    def _matches_area(values: tuple[str, str], area: str) -> bool:
        # Match official Chinese/English district labels, including Chinese 區.
        normalized = area.strip().casefold().removesuffix('區')
        return any(normalized == value.removesuffix('區') for value in values)

    @staticmethod
    def _result(matches: list, sources: list, now: datetime, state: str, reason: str | None,
                offset: int, limit: int) -> dict[str, object]:
        messages = {
            'sources_disabled': 'Community search for this listing type is not enabled yet.',
            'source_unavailable': 'The official activity snapshot could not be reached.',
            'parse_failed': 'The official activity snapshot could not be read safely.',
            'no_matches': 'No current activities match these filters in the official snapshot.',
            'stale_cache': 'Showing an earlier official snapshot; refresh failed. Confirm details with the provider.',
        }
        return {'items': matches[offset:offset + limit], 'no_results': not matches,
                'total_count': len(matches), 'offset': offset, 'limit': limit,
                'has_more': offset + limit < len(matches), 'message': messages.get(reason),
                'search_state': state, 'search_reason': reason,
                'checked_at': sources[0]['checked_at'] if sources else None,
                'requested_at': now, 'sources': sources}
