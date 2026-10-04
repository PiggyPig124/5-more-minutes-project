from __future__ import annotations

import copy
import gzip
import importlib
import json
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

NOW = datetime(2026, 10, 4, 12, tzinfo=timezone.utc)
URL = 'https://data.smartplay.lcsd.gov.hk/rest/cms/api/v1/publ/contents/open-data/activity-prog/file'


def module():
    assert importlib.util.find_spec('app.smartplay_community_search') is not None, 'SmartPLAY adapter is missing'
    return importlib.import_module('app.smartplay_community_search')


def row(number='ST260015HES', **changes):
    value = {
        'ACTIVITY_NO': number, 'TC_PGM_NAME': '活力長者計劃 - 乒乓球同樂',
        'EN_PGM_NAME': 'Healthy Elderly Scheme - Table-tennis Fun Day for Elderly',
        'TC_ACT_TYPE_NAME': '活力長者計劃', 'EN_ACT_TYPE_NAME': 'Healthy Elderly Scheme',
        'TC_DISTRICT': '沙田區', 'EN_DISTRICT': 'Sha Tin',
        'PGM_START_DATE': '2026-10-05', 'PGM_END_DATE': '2026-10-28',
        'TC_DAY': '逢星期一、三（10月19日除外）', 'EN_DAY': 'Mon,Wed (Exclude 19 Oct 2026)',
        'PGM_START_TIME': '10:00', 'PGM_END_TIME': '12:00',
        'TC_VENUE': '圓洲角體育館', 'EN_VENUE': 'Yuen Chau Kok Sports Centre',
        'TC_TARGET_GRP': '長者', 'EN_TARGET_GRP': 'Elderly',
        'MIN_AGE': 60, 'MAX_AGE': 199, 'FEE': 0, 'QUOTA': 16, 'PLACES_LEFT': 16,
        'ENROL_METHOD': 'WALKIN', 'TC_NOTES': None, 'EN_NOTES': None,
        'TC_URL': f'https://www.smartplay.lcsd.gov.hk/programme/detail?activityNo={number}&&lang=tc',
        'EN_URL': f'https://www.smartplay.lcsd.gov.hk/programme/detail?activityNo={number}&&lang=en',
    }
    value.update(changes)
    return value


def service(rows=None, handler=None, clock=None):
    adapter = module()
    chosen = handler or (lambda request: httpx.Response(200, json=[row()] if rows is None else rows))
    def streaming_response(request):
        response = chosen(request)
        if response.is_stream_consumed:
            response = httpx.Response(response.status_code, headers=response.headers, stream=httpx.ByteStream(response.content))
        return response
    return adapter.SmartPlayCommunitySearch(
        transport=httpx.MockTransport(streaming_response),
        clock=clock or (lambda: NOW),
    )


def test_maps_bilingual_official_fields_without_availability_or_invented_registration():
    item = service().search(listing_type='activity')['items'][0]
    assert item['id'] == 'lcsd-smartplay:ST260015HES'
    assert item['title'] == row()['TC_PGM_NAME']
    assert item['title_en'] == row()['EN_PGM_NAME']
    assert item['area'] == '沙田區' and item['area_en'] == 'Sha Tin'
    assert '圓洲角體育館' in item['summary']
    assert 'Yuen Chau Kok' in item['summary_en']
    assert 'Exclude 19 Oct' in item['date_text_en']
    assert '長者' in item['eligibility'] and 'Elderly' in item['eligibility_en']
    assert '60' in item['eligibility'] and '60' in item['eligibility_en']
    assert '199' not in str(item)
    assert 'HK$0' in item['summary'] and 'HK$0' in item['summary_en']
    assert 'PLACES_LEFT' not in item and 'quota' not in item
    assert item['registration_url'] is None and item['verified'] is False
    assert item['source_url'] == row()['TC_URL'] and item['source_url_en'] == row()['EN_URL']
    assert 'DATA.GOV.HK' in item['source_name']
    assert item['event_start_at'].isoformat() == '2026-10-05T00:00:00+08:00'


def test_full_snapshot_filters_locally_before_pagination_and_old_call_works():
    rows = [row(f'OTHER{i}', EN_PGM_NAME='Swimming class', TC_PGM_NAME='游泳班', EN_TARGET_GRP='Adults') for i in range(90)]
    rows += [row(f'MATCH{i}') for i in range(45)]
    calls = []
    def handler(request):
        calls.append(request)
        return httpx.Response(200, json=rows)
    search = service(handler=handler)
    result = search.search(listing_type='activity', topic='table_tennis', area='沙田', target_group='elderly', offset=20, limit=20)
    assert result['total_count'] == 45 and result['offset'] == 20 and result['limit'] == 20
    assert len(result['items']) == 20 and result['has_more']
    assert result['items'][0]['id'] == 'lcsd-smartplay:MATCH20'
    assert len(search.search(listing_type='activity')['items']) == 20
    assert len(calls) == 1 and str(calls[0].url) == URL
    assert calls[0].method == 'GET' and not calls[0].content
    beyond = search.search(listing_type='activity', topic='table_tennis', offset=80)
    assert beyond['items'] == [] and beyond['total_count'] == 45 and not beyond['has_more']
    assert beyond['no_results'] is False and beyond['search_reason'] is None


