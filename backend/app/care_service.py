"""Hong Kong time scheduling and authorization for the care inbox."""
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from .care_models import CareNotification, CarePreference
from .collaboration_models import FamilyMessage
from .models import Account, Conversation, FamilyLink, Message, Task
from .schemas import CheckInScheduleCreate
from .task_share_models import TaskShare
from .task_share_service import active_share, account_owner_ids, begin_guard
from .family_connection_service import pair_is_blocked

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
                    and link.status == 'active' and 'family_messages' in link.scopes
                    and message.access_revoked_at is None and message.link_epoch == link.authorization_epoch
                    and not pair_is_blocked(db, link.elder_id, link.caregiver_id))
    if item.kind == 'task_reminder':
        task = db.get(Task, item.source_id)
        return bool(task and task.owner_id == item.owner_id and task.status in ('pending', 'in_progress'))
    if item.kind == 'shared_task_reminder':
        share = db.get(TaskShare, item.source_id)
        task = db.get(Task, share.task_id) if share else None
        return bool(task and task.status in ('pending', 'in_progress') and active_share(db, share, item.owner_id))
    return True


def add_notification(db: Session, owner_id: str, kind: str, source_id: str, body: str) -> None:
    existing = db.scalar(select(CareNotification).where(
        CareNotification.owner_id == owner_id, CareNotification.kind == kind,
        CareNotification.source_id == source_id))
    if not existing:
        db.add(CareNotification(owner_id=owner_id, kind=kind, source_id=source_id, body=body))
        db.flush()


def collect_notifications(db: Session, account: Account, now: datetime | None = None) -> None:
    account_id = account.id
    owners = account_owner_ids(db, account_id)
    begin_guard(db, owners)
    account = db.get(Account, account_id)
    now = now or datetime.now(timezone.utc)
    pref = db.get(CarePreference, account.id)
    if not pref:
        return
    settings = preferences(db, account.id)
    if quiet_or_paused(settings, now):
        return
    if settings.task_reminders:
        tasks = db.scalars(select(Task).where(Task.owner_id == account.id,
            Task.status.in_(['pending', 'in_progress']), Task.due_at <= now)).all()
        for task in tasks:
            add_notification(db, account.id, 'task_reminder', task.id, '有一項待辦提醒到期，請查看待辦事項。')
        if account.role == 'caregiver':
            shares = db.scalars(select(TaskShare).join(FamilyLink, TaskShare.family_link_id == FamilyLink.id)
                .where(FamilyLink.caregiver_id == account.id, TaskShare.revoked_at.is_(None))).all()
            for share in shares:
                task = db.get(Task, share.task_id)
                if (active_share(db, share, account.id) and task.status in ('pending', 'in_progress')
                        and task.due_at is not None and aware(task.due_at) <= now):
                    add_notification(db, account.id, 'shared_task_reminder', share.id, '有一項已分享待辦到期，請查看。')
    if settings.family_replies:
        messages = db.scalars(select(FamilyMessage).where(FamilyMessage.recipient_id == account.id,
            FamilyMessage.created_at >= pref.created_at)).all()
        for message in messages:
            item = CareNotification(owner_id=account.id, kind='family_reply', source_id=message.id)
            if visible(db, item):
                add_notification(db, account.id, 'family_reply', message.id, '家人傳來新訊息，請查看家庭訊息。')
    db.commit()
