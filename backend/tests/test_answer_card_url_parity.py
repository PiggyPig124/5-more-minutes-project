"""Backend counterparts of strict Flutter source URL validation variants."""
import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from app import answer_card_service as public


def source(url):
    return public.PublicSource(source_id='synthetic-parity', organisation='Synthetic',
        title='Synthetic', url=url, verification_scope='Synthetic URL policy only')


BASE = 'https://www.ha.org.hk/visitors/ha_visitor_guide.asp'
HA_QUERY = BASE + '?Content_ID=100826'
CSDI_QUERY = 'https://portal.csdi.gov.hk/csdi-webpage/?datasetId=swd_rcd_1696994103126_1549'


VECTOR_PATH = Path(public.__file__).resolve().parent.parent / 'tests' / 'fixtures' / 'answer_card_url_parity.json'
VECTORS = json.loads(VECTOR_PATH.read_text(encoding='utf-8'))['vectors']


@pytest.mark.parametrize('vector', VECTORS, ids=lambda v: v['id'])
def test_strict_url_vectors_match_flutter(vector):
    if vector['allowed']:
        assert source(vector['url']).url == vector['url']
    else:
        with pytest.raises(ValidationError):
            source(vector['url'])


def test_current_manifest_templates_and_precise_query_exceptions_remain_valid():
    manifest = Path(public.__file__).resolve().parent.parent / 'data' / 'hk_resources.json'
    urls = [r['url'] for r in json.loads(manifest.read_text(encoding='utf-8'))]
    urls.extend(s['url'] for t in public.templates() for s in t['public_payload']['public_sources'])
    urls.extend([HA_QUERY, CSDI_QUERY])
    for url in urls:
        assert source(url).url == url
