"""Proactive check-in router: schedule management and message generation.

The elder configures a check-in schedule (daily or weekly, between 09:00 and
20:59 Hong Kong time). The backend persists the schedule and can generate a
check-in conversation turn on demand or when triggered by a scheduler.

A check-in message is an assistant message in the elder's default conversation
created through the orchestrator, so it benefits from memory retrieval and the
safety node just like a user-initiated turn. The only difference is that the
"trigger" is the check-in schedule rather than the user typing a message.
"""

from __future__ import annotations

from datetime import datetime, timezone, time
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from ..db import get_db
from ..dependencies import get_current_account, require_elder
from ..models import Account, Conversation, Message
from ..safety_models import CheckInSchedule
from ..care_models import CarePreference
from ..care_service import preferences, quiet_or_paused, aware, add_notification
from ..memory_consent import memory_consent_enabled
from ..memory_service import lock_owner_account, memory_revision
from ..schemas import (
    CheckInScheduleCreate,
    CheckInScheduleOut,
    CheckInTriggerOut,
    CheckInTriggerRequest,
)

router = APIRouter(prefix="/check-ins", tags=["check-ins"])

HK = ZoneInfo("Asia/Hong_Kong")

CHECK_IN_TRIGGER_MESSAGE = "（這是一個定時關心訊息）你好，今天過得怎麼樣？有沒有什麼想聊聊的？"


def _schedule_out(schedule: CheckInSchedule, db: Session) -> CheckInScheduleOut:
    return CheckInScheduleOut(
        **preferences(db, schedule.elder_id).model_dump(exclude={"enabled", "frequency", "check_in_time", "weekday"}),
        id=schedule.id,
        elder_id=schedule.elder_id,
        enabled=schedule.enabled,
        frequency=schedule.frequency,
        check_in_time=schedule.check_in_time,
        weekday=schedule.weekday,
        last_check_in_at=schedule.last_check_in_at,
        created_at=schedule.created_at,
        updated_at=schedule.updated_at,
    )


