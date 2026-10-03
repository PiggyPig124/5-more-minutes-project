"""Hong Kong time scheduling and authorization for the care inbox."""
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from .care_models import CareNotification, CarePreference
from .collaboration_models import FamilyMessage
from .models import Account, Conversation, FamilyLink, Message, Task
from .schemas import CheckInScheduleCreate
from .dependencies import active_care_link, linked_elder_ids

HK = ZoneInfo('Asia/Hong_Kong')


def aware(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def preferences(db: Session, owner_id: str) -> CheckInScheduleCreate:
    row = db.get(CarePreference, owner_id)
    return CheckInScheduleCreate(**(row.settings if row else {}))


def quiet_or_paused(settings: CheckInScheduleCreate, now: datetime) -> bool:
    clock = now.astimezone(HK).strftime('%H:%M')
    start, end = settings.quiet_start, settings.quiet_end
    quiet = start <= clock < end if start < end else (clock >= start or clock < end) if start != end else False
    return quiet or bool(settings.paused_until and aware(settings.paused_until) > now)


def visible(db: Session, item: CareNotification) -> bool:
    if item.kind == 'check_in':
        message = db.get(Message, item.source_id)
        conversation = db.get(Conversation, message.conversation_id) if message else None
        return bool(conversation and conversation.owner_id == item.owner_id)
    if item.kind == 'family_reply':
        message = db.get(FamilyMessage, item.source_id)
        link = db.get(FamilyLink, message.link_id) if message else None
        return bool(message and message.recipient_id == item.owner_id and link
                    and link.status == 'active' and 'family_messages' in link.scopes)
    if item.kind == 'task_reminder':
        task = db.get(Task, item.source_id)
        return bool(task and (task.owner_id == item.owner_id or active_care_link(db, item.owner_id, task.owner_id))
                    and task.status in ('pending', 'in_progress'))
    return True


def add_notification(db: Session, owner_id: str, kind: str, source_id: str, body: str) -> None:
    existing = db.scalar(select(CareNotification).where(
        CareNotification.owner_id == owner_id, CareNotification.kind == kind,
        CareNotification.source_id == source_id))
    if not existing:
        db.add(CareNotification(owner_id=owner_id, kind=kind, source_id=source_id, body=body))
        db.flush()


def collect_notifications(db: Session, account: Account, now: datetime | None = None) -> None:
    now = now or datetime.now(timezone.utc)
    pref = db.get(CarePreference, account.id)
    if not pref:
        return
    settings = preferences(db, account.id)
    if quiet_or_paused(settings, now):
        return
    if settings.task_reminders:
        owners = {account.id} | (linked_elder_ids(db, account.id) if account.role == 'caregiver' else set())
        tasks = db.scalars(select(Task).where(Task.owner_id.in_(owners),
            Task.status.in_(['pending', 'in_progress']), Task.due_at <= now)).all()
        for task in tasks:
            add_notification(db, account.id, 'task_reminder', task.id, '有一項照顧事項已到期，請查看待辦事項。')
    if settings.family_replies:
        messages = db.scalars(select(FamilyMessage).where(FamilyMessage.recipient_id == account.id,
            FamilyMessage.created_at >= pref.created_at)).all()
        for message in messages:
            item = CareNotification(owner_id=account.id, kind='family_reply', source_id=message.id)
            if visible(db, item):
                add_notification(db, account.id, 'family_reply', message.id, '家人傳來新訊息，請查看家庭訊息。')
    db.commit()
