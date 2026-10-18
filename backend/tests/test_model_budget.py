"""Offline competition safeguards; all credentials and responses are synthetic."""
import asyncio
import json
import logging
import os

import httpx
import pytest

from app.config import Settings
from app.llm import OpenAICompatibleAdapter

REAL_CLIENT = httpx.AsyncClient
SYNTHETIC_KEY = 'synthetic-only-not-a-real-credential'


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    async def forbidden(*args, **kwargs):
        raise AssertionError('External model calls are forbidden')
    monkeypatch.setattr(httpx.AsyncHTTPTransport, 'handle_async_request', forbidden)


def settings(**changes):
    return Settings(model_api_key=SYNTHETIC_KEY,
                    model_base_url='https://competition.example.invalid/v1',
                    model_name='qwen3.8-flash', **changes)


def synthetic_env(monkeypatch, **changes):
    # Replace the environment, do not inspect/copy host credentials.
    monkeypatch.setattr(os, 'environ', {'APP_ENV': 'test', 'DEMO_MODE': 'true', **changes})


def test_default_output_limit_is_bounded():
    assert settings().model_max_output_tokens == 1024


@pytest.mark.parametrize('value', [1, 1024, 4096])
def test_output_limit_accepts_only_documented_boundaries(value):
    assert settings(model_max_output_tokens=value).model_max_output_tokens == value


@pytest.mark.parametrize('value', [0, -1, 4097, True, False, 1.5, '1024', None])
def test_direct_settings_reject_invalid_output_limit_without_echo(value):
    with pytest.raises(ValueError, match='MODEL_MAX_OUTPUT_TOKENS'):
        settings(model_max_output_tokens=value)


@pytest.mark.parametrize('value', ['0', '-1', '4097', '1.5', 'true', '', 'synthetic-private-value'])
def test_environment_rejects_invalid_limit_without_echo(monkeypatch, value):
    synthetic_env(monkeypatch, MODEL_MAX_OUTPUT_TOKENS=value)
    with pytest.raises(ValueError) as error:
        Settings.from_env()
    assert str(error.value) == 'MODEL_MAX_OUTPUT_TOKENS must be an integer from 1 to 4096'


def test_environment_loads_output_limit_and_stays_demo(monkeypatch):
    synthetic_env(monkeypatch, MODEL_MAX_OUTPUT_TOKENS='512')
    config = Settings.from_env()
    assert config.model_max_output_tokens == 512
    assert config.using_demo_mode


def test_settings_repr_hides_both_synthetic_secrets():
    config = settings(auth_secret='synthetic-auth-private')
    assert SYNTHETIC_KEY not in repr(config)
    assert 'synthetic-auth-private' not in repr(config)


@pytest.mark.parametrize('limit', [1, 1024, 4096])
@pytest.mark.parametrize('strict', [False, True])
def test_output_cap_is_sent_on_chat_and_readonly_paths(monkeypatch, limit, strict):
    seen = []
    def provider(request):
        seen.append(json.loads(request.content))
        assert request.headers['authorization'] == 'Bearer '+SYNTHETIC_KEY
        return httpx.Response(200, json={'choices': [{'finish_reason': 'stop', 'message': {
            'content': json.dumps({'text': 'Synthetic response', 'proposed_task': None, 'memory_actions': []})}}]})
    monkeypatch.setattr(httpx, 'AsyncClient', lambda **kw: REAL_CLIENT(transport=httpx.MockTransport(provider), **kw))
    reply = asyncio.run(OpenAICompatibleAdapter(settings(model_max_output_tokens=limit)).reply({}, 'Synthetic request', strict_readonly=strict))
    assert reply.mode == 'openai_compatible'
    assert len(seen) == 1
    assert seen[0]['max_tokens'] == limit
    assert SYNTHETIC_KEY not in json.dumps(seen)


@pytest.mark.parametrize('failure', [400, 401, 403, 429, 500, 503, 'timeout', 'malformed'])
def test_failures_make_one_attempt_without_leaking_secrets(monkeypatch, caplog, failure):
    attempts = []
    timeouts = []
    def provider(request):
        attempts.append(request)
        if failure == 'timeout':
            raise httpx.ReadTimeout(SYNTHETIC_KEY, request=request)
        if failure == 'malformed':
            return httpx.Response(200, text=SYNTHETIC_KEY)
        return httpx.Response(failure, text=SYNTHETIC_KEY)
    def client(**kw):
        timeouts.append(kw['timeout'])
        return REAL_CLIENT(transport=httpx.MockTransport(provider), **kw)
    monkeypatch.setattr(httpx, 'AsyncClient', client)
    with caplog.at_level(logging.INFO):
        reply = asyncio.run(OpenAICompatibleAdapter(settings()).reply({}, 'Synthetic request'))
    assert reply.mode == 'error'
    assert reply.proposed_task is None and reply.memory_actions == []
    assert len(attempts) == 1  # Zero automatic retries, including throttling.
    assert timeouts == [45.0]
    assert SYNTHETIC_KEY not in repr(reply)
    assert SYNTHETIC_KEY not in caplog.text
