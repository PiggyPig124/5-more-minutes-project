"""Public payload privacy contracts using only synthetic text and reviewed fixtures."""
import hashlib
import importlib.util
import json

import pytest
from pydantic import ValidationError


def service():
    assert importlib.util.find_spec('app.answer_card_service') is not None, 'AnswerCard service is not implemented'
    from app import answer_card_service
    return answer_card_service


def test_exact_three_templates_keep_original_dates_sources_and_scope():
    cards = service().templates()
    assert len(cards) == 3 and len({x['template_id'] for x in cards}) == 3
    for card in cards:
        public = card['public_payload']
        assert public['verification_state'] == 'reviewed_public_guidance'
        assert len(public['next_steps']) == 3
        assert public['public_sources'] and public['verification_scope']
        assert all(s['reviewed_at'] == '2026-10-03' for s in public['public_sources'])
        assert all(s['url'].startswith('https://') for s in public['public_sources'])


def test_public_payload_rejects_hidden_fields_and_nested_private_metadata():
    svc = service()
    valid = svc.templates()[0]['public_payload']
    for key in ('owner_id', 'conversation_id', 'memory_ids', 'metadata', 'origin_message_id'):
        with pytest.raises(ValidationError):
            svc.CardPublicPayload.model_validate({**valid, key: 'private'})
    source = {**valid['public_sources'][0], 'metadata': {'token': 'private'}}
    with pytest.raises(ValidationError):
        svc.CardPublicPayload.model_validate({**valid, 'public_sources': [source]})


@pytest.mark.parametrize('mode,edited,sources,expected', [
    ('assistant_answer', False, True, 'ai_unverified'),
    ('assistant_answer', True, True, 'user_edited_unverified'),
    ('assistant_answer', False, False, 'no_verified_source'),
    ('public_template', True, True, 'user_edited_unverified'),
    ('public_template', False, False, 'no_verified_source'),
])
def test_verification_never_upgrades_ai_or_edited_or_missing_source(mode, edited, sources, expected):
    assert service().verification_state(mode, edited, sources, True) == expected


def test_canonical_unicode_hash_uses_utf8_and_preserves_nulls_and_order():
    svc = service()
    public = svc.templates()[1]['public_payload']
    public = {**public, 'title': '繁中 👩🏽‍💻 e\u0301 <script>',
              'public_sources': [{**public['public_sources'][0], 'effective_date': None}]}
    wire = json.dumps(public, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
    assert svc.payload_hash(public) == hashlib.sha256(wire).hexdigest()
    assert svc.canonical_bytes(public) == wire
    assert b'null' in wire and '<script>'.encode() in wire


def test_payload_limits_refuse_without_truncating():
    svc = service()
    valid = svc.templates()[0]['public_payload']
    for changes in ({'title': 'a' * 241}, {'selected_sections': ['x' * 4001]},
                    {'selected_sections': ['x' * 4000] * 5}, {'next_steps': ['a'] * 11}):
        with pytest.raises((ValidationError, ValueError)):
            svc.validate_payload({**valid, **changes})


def test_sections_are_hash_index_ids_and_do_not_guess_terms_or_next_steps():
    svc = service()
    text = 'Private first paragraph\n\nPublic second paragraph 👩🏽‍💻'
    sections = svc.split_sections(text)
    digest = hashlib.sha256(text.encode('utf-8')).hexdigest()
    assert sections == [{'id': digest + ':0', 'text': 'Private first paragraph'},
                        {'id': digest + ':1', 'text': 'Public second paragraph 👩🏽‍💻'}]


def test_sources_do_not_trust_arbitrary_message_metadata():
    svc = service()
    metadata = {'memory_sources': [{'title': 'private', 'url': 'https://evil.test/token'}],
                'resource_sources': [{'source_id': 'unknown', 'title': 'private diagnosis',
                                     'url': 'https://www.swd.gov.hk/?token=private', 'verified_at': '2099-01-01'}]}
    assert svc.sanitized_sources(metadata) == []


def test_bound_sources_are_reconstructed_not_copied_from_private_metadata():
    svc = service()
    canonical = svc.templates()[0]['public_payload']['public_sources'][0]
    ref = {**canonical, 'title': 'Synthetic private diagnosis', 'url': 'https://evil.test/?token=private',
           'reviewed_at': '2099-01-01'}
    assert svc.sanitized_sources({'resource_sources': [ref]}) == [canonical]
    assert svc.sanitized_sources({'resource_sources': [{**ref, 'content_hash': 'a' * 64}]}) == []


def test_template_hash_binds_body_sources_scope_and_version():
    svc = service()
    card = svc.templates()[0]
    bound = {k: card[k] for k in ('template_id', 'template_version', 'sections', 'public_payload')}
    assert card['template_hash'] == svc.payload_hash(bound)
    mutated = {**bound, 'public_payload': {**bound['public_payload'], 'verification_scope': 'Changed scope'}}
    assert svc.payload_hash(mutated) != card['template_hash']


def test_malformed_nested_source_ids_are_ignored_without_leaking_or_crashing():
    svc = service()
    refs = [{'source_id': ['private'], 'content_hash': 'a' * 64},
            {'source_id': {'private': 'value'}}, None, 'private']
    assert svc.sanitized_sources({'resource_sources': refs}) == []


def test_utf8_byte_budget_refuses_large_emoji_card_even_with_valid_character_limits():
    svc = service()
    valid = svc.templates()[0]['public_payload']
    # 16000 code points are 64000 UTF-8 bytes; sources/other public fields push
    # the full wire beyond65536. No silently dropping sources or truncation.
    with pytest.raises(ValueError, match='export limit'):
        svc.validate_payload({**valid, 'selected_sections': ['🙂' * 4000] * 4})


def test_empty_or_whitespace_public_selection_cannot_become_an_exportable_card():
    svc = service()
    valid = svc.templates()[0]['public_payload']
    for changes in ({'selected_sections': []}, {'next_steps': ['  ']}, {'official_terms': ['  ']}):
        with pytest.raises(ValidationError):
            svc.validate_payload({**valid, **changes})


@pytest.mark.parametrize('boundary', ['private-top', 'private-section', 'missing-payload', 'string-version'])
def test_template_envelope_and_sections_are_closed_and_invalid_data_fails_as_value_error(boundary):
    svc = service()
    rows = [{k: v for k, v in row.items() if k != 'template_hash'} for row in svc.templates()]
    if boundary == 'private-top': rows[0]['owner_email'] = 'private@example.invalid'
    if boundary == 'private-section': rows[0]['sections'][0]['metadata'] = 'private'
    if boundary == 'missing-payload': rows[0].pop('public_payload')
    if boundary == 'string-version': rows[0]['template_version'] = '1'
    with pytest.raises(ValueError):
        svc.validate_templates(rows)