@pytest.mark.parametrize('topic,name', [('tai_chi','Tai Chi'),('dance','Social Dance'),('table_tennis','Table-tennis'),('badminton','Badminton'),('swimming','Swimming'),('fitness','Fitness'),('yoga','Yoga'),('hiking','Hiking')])
def test_closed_sports_topics_use_programme_fields(topic, name):
    search = service([row(EN_PGM_NAME=name, TC_PGM_NAME='', EN_NOTES='cooking gardening')])
    assert search.search(listing_type='activity', topic=topic)['total_count'] == 1
    assert search.search(listing_type='activity', topic='cooking')['search_reason'] == 'no_matches'


def test_only_current_dates_hong_kong_and_exact_elderly_target_not_age_guesses():
    search = service([row('A', PGM_END_DATE='2026-10-04', PGM_START_DATE='2026-10-01'), row('B',EN_TARGET_GRP='Adults',TC_TARGET_GRP='成人'), row('C', PGM_END_DATE='2026-10-03',PGM_START_DATE='2026-10-01')], clock=lambda: datetime(2026,10,4,16,tzinfo=timezone.utc))
    result = search.search(listing_type='activity', target_group='elderly')
    assert result['items'] == [] and result['search_reason'] == 'no_matches'
    assert search.search(listing_type='activity')['total_count'] == 1


def test_opportunity_and_disabled_activity_never_fetch():
    def forbidden(request):
        pytest.fail('Source must not be fetched')
    search = service(handler=forbidden)
    result = search.search(listing_type='opportunity', topic='teaching')
    assert result['search_reason'] == 'sources_disabled' and result['checked_at'] is None
    assert result['sources'] == [] and result['search_state'] == 'unavailable'
    disabled = module().SmartPlayCommunitySearch(enabled=False, transport=httpx.MockTransport(forbidden))
    assert disabled.search(listing_type='activity')['search_reason'] == 'sources_disabled'


@pytest.mark.parametrize('changes', [
    {'TC_URL':'https://[', 'EN_URL':None},
    {'TC_URL':'javascript:alert(1)', 'EN_URL':'https://evil.test/'},
    {'TC_URL':'https://www.smartplay.lcsd.gov.hk/programme/detail?activityNo=OTHER&lang=tc','EN_URL':None},
    {'TC_URL':'https://www.smartplay.lcsd.gov.hk:443/programme/detail?activityNo=ST260015HES&lang=tc','EN_URL':None},
    {'TC_URL':'https://www.smartplay.lcsd.gov.hk/programme/detail?activityNo=ST260015HES&lang=en','EN_URL':None},
])
def test_invalid_original_urls_do_not_become_invented_links(changes):
    result = service([row(**changes)]).search(listing_type='activity')
    assert result['search_reason'] == 'parse_failed' and not result['items']


@pytest.mark.parametrize('fee', [True,-1,float('inf'),10**500,'25'])
def test_invalid_fee_is_schema_failure(fee):
    search=service(handler=lambda request:httpx.Response(200,headers={'content-type':'application/json'},text=json.dumps([row(FEE=fee)])))
    assert search.search(listing_type='activity')['search_reason']=='parse_failed'


def test_oversized_fee_parse_failure_preserves_last_valid_snapshot():
    now=[NOW]
    rows=[[row()]]
    search=service(handler=lambda request:httpx.Response(200,json=rows[0]),clock=lambda:now[0])
    search.search(listing_type='activity')
    now[0]+=timedelta(seconds=601)
    rows[0]=[row(FEE=10**400)]
    result=search.search(listing_type='activity')
    assert result['search_reason']=='stale_cache' and result['checked_at']==NOW
    assert result['sources'][0]['error_kind']=='parse_failed'
    assert 'HK$0' in result['items'][0]['summary_en']


@pytest.mark.parametrize('encoding', ['gzip','deflate'])
def test_valid_compressed_snapshot_decodes_with_raw_stream(encoding):
    import zlib
    payload=json.dumps([row()]).encode()
    encoded=gzip.compress(payload) if encoding=='gzip' else zlib.compress(payload)
    result=service(handler=lambda request:httpx.Response(200,headers={'content-type':'application/json','content-encoding':encoding},stream=httpx.ByteStream(encoded))).search(listing_type='activity')
    assert result['search_state']=='live' and result['total_count']==1