@router.get("/schedule", response_model=CheckInScheduleOut | None)
def get_schedule(
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> CheckInScheduleOut | None:
    schedule = db.scalar(
        select(CheckInSchedule).where(CheckInSchedule.elder_id == account.id)
    )
    return _schedule_out(schedule, db) if schedule else None


@router.put("/schedule", response_model=CheckInScheduleOut)
def upsert_schedule(
    payload: CheckInScheduleCreate,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> CheckInScheduleOut:
    if account.role != "elder" and payload.enabled:
        raise HTTPException(403, "Only elder accounts can enable check-ins")
    pref = db.get(CarePreference, account.id)
    if pref is None:
        pref = CarePreference(owner_id=account.id)
        db.add(pref)
    pref.settings = payload.model_dump(mode="json")
    schedule = db.scalar(
        select(CheckInSchedule).where(CheckInSchedule.elder_id == account.id)
    )
    if schedule is None:
        schedule = CheckInSchedule(
            elder_id=account.id,
            enabled=payload.enabled,
            frequency=payload.frequency,
            check_in_time=payload.check_in_time,
            weekday=payload.weekday,
        )
        db.add(schedule)
    else:
        schedule.enabled = payload.enabled
        schedule.frequency = payload.frequency
        schedule.check_in_time = payload.check_in_time
        schedule.weekday = payload.weekday
    schedule.updated_at = datetime.now(timezone.utc)
    db.commit()
    return _schedule_out(schedule, db)


def _check_in_conversation(db: Session, owner_id: str, conversation_id: str | None) -> Conversation:
    # Find or create the check-in conversation.
    if conversation_id:
        conversation = db.get(Conversation, conversation_id)
        if conversation is None or conversation.owner_id != owner_id:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Conversation not found")
    else:
        conversation = db.scalar(
            select(Conversation).where(
                Conversation.owner_id == owner_id,
                Conversation.title == "定時關心",
            )
        )
        if conversation is None:
            conversation = Conversation(owner_id=owner_id, title="定時關心")
            db.add(conversation)
            db.commit()
            db.refresh(conversation)

    return conversation


async def generate_check_in(
    payload: CheckInTriggerRequest,
    request: Request,
    account: Account,
    db: Session,
) -> CheckInTriggerOut:
    """Generate a check-in message in the elder's conversation.

    This creates or reuses a conversation titled "定時關心" (Scheduled check-in),
    then runs the orchestrator with a check-in trigger message. The resulting
    assistant message is persisted as a normal conversation turn.
    """

    # Snapshot before reading any persisted context, including when Memory is off.
    revision = memory_revision(db, account.id)
    schedule = db.scalar(select(CheckInSchedule).where(CheckInSchedule.elder_id == account.id))
    now = datetime.now(timezone.utc)
    local = now.astimezone(HK)
    settings = preferences(db, account.id)
    if payload.conversation_id:
        target = db.get(Conversation, payload.conversation_id)
        if target is None or target.owner_id != account.id:
            raise HTTPException(404, "Conversation not found")
    if (not schedule or not schedule.enabled or quiet_or_paused(settings, now)
        or settings.skip_date == local.date().isoformat()
        or local.strftime("%H:%M") < schedule.check_in_time
        or (schedule.frequency == "weekly" and local.isoweekday() != schedule.weekday)
        or (schedule.last_check_in_at and aware(schedule.last_check_in_at).astimezone(HK).date() == local.date())):
        return CheckInTriggerOut(triggered=False)
    day_start = datetime.combine(local.date(), time.min, tzinfo=HK).astimezone(timezone.utc)
    today_messages = db.scalars(select(Message).join(Conversation).where(
        Conversation.owner_id == account.id, Message.role == "user", Message.created_at >= day_start)).all()
    if any(not (item.metadata_json or {}).get("check_in_trigger") for item in today_messages):
        return CheckInTriggerOut(triggered=False)

    # First-time creation also commits and can wait for SQLite's writer.
    conversation = await run_in_threadpool(_check_in_conversation, db, account.id, payload.conversation_id)

    context: dict = {
        "rolling_summary": conversation.rolling_summary or "",
        "recent_context": list(conversation.recent_context or []),
        "check_in_trigger": True,
    }

    context["memory_retrieval_mode"] = "disabled"
    context["memory_sources"] = []
    if memory_consent_enabled(db, account.id):
        from ..memory_service import retrieve_for_chat
        from fastapi.encoders import jsonable_encoder
        result = await retrieve_for_chat(db, account.id, CHECK_IN_TRIGGER_MESSAGE)
        context["memory_sources"] = jsonable_encoder(result["items"])
        context["memory_retrieval_mode"] = result["retrieval_mode"]

    db.rollback()
    reply = await request.app.state.orchestrator.run(context, CHECK_IN_TRIGGER_MESSAGE)

    if reply.mode == "error":
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"message": reply.text, "mode": "error"},
        )

    await run_in_threadpool(lock_owner_account, db, account.id)
    db.expire_all()
    if memory_revision(db, account.id) != revision:
        db.rollback()
        raise HTTPException(409, "記憶資料已更新，請重試以使用最新內容。")
    if context["memory_sources"] and not memory_consent_enabled(db, account.id):
        db.rollback()
        raise HTTPException(409, "記憶授權已關閉，請重試。")
    current_settings = preferences(db, account.id)
    db.refresh(schedule)
    if (not schedule.enabled or quiet_or_paused(current_settings, datetime.now(timezone.utc))
            or current_settings.skip_date == local.date().isoformat()):
        db.rollback()
        return CheckInTriggerOut(triggered=False)
    from sqlalchemy import func

    max_ordinal = db.scalar(select(func.max(Message.ordinal)).where(Message.conversation_id == conversation.id))
    next_ordinal = int(max_ordinal or 0) + 1

    # The user message is the check-in trigger (system-generated, not typed by the elder).
    trigger_message = Message(
        conversation_id=conversation.id,
        sender_id=account.id,
        role="user",
        content=CHECK_IN_TRIGGER_MESSAGE,
        metadata_json={"check_in_trigger": True},
        ordinal=next_ordinal,
    )
    assistant_message = Message(
        conversation_id=conversation.id,
        sender_id=None,
        role="assistant",
        content=reply.text,
        metadata_json={
            "mode": reply.mode,
            "check_in": True,
            "memory_sources": context["memory_sources"],
            "memory_retrieval_mode": context["memory_retrieval_mode"],
        },
        ordinal=next_ordinal + 1,
    )
    db.add_all([trigger_message, assistant_message])
    db.flush()
    # Resolve greeting text from the conversation on read, so memory deletion
    # cannot leave a second copy of a recalled fact in the inbox.
    add_notification(db, account.id, "check_in", assistant_message.id, "你有一則新的關懷問候。")

    # Update the schedule's last_checkIn fields.
    schedule = db.scalar(select(CheckInSchedule).where(CheckInSchedule.elder_id == account.id))
    if schedule is not None:
        schedule.last_check_in_at = datetime.now(timezone.utc)
        schedule.last_check_in_message_id = assistant_message.id

    # Refresh the conversation context.
    messages = db.scalars(
        select(Message).where(Message.conversation_id == conversation.id).order_by(Message.ordinal.asc())
    ).all()
    recent = [
        {"role": msg.role, "content": msg.content, "ordinal": msg.ordinal}
        for msg in messages[-12:]
    ]
    conversation.recent_context = recent
    conversation.updated_at = datetime.now(timezone.utc)

    db.commit()

    return CheckInTriggerOut(
        triggered=True,
        conversation_id=conversation.id,
        message_id=assistant_message.id,
        assistant_text=reply.text,
        mode=reply.mode,
    )


@router.post("/skip", response_model=CheckInScheduleOut)
def skip_today(account: Account = Depends(require_elder), db: Session = Depends(get_db)):
    settings = preferences(db, account.id)
    settings.skip_date = datetime.now(HK).date().isoformat()
    return upsert_schedule(settings, account, db)


@router.post("/trigger", response_model=CheckInTriggerOut)
async def trigger_check_in(payload: CheckInTriggerRequest, request: Request,
                           account: Account = Depends(require_elder), db: Session = Depends(get_db)):
    async with request.app.state.care_lock:
        return await generate_check_in(payload, request, account, db)
