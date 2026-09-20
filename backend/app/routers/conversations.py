from __future__ import annotations

from datetime import datetime, timezone
import re

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.encoders import jsonable_encoder
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..db import get_db
from ..dependencies import get_current_account, get_owned_conversation
from ..models import Account, ActionProposal, Conversation, Message
from ..memory_models import PersonalMemory
from ..memory_service import retrieve_for_chat, propose_from_message, memory_revision
from ..resource_service import search_resources
from ..schemas import (
    ActionOut,
    ConversationCreate,
    ConversationDetail,
    ConversationOut,
    MessageCreate,
    MessageOut,
    SendMessageOut,
)

router = APIRouter(prefix="/conversations", tags=["conversations"])
RECENT_MESSAGE_LIMIT = 12


def _message_out(message: Message) -> MessageOut:
    return MessageOut(
        id=message.id,
        conversation_id=message.conversation_id,
        sender_id=message.sender_id,
        role=message.role,
        content=message.content,
        metadata_json=dict(message.metadata_json or {}),
        client_message_id=message.client_message_id,
        ordinal=message.ordinal,
        created_at=message.created_at,
    )


def _conversation_out(conversation: Conversation) -> ConversationOut:
    return ConversationOut(
        id=conversation.id,
        owner_id=conversation.owner_id,
        title=conversation.title,
        rolling_summary=conversation.rolling_summary or "",
        recent_context=list(conversation.recent_context or []),
        created_at=conversation.created_at,
        updated_at=conversation.updated_at,
    )


def _action_out(action: ActionProposal) -> ActionOut:
    return ActionOut(
        id=action.id,
        conversation_id=action.conversation_id,
        owner_id=action.owner_id,
        action_type=action.action_type,
        payload=dict(action.payload or {}),
        status=action.status,
        result_task_id=action.result_task_id,
        created_at=action.created_at,
        confirmed_at=action.confirmed_at,
        dismissed_at=action.dismissed_at,
    )


def _context_summary(messages: list[Message]) -> str:
    if len(messages) <= RECENT_MESSAGE_LIMIT:
        return ""
    older = messages[:-RECENT_MESSAGE_LIMIT]
    parts = [f"{message.role}: {message.content.strip()}" for message in older]
    # This is a compact persisted summary, not a model inference. A later
    # memory milestone can replace it with reviewed memory extraction.
    return " | ".join(parts)[-3000:]


def _refresh_context(db: Session, conversation: Conversation) -> None:
    messages = db.scalars(
        select(Message).where(Message.conversation_id == conversation.id).order_by(Message.ordinal.asc())
    ).all()
    conversation.recent_context = [
        {"role": message.role, "content": message.content, "ordinal": message.ordinal}
        for message in messages[-RECENT_MESSAGE_LIMIT:]
    ]
    conversation.rolling_summary = _context_summary(messages)
    conversation.updated_at = datetime.now(timezone.utc)


def _lock_conversation_for_write(db: Session, conversation_id: str, owner_id: str) -> Conversation:
    """Serialize ordinal allocation and message writes per conversation."""

    if db.bind is not None and db.bind.dialect.name == "sqlite":
        # SQLite does not implement SELECT FOR UPDATE. IMMEDIATE reserves the
        # write lock before max(ordinal) is read, preventing two requests from
        # assigning the same ordinal.
        db.connection().exec_driver_sql("BEGIN IMMEDIATE")
        conversation = db.get(Conversation, conversation_id)
    else:
        db.scalar(select(Account).where(Account.id == owner_id).with_for_update())
        conversation = db.scalar(
            select(Conversation).where(Conversation.id == conversation_id).with_for_update()
        )
    if conversation is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Conversation not found")
    return conversation


def _replay_send(db: Session, conversation: Conversation, user_message: Message) -> SendMessageOut:
    """Return the durable result for a retried client message."""

    assistant_message = db.scalar(
        select(Message).where(
            Message.conversation_id == conversation.id,
            Message.ordinal == user_message.ordinal + 1,
            Message.role == "assistant",
        )
    )
    if assistant_message is None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Message is still being processed")
    metadata = dict(assistant_message.metadata_json or {})
    action_id = metadata.get("action_id")
    action = db.get(ActionProposal, action_id) if action_id else None
    mode = metadata.get("mode")
    if mode not in {"deterministic_demo", "openai_compatible", "error"}:
        mode = "error"
    return SendMessageOut(
        conversation=_conversation_out(conversation),
        user_message=_message_out(user_message),
        assistant_message=_message_out(assistant_message),
        action=_action_out(action) if action else None,
        mode=mode,
    )


