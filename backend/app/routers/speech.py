"""Consent-gated Tencent SentenceRecognition, with no application retention.

Official contract verified 2026-10-02:
https://cloud.tencent.com/document/product/1093/35646
https://cloud.tencent.com/document/product/1093/52554
Provider retention is governed by Tencent's terms, not by this endpoint.
"""

from __future__ import annotations

import base64
import binascii
import io
import os
import wave

from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from starlette.concurrency import run_in_threadpool

from ..dependencies import get_current_account
from ..models import Account
from ..schemas import TranscriptionRequest, TranscriptionResponse

class SpeechRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def private_response(request):
            try:
                response = await handler(request)
            except RequestValidationError as exc:
                # FastAPI otherwise echoes the audio in validation error inputs.
                response = JSONResponse(status_code=422, content={"detail": [
                    {key: error[key] for key in ("loc", "msg", "type")}
                    for error in exc.errors()
                ]})
            except HTTPException as exc:
                exc.headers = {**(exc.headers or {}), "Cache-Control": "no-store"}
                raise
            response.headers["Cache-Control"] = "no-store"
            return response

        return private_response


router = APIRouter(prefix="/speech", tags=["speech"], route_class=SpeechRoute)

_MODELS = {
    "yue-HK": "16k_yue",
    "zh-HK": "16k_zh-PY",
    "zh": "16k_zh",
    "en": "16k_en",
}


class SpeechUnavailable(RuntimeError):
    pass


def _tencent_asr_configured() -> bool:
    return bool(os.getenv("TENCENT_ASR_SECRET_ID", "").strip()
                and os.getenv("TENCENT_ASR_SECRET_KEY", "").strip())


def _validate_audio(payload: TranscriptionRequest) -> bytes:
    try:
        audio = base64.b64decode(payload.audio_base64, validate=True)
    except (ValueError, binascii.Error):
        raise HTTPException(400, "Invalid base64 audio data.") from None
    if base64.b64encode(audio).decode("ascii") != payload.audio_base64:
        raise HTTPException(400, "Audio must use canonical base64 encoding.")
    if payload.format == "pcm":
        if not audio or len(audio) % 2:
            raise HTTPException(400, "PCM audio must contain complete 16-bit samples.")
        frames = len(audio) // 2
    else:
        try:
            with wave.open(io.BytesIO(audio), "rb") as source:
                if (source.getnchannels() != 1 or source.getsampwidth() != 2
                        or source.getframerate() != payload.sample_rate or source.getcomptype() != "NONE"):
                    raise HTTPException(400, "WAV audio must be mono 16-bit PCM at 16000 Hz.")
                frames = source.getnframes()
                if frames > 60 * payload.sample_rate:
                    raise HTTPException(400, "Audio must be at most 60 seconds.")
                if len(source.readframes(frames)) != frames * 2:
                    raise HTTPException(400, "WAV audio is truncated.")
        except (wave.Error, EOFError):
            raise HTTPException(400, "Invalid WAV audio data.") from None
    if not 0 < frames <= 60 * payload.sample_rate:
        raise HTTPException(400, "Audio must be nonempty and at most 60 seconds.")
    return audio


def _call_tencent_asr(audio_bytes: bytes, request: TranscriptionRequest) -> str:
    """Blocking SDK adapter; invoke only from a worker thread, never log audio."""
    if not _tencent_asr_configured():
        raise SpeechUnavailable("Tencent ASR credentials are not configured")
    try:
        from tencentcloud.common import credential
        from tencentcloud.common.profile.client_profile import ClientProfile
        from tencentcloud.common.profile.http_profile import HttpProfile
        from tencentcloud.asr.v20190614 import asr_client, models
    except ImportError:
        raise SpeechUnavailable("Tencent ASR SDK is not installed") from None

    credentials = credential.Credential(
        os.environ["TENCENT_ASR_SECRET_ID"].strip(),
        os.environ["TENCENT_ASR_SECRET_KEY"].strip(),
    )
    http_profile = HttpProfile()
    http_profile.endpoint = "asr.tencentcloudapi.com"
    http_profile.reqTimeout = 30
    profile = ClientProfile()
    profile.httpProfile = http_profile
    profile.signMethod = "TC3-HMAC-SHA256"
    # SentenceRecognition does not require a Region.
    client = asr_client.AsrClient(credentials, "", profile)
    sdk_request = models.SentenceRecognitionRequest()
    sdk_request.EngSerViceType = _MODELS[request.language_hint]
    sdk_request.SourceType = 1
    sdk_request.VoiceFormat = request.format
    sdk_request.Data = base64.b64encode(audio_bytes).decode("ascii")
    sdk_request.DataLen = len(audio_bytes)
    result = client.SentenceRecognition(sdk_request).Result
    if not isinstance(result, str) or not result.strip():
        raise RuntimeError("Tencent ASR returned no transcript")
    return result


@router.post("/transcribe", response_model=TranscriptionResponse)
async def transcribe(
    payload: TranscriptionRequest,
    response: Response,
    account: Account = Depends(get_current_account),
) -> TranscriptionResponse:
    response.headers["Cache-Control"] = "no-store"
    audio = _validate_audio(payload)
    if not _tencent_asr_configured():
        raise HTTPException(503, "Speech transcription is not configured.", headers={"Cache-Control": "no-store"})
    try:
        transcript = await run_in_threadpool(_call_tencent_asr, audio, payload)
        if not isinstance(transcript, str) or not transcript.strip():
            raise RuntimeError("No transcript")
    except SpeechUnavailable:
        raise HTTPException(503, "Speech transcription is not configured.", headers={"Cache-Control": "no-store"}) from None
    except Exception:
        # Never return provider errors that may contain credentials or audio.
        raise HTTPException(502, "Speech provider could not transcribe this audio.", headers={"Cache-Control": "no-store"}) from None
    return TranscriptionResponse(
        transcript=transcript,
        language=payload.language_hint,
        confidence=None,
        mode="tencent_asr",
    )