def test_valid_english_url_fallback_preserves_original():
    item = service([row(TC_URL=None)]).search(listing_type='activity')['items'][0]
    assert item['source_url'] == row()['EN_URL']


def test_absent_age_fee_and_non_sentinel_upper_age_are_not_invented():
    item = service([row(MIN_AGE=None,MAX_AGE=None,FEE=None)]).search(listing_type='activity')['items'][0]
    assert item['eligibility_en']=='Elderly' and 'HK$' not in item['summary_en']
    item = service([row(MIN_AGE=60,MAX_AGE=75,FEE=25.5)]).search(listing_type='activity')['items'][0]
    assert '60' in item['eligibility_en'] and '75' in item['eligibility_en'] and 'HK$25.5' in item['summary_en']


def test_official_notes_arrays_preserve_order_nulls_and_all_records():
    result=service([row(TC_NOTES=['自備午膳',None,'安排請見來源'],EN_NOTES=['Bring your own meal',None,'See official arrangements'])]).search(listing_type='activity')
    assert result['total_count']==1
    assert '自備午膳；安排請見來源' in result['items'][0]['summary']
    assert 'Bring your own meal; See official arrangements' in result['items'][0]['summary_en']


@pytest.mark.parametrize('notes', [[{}], [1], ['x']*101])
def test_bad_notes_array_is_parse_failure(notes):
    assert service([row(TC_NOTES=notes)]).search(listing_type='activity')['search_reason']=='parse_failed'


def test_total_deadline_observed_on_small_raw_chunks_before_buffer_completes(monkeypatch):
    adapter=module()
    elapsed=[0]
    emitted=[]
    class Drip(httpx.SyncByteStream):
        def __iter__(self):
            for _ in range(100):
                elapsed[0] += 20
                emitted.append('chunk')
                yield b' '
    monkeypatch.setattr(adapter.time,'monotonic',lambda:elapsed[0])
    result=service(handler=lambda request:httpx.Response(200,headers={'content-type':'application/json'},stream=Drip())).search(listing_type='activity')
    assert result['search_reason']=='source_unavailable'
    assert len(emitted)==3


def test_refresh_crossing_hong_kong_midnight_filters_at_completion():
    now=[datetime(2026,10,4,15,59,50,tzinfo=timezone.utc)]
    def handler(request):
        now[0]+=timedelta(seconds=20)
        return httpx.Response(200,json=[row(PGM_START_DATE='2026-10-01',PGM_END_DATE='2026-10-04')])
    result=service(handler=handler,clock=lambda:now[0]).search(listing_type='activity')
    assert result['total_count']==0 and result['search_reason']=='no_matches'
    assert result['checked_at']==now[0] and result['requested_at']==now[0]


def test_refresh_failure_crossing_six_hour_stale_boundary_does_not_show_expired_cache():
    now=[NOW]
    search=service(clock=lambda:now[0])
    search.search(listing_type='activity')
    now[0]=NOW+timedelta(hours=6,seconds=-10)
    def handler(request):
        now[0]+=timedelta(seconds=20)
        return httpx.Response(503)
    search.transport=httpx.MockTransport(handler)
    result=search.search(listing_type='activity')
    assert result['search_state']=='unavailable' and result['items']==[]
    assert result['checked_at'] is None and result['search_reason']=='source_unavailable'


@pytest.mark.parametrize('payload', [None,{},[{}],[row(),row()], [row(PGM_START_DATE='nonsense')], [row(PGM_START_DATE='2026-11-01')], [row(ACTIVITY_NO='bad/id')], [row(EN_PGM_NAME=[])], [row(EN_TARGET_GRP=[])]] )
def test_invalid_snapshot_fails_atomically(payload):
    result = service(handler=lambda request: httpx.Response(200,json=payload)).search(listing_type='activity')
    assert result['search_reason'] == 'parse_failed' and result['checked_at'] is None


def test_empty_valid_snapshot_is_live_no_matches():
    result = service([]).search(listing_type='activity')
    assert result['search_state'] == 'live' and result['search_reason'] == 'no_matches'
    assert result['checked_at'] == NOW


@pytest.mark.parametrize('kind,reason', [('redirect','source_unavailable'),('timeout','source_unavailable'),('http503','source_unavailable'),('mime','parse_failed'),('json','parse_failed')])
def test_failures_and_cooldown_do_not_claim_live(kind, reason):
    calls = []
    def handler(request):
        calls.append(request)
        if kind=='timeout': raise httpx.ReadTimeout('timeout', request=request)
        if kind=='redirect': return httpx.Response(302,headers={'location':'https://evil.test/'})
        if kind=='http503': return httpx.Response(503)
        if kind=='mime': return httpx.Response(200,headers={'content-type':'text/html'},text='[]')
        return httpx.Response(200,headers={'content-type':'application/json'},text='broken')
    search = service(handler=handler)
    for _ in range(3):
        result = search.search(listing_type='activity')
        assert result['search_reason']==reason and result['search_state']=='unavailable'
        assert result['sources'][0]['error_kind']==reason and result['checked_at'] is None
    assert len(calls)==1