@router.post("", response_model=ConversationOut, status_code=status.HTTP_201_CREATED)
def create_conversation(
    payload: ConversationCreate,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> ConversationOut:
    conversation = Conversation(owner_id=account.id, title=payload.title.strip())
    db.add(conversation)
    db.commit()
    return _conversation_out(conversation)


@router.get("", response_model=list[ConversationOut])
def list_conversations(account: Account = Depends(get_current_account), db: Session = Depends(get_db)) -> list[ConversationOut]:
    conversations = db.scalars(
        select(Conversation).where(Conversation.owner_id == account.id).order_by(Conversation.updated_at.desc())
    ).all()
    return [_conversation_out(conversation) for conversation in conversations]


@router.get("/{conversation_id}", response_model=ConversationDetail)
def get_conversation(
    conversation_id: str,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> ConversationDetail:
    conversation = get_owned_conversation(db, account, conversation_id)
    messages = db.scalars(
        select(Message).where(Message.conversation_id == conversation.id).order_by(Message.ordinal.asc())
    ).all()
    return ConversationDetail(
        **_conversation_out(conversation).model_dump(),
        messages=[_message_out(message) for message in messages],
    )


@router.get("/{conversation_id}/messages", response_model=list[MessageOut])
def list_messages(
    conversation_id: str,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> list[MessageOut]:
    conversation = get_owned_conversation(db, account, conversation_id)
    messages = db.scalars(
        select(Message).where(Message.conversation_id == conversation.id).order_by(Message.ordinal.asc())
    ).all()
    return [_message_out(message) for message in messages]


@router.get("/{conversation_id}/actions", response_model=list[ActionOut])
def list_actions(
    conversation_id: str,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> list[ActionOut]:
    conversation = get_owned_conversation(db, account, conversation_id)
    actions = db.scalars(
        select(ActionProposal).where(ActionProposal.conversation_id == conversation.id).order_by(ActionProposal.created_at.desc())
    ).all()
    return [_action_out(action) for action in actions]


@router.post("/{conversation_id}/messages", response_model=SendMessageOut)
async def send_message(
    conversation_id: str,
    payload: MessageCreate,
    request: Request,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> SendMessageOut:
    owner_id = account.id
    context_revision = memory_revision(db, owner_id)
    conversation = get_owned_conversation(db, account, conversation_id)
    if payload.client_message_id:
        existing = db.scalar(
            select(Message).where(
                Message.conversation_id == conversation.id,
                Message.client_message_id == payload.client_message_id,
                Message.role == "user",
            )
        )
        if existing is not None:
            if existing.content != payload.content:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="client_message_id is already associated with different content",
                )
            return _replay_send(db, conversation, existing)
    context = {
        "rolling_summary": conversation.rolling_summary or "",
        "recent_context": list(conversation.recent_context or []),
    }
    memory_result = await retrieve_for_chat(db, owner_id, payload.content)
    context["memory_sources"] = jsonable_encoder(memory_result["items"])
    context["memory_retrieval_mode"] = memory_result["retrieval_mode"]
    resource_query = bool(re.search(
        r"福利|津貼|津贴|補助|补助|資助|资助|醫療費|医疗费|覆診費|覆诊费|"
        r"照顧者支援|照顾者支援|社區照顧|社区照顾|長者中心|长者中心|"
        r"\bwelfare\b|\bsubsid(?:y|ies)\b|\bfee waiver\b|\bcaregiver support\b",
        payload.content, re.IGNORECASE,
    ))
    context["resource_query"] = resource_query
    resource_result = {"items": [], "retrieval_mode": "not_requested", "conflicts": []}
    if resource_query:
        resource_result = await search_resources(db, payload.content[:500])
    context["resource_sources"] = resource_result["items"]
    context["resource_conflicts"] = resource_result["conflicts"]
    # Release the read transaction while a remote model provider is running.
    # Authorization and ownership were checked above; the write transaction
    # starts only after the provider returns.
    db.rollback()
    reply = await request.app.state.orchestrator.run(context, payload.content)
    if reply.mode == "error":
        # A provider failure is not a conversation turn. Do not persist an
        # error assistant message, so the same client_message_id can safely be
        # retried after the provider recovers.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"message": reply.text, "mode": "error"},
        )

    # The model call runs outside a database transaction. Reopen a serialized
    # write section now, rechecking the client key in case another request
    # completed the same message while the provider was running.
    db.rollback()
    conversation = _lock_conversation_for_write(db, conversation_id, owner_id)
    if memory_revision(db, owner_id) != context_revision:
        raise HTTPException(409, "記憶資料已更新，請重試以使用最新內容。")
    # A memory may have been withdrawn while a remote model was answering.
    # Reject that stale answer instead of resurrecting its text in history.
    for source in context["memory_sources"]:
        current = db.scalar(select(PersonalMemory).where(PersonalMemory.id == source["id"]).with_for_update())
        if (current is None or current.owner_id != owner_id or current.status != "confirmed"
                or current.suppressed or current.deleted_at is not None
                or current.superseded_by is not None or current.content != source["content"]):
            raise HTTPException(409, "記憶資料已更新，請重試以使用最新內容。")
    if payload.client_message_id:
        existing = db.scalar(
            select(Message).where(
                Message.conversation_id == conversation.id,
                Message.client_message_id == payload.client_message_id,
                Message.role == "user",
            )
        )
        if existing is not None:
            if existing.content != payload.content:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="client_message_id is already associated with different content",
                )
            return _replay_send(db, conversation, existing)

    max_ordinal = db.scalar(select(func.max(Message.ordinal)).where(Message.conversation_id == conversation.id))
    next_ordinal = int(max_ordinal or 0) + 1
    user_metadata = {"client_message_id": payload.client_message_id} if payload.client_message_id else {}
    user_metadata["source_memory_ids"] = [source["id"] for source in context["memory_sources"]]
    user_message = Message(
        conversation_id=conversation.id,
        sender_id=account.id,
        role="user",
        content=payload.content,
        metadata_json=user_metadata,
        client_message_id=payload.client_message_id,
        ordinal=next_ordinal,
    )
    assistant_message = Message(
        conversation_id=conversation.id,
        sender_id=None,
        role="assistant",
        content=reply.text,
        metadata_json={
            "mode": reply.mode, "demo_label": reply.mode == "deterministic_demo",
            "memory_sources": context["memory_sources"],
            "memory_retrieval_mode": memory_result["retrieval_mode"],
            "resource_sources": resource_result["items"],
            "resource_retrieval_mode": resource_result["retrieval_mode"],
            "resource_conflicts": resource_result["conflicts"],
        },
        ordinal=next_ordinal + 1,
    )
    action = None
    try:
        db.add_all([user_message, assistant_message])
        db.flush()
        if account.role == "elder":
            candidate = propose_from_message(db, owner_id, user_message)
            if candidate is not None:
                assistant_message.metadata_json = {
                    **assistant_message.metadata_json,
                    "candidate_memory_id": candidate.id,
                }
                assistant_message.content += "\n已整理成待確認記憶；請到「記憶」核對，確認前不會用作長期回憶。"
        if reply.proposed_task is not None:
            action = ActionProposal(
                conversation_id=conversation.id,
                owner_id=account.id,
                action_type=str(reply.proposed_task.get("type") or "care_task"),
                payload=reply.proposed_task,
                status="pending",
            )
            db.add(action)
            db.flush()
            assistant_message.metadata_json = {
                **dict(assistant_message.metadata_json or {}),
                "action_id": action.id,
            }
        _refresh_context(db, conversation)
        db.commit()
    except IntegrityError:
        db.rollback()
        if payload.client_message_id:
            existing = db.scalar(
                select(Message).where(
                    Message.conversation_id == conversation.id,
                    Message.client_message_id == payload.client_message_id,
                    Message.role == "user",
                )
            )
            if existing is not None:
                if existing.content != payload.content:
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail="client_message_id is already associated with different content",
                    )
                return _replay_send(db, conversation, existing)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Message could not be persisted")
    return SendMessageOut(
        conversation=_conversation_out(conversation),
        user_message=_message_out(user_message),
        assistant_message=_message_out(assistant_message),
        action=_action_out(action) if action else None,
        mode=reply.mode,
    )
