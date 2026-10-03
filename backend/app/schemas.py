"""Public request and response schemas for the HTTP API."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class APIModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class AccountPublic(APIModel):
    id: str
    email: str
    display_name: str
    role: Literal["elder", "caregiver"]
    created_at: datetime


class RegisterRequest(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=8, max_length=256)
    display_name: str = Field(min_length=1, max_length=120)
    role: Literal["elder", "caregiver"] = "elder"

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        value = value.strip().lower()
        if "@" not in value or value.startswith("@") or value.endswith("@"):
            raise ValueError("a valid email address is required")
        return value


class LoginRequest(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=1, max_length=256)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class TokenResponse(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    account: AccountPublic


class FamilyInvitationCreate(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    scopes: list[str] = Field(default_factory=lambda: ["care_tasks"])

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()

    @field_validator("scopes")
    @classmethod
    def supported_family_scopes(cls, value: list[str]) -> list[str]:
        normalized = sorted(set(value))
        if not normalized or not set(normalized) <= {"care_tasks", "family_messages"}:
            raise ValueError("supported scopes are care_tasks and family_messages")
        return normalized


class FamilyInvitationAccept(BaseModel):
    token: str = Field(min_length=16, max_length=256)


class FamilyInvitationOut(APIModel):
    id: str
    elder_id: str
    email: str
    scopes: list[str]
    status: str
    expires_at: datetime
    created_at: datetime
    accepted_at: datetime | None = None
    # The raw token is returned only on creation. It is omitted for all other
    # responses and is never persisted in the database.
    token: str | None = None


class FamilyLinkOut(APIModel):
    id: str
    elder_id: str
    caregiver_id: str
    scopes: list[str]
    status: str
    created_at: datetime
    revoked_at: datetime | None = None
    elder: AccountPublic | None = None
    caregiver: AccountPublic | None = None


class ConversationCreate(BaseModel):
    title: str = Field(default="Conversation", min_length=1, max_length=200)


class MessageCreate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)
    client_message_id: str | None = Field(default=None, min_length=1, max_length=200)

    @field_validator("content")
    @classmethod
    def trim_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("message cannot be blank")
        return value


class MessageOut(APIModel):
    id: str
    conversation_id: str
    sender_id: str | None
    role: Literal["user", "assistant", "system"]
    content: str
    metadata_json: dict[str, Any] = Field(default_factory=dict)
    client_message_id: str | None = None
    ordinal: int
    created_at: datetime


class ConversationOut(APIModel):
    id: str
    owner_id: str
    title: str
    rolling_summary: str
    recent_context: list[dict[str, Any]]
    created_at: datetime
    updated_at: datetime


class ConversationDetail(ConversationOut):
    messages: list[MessageOut] = Field(default_factory=list)


class ActionOut(APIModel):
    id: str
    conversation_id: str
    owner_id: str
    action_type: str
    payload: dict[str, Any]
    status: str
    result_task_id: str | None
    created_at: datetime
    confirmed_at: datetime | None
    dismissed_at: datetime | None


class SendMessageOut(BaseModel):
    conversation: ConversationOut
    user_message: MessageOut
    assistant_message: MessageOut
    action: ActionOut | None = None
    mode: Literal["deterministic_demo", "openai_compatible", "error", "safety_intervention"]


class ActionDecisionRequest(BaseModel):
    idempotency_key: str | None = Field(default=None, min_length=1, max_length=200)


class TaskOut(APIModel):
    id: str
    owner_id: str
    created_by: str
    source_action_id: str | None
    task_type: str
    title: str
    description: str
    due_at: datetime | None
    status: str
    created_at: datetime
    updated_at: datetime


class ActionDecisionOut(BaseModel):
    action: ActionOut
    task: TaskOut | None = None


class TaskPatch(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=240)
    description: str | None = Field(default=None, max_length=5000)
    due_at: datetime | None = None
    status: Literal["pending", "in_progress", "completed", "dismissed"] | None = None

    @field_validator("title", "description", "status", mode="before")
    @classmethod
    def reject_null_required_patch_fields(cls, value: object) -> object:
        if value is None:
            raise ValueError("use an omitted field to leave it unchanged")
        return value


# ---------------------------------------------------------------------------
# Safety-assistance schemas
# ---------------------------------------------------------------------------


class EmergencyContactCreate(BaseModel):
    family_link_id: str = Field(min_length=1, max_length=36)
    label: str = Field(default="", max_length=120)


class EmergencyContactOut(APIModel):
    id: str
    elder_id: str
    family_link_id: str
    caregiver_id: str
    caregiver_name: str = ""
    label: str
    is_enabled: bool
    created_at: datetime


class SafetyEventOut(APIModel):
    id: str
    elder_id: str
    conversation_id: str | None
    trigger_message_id: str | None
    intervention_mode: str
    support_request_sent: bool
    resolved_at: datetime | None
    notes: str
    created_at: datetime


class SafetySupportRequest(BaseModel):
    """Explicit confirmation from the elder to send a support request.

    The elder must confirm both the recipient (emergency contact id) and the
    message content. An idempotency key prevents duplicate sends on retry.
    """

    emergency_contact_id: str = Field(min_length=1, max_length=36)
    message: str = Field(min_length=1, max_length=2000)
    safety_event_id: str | None = Field(default=None, min_length=1, max_length=36)
    idempotency_key: str = Field(min_length=1, max_length=200, pattern=r"^[A-Za-z0-9._:-]+$")

    @field_validator("message")
    @classmethod
    def nonblank_message(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("message cannot be blank")
        return value


class SafetySupportRequestOut(APIModel):
    sent: bool
    family_message_id: str | None = None
    emergency_contact_id: str
    message: str


# ---------------------------------------------------------------------------
# Proactive check-in schemas
# ---------------------------------------------------------------------------


class CheckInScheduleCreate(BaseModel):
    enabled: bool = False
    frequency: Literal["daily", "weekly"] = "daily"
    check_in_time: str = Field(default="10:00", pattern=r"^[0-2][0-9]:[0-5][0-9]$")
    weekday: int = Field(default=1, ge=1, le=7)
    task_reminders: bool = False
    family_replies: bool = False
    quiet_start: str = Field(default="21:00", pattern=r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
    quiet_end: str = Field(default="09:00", pattern=r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
    paused_until: datetime | None = None
    skip_date: str | None = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")

    @field_validator("check_in_time")
    @classmethod
    def enforce_quiet_hours(cls, value: str) -> str:
        hour = int(value.split(":")[0])
        if hour < 9 or hour >= 21:
            raise ValueError("check-in time must be between 09:00 and 20:59 (quiet hours 21:00–09:00)")
        return value


class CheckInScheduleOut(APIModel):
    id: str
    elder_id: str
    enabled: bool
    frequency: str
    check_in_time: str
    weekday: int
    task_reminders: bool = False
    family_replies: bool = False
    quiet_start: str = "21:00"
    quiet_end: str = "09:00"
    paused_until: datetime | None = None
    skip_date: str | None = None
    last_check_in_at: datetime | None
    created_at: datetime
    updated_at: datetime


class CheckInTriggerRequest(BaseModel):
    """Check whether a greeting is due; never bypass schedule suppression."""

    conversation_id: str | None = Field(default=None, min_length=1, max_length=36)


class CheckInTriggerOut(BaseModel):
    triggered: bool
    conversation_id: str | None = None
    message_id: str | None = None
    assistant_text: str = ""
    mode: str = "deterministic_demo"


# ---------------------------------------------------------------------------
# Speech transcription schemas
# ---------------------------------------------------------------------------


class TranscriptionRequest(BaseModel):
    """One explicitly consented upload to Tencent Cloud for transcription.

    The application does not persist audio or transcripts. This is not a
    guarantee about provider-side retention. Only mono, signed 16-bit little-
    endian PCM (raw or WAV), 16 kHz, at most 60 seconds is accepted. Compressed
    formats are intentionally excluded so duration is verified locally.
    """

    model_config = ConfigDict(extra="forbid")

    # Conservative interpretation of the provider's 3 MB *encoded* limit.
    audio_base64: str = Field(min_length=1, max_length=3_000_000, repr=False)
    format: Literal["wav", "pcm"] = "wav"
    language_hint: Literal["yue-HK", "zh-HK", "zh", "en"] = "yue-HK"
    sample_rate: Literal[16000] = 16000
    audio_processing_consent: bool = Field(strict=True)

    @field_validator("audio_processing_consent")
    @classmethod
    def require_audio_consent(cls, value: bool) -> bool:
        if value is not True:
            raise ValueError("explicit consent to send audio to Tencent Cloud is required")
        return value


class TranscriptionResponse(BaseModel):
    transcript: str
    language: str
    confidence: float | None = None
    mode: Literal["tencent_asr"]