def test_cache_stale_failure_preserves_timestamp_then_expires_and_recovers():
    now = [NOW]
    healthy = [True]
    search = service(handler=lambda request: httpx.Response(200,json=[row()]) if healthy[0] else httpx.Response(503),clock=lambda:now[0])
    live = search.search(listing_type='activity')
    assert live['search_state']=='live'
    assert search.search(listing_type='activity')['search_state']=='cache'
    now[0] += timedelta(seconds=601)
    healthy[0]=False
    stale = search.search(listing_type='activity')
    assert stale['search_reason']=='stale_cache' and stale['checked_at']==NOW
    assert stale['items'][0]['last_checked_at']==NOW
    now[0] += timedelta(hours=6)
    expired = search.search(listing_type='activity')
    assert expired['search_state']=='unavailable' and expired['checked_at'] is None
    now[0] += timedelta(seconds=61)
    healthy[0]=True
    assert search.search(listing_type='activity')['checked_at']==now[0]


def test_parse_failure_never_replaces_valid_cache():
    now = [NOW]
    rows = [[row()]]
    search = service(handler=lambda request: httpx.Response(200,json=rows[0]),clock=lambda:now[0])
    search.search(listing_type='activity')
    now[0] += timedelta(seconds=601)
    rows[0] = [row('NEW'),{}]
    stale = search.search(listing_type='activity')
    assert [item['id'] for item in stale['items']]==['lcsd-smartplay:ST260015HES']
    assert stale['search_reason']=='stale_cache' and stale['sources'][0]['error_kind']=='parse_failed'


def test_single_flight_shares_one_fetch_across_concurrent_searches():
    entered = threading.Event()
    release = threading.Event()
    calls=[]
    def handler(request):
        calls.append(request)
        entered.set()
        assert release.wait(3)
        return httpx.Response(200,json=[row()])
    search = service(handler=handler)
    with ThreadPoolExecutor(max_workers=5) as pool:
        first=pool.submit(search.search,listing_type='activity')
        assert entered.wait(3)
        others=[pool.submit(search.search,listing_type='activity') for _ in range(4)]
        release.set()
        results=[first.result()]+[future.result() for future in others]
    assert len(calls)==1
    assert all(result['total_count']==1 for result in results)
    assert sum(result['search_state']=='live' for result in results)==1


def test_bounds_decompressed_payload_rows_and_total_time(monkeypatch):
    adapter=module()
    monkeypatch.setattr(adapter,'MAX_BYTES',100)
    encoded=gzip.compress(json.dumps([row()]).encode())
    result=service(handler=lambda request:httpx.Response(200,headers={'content-type':'application/json','content-encoding':'gzip'},stream=httpx.ByteStream(encoded))).search(listing_type='activity')
    assert result['search_reason']=='source_unavailable'
    monkeypatch.setattr(adapter,'MAX_BYTES',20*1024*1024)
    monkeypatch.setattr(adapter,'MAX_ROWS',1)
    assert service([row('A'),row('B')]).search(listing_type='activity')['search_reason']=='parse_failed'
    monkeypatch.setattr(adapter,'MAX_ROWS',10000)
    ticks=iter([0,0,100,100])
    monkeypatch.setattr(adapter.time,'monotonic',lambda:next(ticks,100))
    assert service().search(listing_type='activity')['search_reason']=='source_unavailable'


def test_actual_app_registers_only_smartplay_and_exposes_bilingual_pagination():
    adapter=module()
    app=create_app(Settings(database_url='sqlite:///:memory:',auth_secret='synthetic-smartplay',demo_mode=True))
    assert isinstance(app.state.community_search,adapter.SmartPlayCommunitySearch)
    app.state.community_search=service([row(f'ID{i}') for i in range(3)])
    with TestClient(app) as client:
        response=client.get('/community/activities',params={'topic':'table_tennis','target_group':'elderly','offset':1,'limit':1})
        assert response.status_code==200,response.text
        body=response.json()
        assert body['total_count']==3 and body['offset']==1 and body['limit']==1 and body['has_more']
        assert body['items'][0]['title_en']==row()['EN_PGM_NAME']
        for params in ({'limit':0},{'limit':41},{'offset':-1},{'target_group':'adult'},{'topic':'arbitrary'}):
            assert client.get('/community/activities',params=params).status_code==422
