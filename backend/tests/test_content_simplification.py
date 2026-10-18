"""Synthetic-only contract tests. Real HTTP transport is forbidden."""
import asyncio
import importlib
import json

import httpx
import pytest

from app.config import Settings

ORIGINAL = ('The fictional neighborhood club is a place where local people gather '
            'to talk with one another and enjoy friendly company.')
SIMPLER = 'At the fictional neighborhood club, local people meet and chat.'
REAL_CLIENT = httpx.AsyncClient


@pytest.fixture(autouse=True)
def forbid_real_network(monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError('Real network is forbidden in simplification tests')
    async def no_real_transport(*args, **kwargs):
        raise AssertionError('Real HTTP transport is forbidden')
    monkeypatch.setattr(httpx.AsyncHTTPTransport, 'handle_async_request', no_real_transport)
    monkeypatch.setattr(httpx, 'AsyncClient', forbidden)


def module():
    try:
        return importlib.import_module('app.content_simplification')
    except ModuleNotFoundError:
        pytest.fail('No independent read-only simplification service exists yet')


def settings(**changes):
    return Settings(model_api_key='synthetic-not-a-secret',
                    model_base_url='https://model.example.invalid/v1',
                    model_name='existing-synthetic-model', **changes)


def provider(monkeypatch, text=SIMPLER, *, status=200, memory_actions=None,
             proposed_task=None, raw_content=None, finish_reason='stop'):
    seen = []
    def handler(request):
        seen.append(json.loads(request.content))
        parsed = dict(text=text, proposed_task=proposed_task,
                      memory_actions=memory_actions or [])
        return httpx.Response(status, json={'choices': [{'finish_reason': finish_reason, 'message': {
            'content': raw_content if raw_content is not None else json.dumps(parsed)}}]})
    monkeypatch.setattr(httpx, 'AsyncClient', lambda **kw:
        REAL_CLIENT(transport=httpx.MockTransport(handler), **kw))
    return seen


def run(service, original=ORIGINAL, **kwargs):
    return asyncio.run(service.simplify(original, **kwargs))


def test_explicit_request_reuses_existing_adapter_without_private_context(monkeypatch):
    seen = provider(monkeypatch)
    service = module().ContentSimplificationService(settings())
    result = run(service, explicitly_requested=True, locale='en')
    assert result.status == 'draft'
    assert result.original == ORIGINAL
    assert result.simpler == SIMPLER
    assert result.independently_verified is False
    assert result.reason is None
    assert len(seen) == 1
    assert seen[0]['model'] == 'existing-synthetic-model'
    assert len(seen[0]['messages']) == 2  # Existing adapter receives empty context.
    payload = json.loads(seen[0]['messages'][-1]['content'])
    assert payload['selected_answer'] == ORIGINAL
    assert payload['language'] == 'en'
    assert 'memory_id' not in payload and 'conversation_id' not in payload


@pytest.mark.parametrize('action,locale', [(False, 'en'), (True, 'fr')])
def test_no_automatic_or_unsupported_language_call(action, locale):
    result = run(module().ContentSimplificationService(settings()),
                 explicitly_requested=action, locale=locale)
    assert result.status == 'unavailable'
    assert result.original == ORIGINAL and result.simpler is None


@pytest.mark.parametrize('text', ['', '  ', 'x' * 10001, None],
                         ids=['empty', 'blank', 'overlength', 'non-string'])
def test_invalid_input_is_rejected_whole_without_truncation(text):
    result = run(module().ContentSimplificationService(settings()), original=text,
                 explicitly_requested=True, locale='en')
    assert result.status == 'unavailable'
    assert result.simpler is None
    assert result.reason == 'invalid_input'


@pytest.mark.parametrize('cfg', [Settings(), settings(demo_mode=True)])
def test_missing_model_or_demo_never_pretends_to_simplify(cfg):
    result = run(module().ContentSimplificationService(cfg), explicitly_requested=True)
    assert result.status == 'unavailable'
    assert result.reason == 'model_unavailable'
    assert result.simpler is None and result.original == ORIGINAL


@pytest.mark.parametrize('text,status,raw', [
    ('', 200, None), (SIMPLER, 503, None),
    (SIMPLER, 200, {'not': 'a string'}),
    (ORIGINAL, 200, None), ('x' * 10000, 200, None),
    (ORIGINAL[:35], 200, None),
], ids=['empty', 'http-error', 'malformed', 'unchanged', 'adapter-limit', 'prefix-only'])
def test_failure_empty_unchanged_and_prefix_do_not_claim_success(monkeypatch, text, status, raw):
    provider(monkeypatch, text=text, status=status, raw_content=raw)
    result = run(module().ContentSimplificationService(settings()), explicitly_requested=True)
    assert result.status == 'unavailable'
    assert result.original == ORIGINAL and result.simpler is None


RESTRICTIONS = ('Only people aged 60 or above may attend. '
                'Registration closes on 2026-11-01. '
                'This does not guarantee a place. '
                'Official source: https://example.invalid/program')


def test_critical_conditions_and_source_must_remain_verbatim(monkeypatch):
    provider(monkeypatch, text=SIMPLER + '\n' + RESTRICTIONS)
    original = ORIGINAL + '\n' + RESTRICTIONS
    result = run(module().ContentSimplificationService(settings()), original=original,
                 explicitly_requested=True, locale='en')
    assert result.status == 'draft' and result.original == original
    assert RESTRICTIONS in result.simpler


@pytest.mark.parametrize('draft', [SIMPLER,
    SIMPLER + '\n' + RESTRICTIONS.replace('60', '65'),
    SIMPLER + '\n' + RESTRICTIONS.replace('does not guarantee', 'guarantees'),
    SIMPLER + '\n' + RESTRICTIONS.replace('example.invalid', 'different.invalid'),
    SIMPLER + '\n' + RESTRICTIONS + ' Meet at 09:00.',
])
def test_critical_drift_fails_closed(monkeypatch, draft):
    provider(monkeypatch, text=draft)
    result = run(module().ContentSimplificationService(settings()),
                 original=ORIGINAL + '\n' + RESTRICTIONS, explicitly_requested=True)
    assert result.status == 'unavailable' and result.reason == 'unsafe_draft'
    assert result.simpler is None


def test_task_or_memory_action_is_never_executed_or_presented(monkeypatch):
    provider(monkeypatch, memory_actions=[dict(action='forget', memory_id='synthetic-id',
        content=None, kind='preference', sensitivity='ordinary', topic_key=None,
        evidence='forget synthetic preference')])
    result = run(module().ContentSimplificationService(settings()), explicitly_requested=True)
    # The strict adapter now rejects the action envelope before the service
    # can receive it, returning the ordinary sanitized provider-error mode.
    assert result.status == 'unavailable' and result.reason == 'provider_error'
    assert result.simpler is None


def test_cancellation_propagates_and_does_not_return_a_success(monkeypatch):
    async def exercise():
        started = asyncio.Event()
        async def handler(request):
            started.set()
            await asyncio.Future()
        monkeypatch.setattr(httpx, 'AsyncClient', lambda **kw:
            REAL_CLIENT(transport=httpx.MockTransport(handler), **kw))
        service = module().ContentSimplificationService(settings())
        task = asyncio.create_task(service.simplify(ORIGINAL, explicitly_requested=True))
        await asyncio.wait_for(started.wait(), timeout=2)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(exercise())


def test_chinese_constraints_are_preserved_instead_of_silently_dropped(monkeypatch):
    original = '這是虛構的鄰里聚會。只限60歲或以上人士。不可保證名額。請先向主辦方確認。'
    provider(monkeypatch, text='大家聚在一起聊天。')
    result = run(module().ContentSimplificationService(settings()), original=original,
                 explicitly_requested=True, locale='zh-Hant')
    assert result.status == 'unavailable' and result.simpler is None


@pytest.mark.parametrize('warning', ["Don't share your password.",
    'Don’t share your password.', "You shouldn't share your password.",
    'You can’t share your password.', '請勿分享密碼。', '不要分享密碼。',
    '切勿分享密碼。', '禁止分享密碼。'])
def test_negated_warning_cannot_be_reversed_in_a_draft(monkeypatch, warning):
    provider(monkeypatch, text='Share your password. People chat at the fictional club.')
    result = run(module().ContentSimplificationService(settings()),
                 original=warning + '\n' + ORIGINAL, explicitly_requested=True)
    assert result.status == 'unavailable' and result.reason == 'unsafe_draft'


@pytest.mark.parametrize('finish,raw', [
    ('length', '{"text": "People chat'),
    ('length', None),
    ('stop', '{"text": "People chat'),
    (None, None),
], ids=['truncated-json', 'length-with-valid-json', 'invalid-json-with-stop', 'missing-completion'])
def test_incomplete_or_unstructured_provider_response_is_never_a_draft(monkeypatch, finish, raw):
    provider(monkeypatch, finish_reason=finish, raw_content=raw)
    result = run(module().ContentSimplificationService(settings()), explicitly_requested=True)
    assert result.status == 'unavailable'
    assert result.simpler is None


@pytest.mark.parametrize('finish', ['length', None])
def test_strict_path_does_not_change_existing_chat_default(monkeypatch, finish):
    from app.llm import OpenAICompatibleAdapter
    provider(monkeypatch, finish_reason=finish)
    adapter = OpenAICompatibleAdapter(settings())
    ordinary = asyncio.run(adapter.reply({}, 'Synthetic ordinary chat'))
    strict = asyncio.run(adapter.reply({}, 'Synthetic display draft', strict_readonly=True))
    assert ordinary.mode == 'openai_compatible' and ordinary.text == SIMPLER
    assert strict.mode == 'error' and strict.proposed_task is None and strict.memory_actions == []


@pytest.mark.parametrize('raw', ['null', '[]', 'not JSON',
    '{"text":"Synthetic wording","proposed_task":null,"memory_actions":[],"unexpected":true}'])
def test_strict_path_rejects_fallback_and_unexpected_schema(monkeypatch, raw):
    provider(monkeypatch, raw_content=raw)
    result = run(module().ContentSimplificationService(settings()), explicitly_requested=True)
    assert result.status == 'unavailable' and result.simpler is None
