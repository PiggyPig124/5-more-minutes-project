"""Canonical consent fingerprints and live, serialized authorization."""
import hashlib
import json
from datetime import datetime, timezone
from sqlalchemy import select
from sqlalchemy.orm import Session
from .models import Account, FamilyLink, Task
from .task_share_models import TaskShare


def utc(value):
    if value is None:
        return None
    return (value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value).astimezone(timezone.utc)


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def content_hash(task: Task) -> str:
    due = utc(task.due_at)
    return digest({"task_type": task.task_type, "title": task.title, "description": task.description,
                   "due_at": due.isoformat(timespec="microseconds") if due else None})


def begin_guard(db: Session, owner_ids=()):
    """Start fresh after auth lookup; serialize every consent writer on elder account.

    SQLite must reserve the write lock before reading. PostgreSQL owner account
    locks precede family/task/share locks. NO KEY UPDATE preserves the owner mutex
    while remaining compatible with message INSERT foreign-key KEY SHARE locks.
    Sorted owners avoid cross-owner deadlocks.
    """
    db.rollback()
    db.info["task_share_guard_owners"] = set(owner_ids)
    if db.bind.dialect.name == "sqlite":
        db.connection().exec_driver_sql("BEGIN IMMEDIATE")
    elif owner_ids:
        db.scalars(select(Account).where(Account.id.in_(sorted(set(owner_ids))))
                   .order_by(Account.id).with_for_update(key_share=True, read=False)).all()


def account_owner_ids(db: Session, account_id: str):
    return {account_id} | set(db.scalars(select(FamilyLink.elder_id).where(FamilyLink.caregiver_id == account_id)).all())


def active_share(db: Session, share: TaskShare | None, caregiver_id: str) -> bool:
    if not share or share.revoked_at is not None:
        return False
    task = db.get(Task, share.task_id)
    link = db.get(FamilyLink, share.family_link_id)
    recipient = db.get(Account, caregiver_id)
    guarded_owners = db.info.get("task_share_guard_owners")
    if task and guarded_owners is not None and task.owner_id not in guarded_owners:
        # A newly connected owner joins on the next refresh, after it is locked.
        return False
    from .family_connection_service import pair_is_blocked
    if link and pair_is_blocked(db, link.elder_id, link.caregiver_id):
        return False
    return bool(task and link and recipient and recipient.is_active and recipient.role == "caregiver"
                and link.status == "active" and "care_tasks" in (link.scopes or [])
                and link.caregiver_id == caregiver_id and link.elder_id == task.owner_id
                and share.shared_by == task.owner_id and share.content_hash == content_hash(task))


def shared_for_task(db: Session, task_id: str, caregiver_id: str):
    shares = db.scalars(select(TaskShare).join(FamilyLink, TaskShare.family_link_id == FamilyLink.id)
                       .where(TaskShare.task_id == task_id, TaskShare.revoked_at.is_(None),
                              FamilyLink.caregiver_id == caregiver_id)).all()
    return next((share for share in shares if active_share(db, share, caregiver_id)), None)


def revoke_shares(db: Session, *, task_id=None, link_id=None, reason: str):
    query = select(TaskShare).where(TaskShare.revoked_at.is_(None))
    if task_id is not None:
        query = query.where(TaskShare.task_id == task_id)
    if link_id is not None:
        query = query.where(TaskShare.family_link_id == link_id)
    for share in db.scalars(query.with_for_update()).all():
        share.revoked_at = datetime.now(timezone.utc)
        share.revocation_reason = reason
