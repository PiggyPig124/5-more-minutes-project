"""Speech contract tests. Every provider call is mocked; no live credentials."""

import asyncio
import base64
import io
import sys
import threading
import types
import wave
from types import SimpleNamespace

import pytest
from fastapi import FastAPI, Response
from fastapi.testclient import TestClient

from app.db import get_db
from app.dependencies import get_current_account
from app.models import Account
from app.routers import speech
from app.schemas import TranscriptionRequest


def _wav(frames=1600, rate=16000, channels=1, width=2):
    data = io.BytesIO()
    with wave.open(data, "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(width)
        output.setframerate(rate)
        output.writeframes(b"\0" * frames * channels * width)
    return data.getvalue()


def _payload(audio=None, **changes):
    result = {
        "audio_base64": base64.b64encode(_wav() if audio is None else audio).decode("ascii"),
        "format": "wav", "sample_rate": 16000, "language_hint": "yue-HK",
        "audio_processing_consent": True,
    }
    result.update(changes)
    return result


@pytest.fixture
def client(monkeypatch):
    monkeypatch.delenv("TENCENT_ASR_SECRET_ID", raising=False)
    monkeypatch.delenv("TENCENT_ASR_SECRET_KEY", raising=False)
    app = FastAPI()
    app.include_router(speech.router)
    app.dependency_overrides[get_current_account] = lambda: Account(id="owner", role="elder")
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def sdk(monkeypatch):
    """Fake only the official SDK boundary, leaving the adapter under test."""
    monkeypatch.setenv("TENCENT_ASR_SECRET_ID", "test-only-id")
    monkeypatch.setenv("TENCENT_ASR_SECRET_KEY", "test-only-key")
    state = SimpleNamespace(calls=[], result="Recognized words", error=None)

    class Client:
        def __init__(self, credentials, region, profile):
            state.credentials, state.region, state.profile = credentials, region, profile

        def SentenceRecognition(self, request):
            state.calls.append(request)
            state.thread_id = threading.get_ident()
            if state.error:
                raise state.error
            return SimpleNamespace(Result=state.result)

    modules = {
        "tencentcloud": {},
        "tencentcloud.common": {"credential": SimpleNamespace(Credential=lambda *args: args)},
        "tencentcloud.common.profile": {},
        "tencentcloud.common.profile.client_profile": {"ClientProfile": SimpleNamespace},
        "tencentcloud.common.profile.http_profile": {"HttpProfile": SimpleNamespace},
        "tencentcloud.asr": {},
        "tencentcloud.asr.v20190614": {
            "asr_client": SimpleNamespace(AsrClient=Client),
            "models": SimpleNamespace(SentenceRecognitionRequest=SimpleNamespace),
        },
    }
    for name, attributes in modules.items():
        module = types.ModuleType(name)
        module.__dict__.update(attributes)
        monkeypatch.setitem(sys.modules, name, module)
    return state


def test_unconfigured_is_503_not_demo(client):
    response = client.post("/speech/transcribe", json=_payload())
    assert response.status_code == 503
    assert "transcript" not in response.json()
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.parametrize("consent", [None, False, "true", 1])
def test_explicit_boolean_consent_required(client, sdk, consent):
    payload = _payload(audio_processing_consent=consent)
    if consent is None:
        payload.pop("audio_processing_consent")
    response = client.post("/speech/transcribe", json=payload)
    assert response.status_code == 422
    assert sdk.calls == []


@pytest.mark.parametrize("value", ["!!!!", "abcd\n", "AA=", "AB==", "é"])
def test_strict_base64(client, sdk, value):
    response = client.post("/speech/transcribe", json=_payload(audio_base64=value))
    assert response.status_code == 400
    assert sdk.calls == []


@pytest.mark.parametrize("changes", [
    {"format": "webm"}, {"format": "mp3"}, {"format": "m4a"},
    {"language_hint": "unknown"}, {"sample_rate": 44100}, {"sample_rate": 8000},
    {"EngSerViceType": "unsupported"}, {"duration_seconds": 1},
])
def test_unsupported_input_rejected(client, sdk, changes):
    assert client.post("/speech/transcribe", json=_payload(**changes)).status_code == 422
    assert sdk.calls == []


@pytest.mark.parametrize("audio", [
    b"not a WAV" * 100, _wav(rate=8000), _wav(channels=2), _wav(width=1),
    _wav(frames=0), _wav()[:-10], _wav(frames=960001),
], ids=['invalid', 'rate', 'stereo', 'width', 'empty', 'truncated', 'long'])
def test_wav_validation_before_provider(client, sdk, audio):
    assert client.post("/speech/transcribe", json=_payload(audio)).status_code == 400
    assert sdk.calls == []


@pytest.mark.parametrize("audio", [b"x", b"\0" * 1920002], ids=['unaligned', 'long'])
def test_pcm_alignment_and_duration(client, sdk, audio):
    assert client.post("/speech/transcribe", json=_payload(audio, format="pcm")).status_code == 400
    assert sdk.calls == []


def test_encoded_size_limit(client, sdk):
    response = client.post("/speech/transcribe", json=_payload(audio_base64="A" * 3_000_004))
    assert response.status_code == 422
    assert sdk.calls == []


@pytest.mark.parametrize("language, model", [
    ("yue-HK", "16k_yue"), ("zh-HK", "16k_zh-PY"), ("zh", "16k_zh"), ("en", "16k_en"),
])
def test_sdk_request_contract(client, sdk, language, model):
    audio = _wav()
    response = client.post("/speech/transcribe", json=_payload(audio, language_hint=language))
    assert response.status_code == 200, response.text
    assert response.json() == {"transcript": sdk.result, "language": language,
                               "confidence": None, "mode": "tencent_asr"}
    assert response.headers["cache-control"] == "no-store"
    assert vars(sdk.calls[0]) == {
        "EngSerViceType": model, "SourceType": 1, "VoiceFormat": "wav",
        "Data": base64.b64encode(audio).decode("ascii"), "DataLen": len(audio),
    }
    assert sdk.profile.signMethod == "TC3-HMAC-SHA256"
    assert sdk.profile.httpProfile.endpoint == "asr.tencentcloudapi.com"
    assert sdk.profile.httpProfile.reqTimeout == 30
    assert sdk.region == ""


@pytest.mark.parametrize("format", ["wav", "pcm"])
def test_accepts_exact_duration_limit(client, sdk, format):
    audio = _wav(frames=960000) if format == "wav" else b"\0" * 1920000
    assert client.post("/speech/transcribe", json=_payload(audio, format=format)).status_code == 200
    assert sdk.calls[0].VoiceFormat == format


@pytest.mark.parametrize("result", ["", "   ", None, 42])
def test_empty_or_malformed_provider_result_is_502(client, sdk, result):
    sdk.result = result
    response = client.post("/speech/transcribe", json=_payload())
    assert response.status_code == 502
    assert "transcript" not in response.json()


def test_provider_failure_is_redacted_502(client, sdk):
    sdk.error = RuntimeError("sensitive audio and test-only-key")
    response = client.post("/speech/transcribe", json=_payload())
    assert response.status_code == 502
    assert "test-only-key" not in response.text
    assert "sensitive" not in response.text
    assert response.headers["cache-control"] == "no-store"


def test_missing_sdk_is_503(client, monkeypatch):
    monkeypatch.setenv("TENCENT_ASR_SECRET_ID", "test-only-id")
    monkeypatch.setenv("TENCENT_ASR_SECRET_KEY", "test-only-key")
    monkeypatch.setitem(sys.modules, "tencentcloud.common", None)
    assert client.post("/speech/transcribe", json=_payload()).status_code == 503


def test_sdk_runs_off_event_loop(sdk):
    async def run():
        loop_thread = threading.get_ident()
        result = await speech.transcribe(
            TranscriptionRequest(**_payload()), Response(), Account(id="owner")
        )
        assert result.transcript == sdk.result
        assert sdk.thread_id != loop_thread
    asyncio.run(run())


def test_authentication_required():
    app = FastAPI()
    app.include_router(speech.router)
    app.dependency_overrides[get_db] = lambda: None
    with TestClient(app) as client:
        assert client.post("/speech/transcribe", json=_payload()).status_code == 401


def test_request_representation_does_not_include_audio():
    payload = TranscriptionRequest(**_payload())
    assert payload.audio_base64 not in repr(payload)
