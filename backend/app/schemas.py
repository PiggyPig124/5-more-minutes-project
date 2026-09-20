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
    def only_care_task_scope(cls, value: list[str]) -> list[str]:
        normalized = sorted(set(value))
        if normalized != ["care_tasks"]:
            raise ValueError("the only supported family-link scope is care_tasks")
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
    mode: Literal["deterministic_demo", "openai_compatible", "error"]


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
