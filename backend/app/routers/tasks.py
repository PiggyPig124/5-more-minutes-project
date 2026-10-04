from __future__ import annotations
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account, FamilyLink, Task
from ..schemas import TaskOut, TaskPatch
from ..task_share_models import TaskShare
from ..task_share_service import (account_owner_ids, active_share, begin_guard, content_hash,
    digest, revoke_shares, shared_for_task, utc)

router = APIRouter(prefix="/tasks", tags=["tasks"])


class ShareCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    family_link_id: str = Field(min_length=1, max_length=36)
    expected_content_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    idempotency_key: str = Field(min_length=1, max_length=200)


def _task_out(task: Task) -> TaskOut:
    return TaskOut(id=task.id, owner_id=task.owner_id, created_by=task.created_by,
        source_action_id=task.source_action_id, task_type=task.task_type, title=task.title,
        description=task.description, due_at=utc(task.due_at), status=task.status,
        created_at=task.created_at, updated_at=task.updated_at, content_hash=content_hash(task))


def _view(db, task, share=None):
    if share is None:
        return _task_out(task).model_dump(mode="json")
    owner = db.get(Account, task.owner_id)
    return {"id":task.id, "owner_id":task.owner_id,
        "owner_display_name":owner.display_name if owner else "", "task_type":task.task_type,
        "title":task.title, "description":task.description, "due_at":utc(task.due_at),
        "status":task.status, "share_id":share.id, "access_mode":"shared_readonly"}


def _owned(db, task_id, account_id):
    task=db.get(Task,task_id)
    if task is None or task.owner_id != account_id:
        raise HTTPException(404,"Task not found")
    return task


def _guard_task(db, account_id, task_id):
    task=db.get(Task,task_id)
    owners={account_id, task.owner_id} if task else {account_id}
    begin_guard(db,owners)


def _share_out(db, share):
    link=db.get(FamilyLink,share.family_link_id)
    recipient=db.get(Account,link.caregiver_id) if link else None
    return {key:getattr(share,key) for key in ("id","task_id","family_link_id","shared_by","content_hash",
        "consented_at","revoked_at","revocation_reason")} | {
        "consented_at":utc(share.consented_at), "revoked_at":utc(share.revoked_at),
        "caregiver_name":recipient.display_name if recipient else "",
        "caregiver_email":recipient.email if recipient else "",
        "caregiver_id":link.caregiver_id if link else None}


@router.get("")
def list_tasks(owner_id: str | None=Query(default=None),account: Account=Depends(get_current_account),db: Session=Depends(get_db)):
    aid=account.id
    owners=account_owner_ids(db,aid)
    begin_guard(db,owners)
    tasks=db.scalars(select(Task).where(Task.owner_id.in_(owners)).order_by(Task.updated_at.desc())).all()
    result=[]
    for task in tasks:
        if owner_id is not None and task.owner_id != owner_id:
            continue
        if task.owner_id == aid:
            result.append(_view(db, task))
        else:
            share=shared_for_task(db,task.id,aid)
            if share:
                result.append(_view(db, task,share))
    if owner_id is not None and owner_id != aid and not result:
        raise HTTPException(404,"Tasks not found")
    return result


@router.get("/{task_id}")
def get_task(task_id: str,account: Account=Depends(get_current_account),db: Session=Depends(get_db)):
    aid=account.id
    _guard_task(db,aid,task_id)
    task=db.get(Task,task_id)
    if task and task.owner_id == aid:
        return _view(db, task)
    share=shared_for_task(db,task_id,aid) if task else None
    if not share:
        raise HTTPException(404,"Task not found")
    return _view(db, task,share)


@router.patch("/{task_id}",response_model=TaskOut)
def patch_task(task_id: str,payload: TaskPatch,account: Account=Depends(get_current_account),db: Session=Depends(get_db)):
    aid=account.id
    _guard_task(db,aid,task_id)
    task=_owned(db,task_id,aid)
    before=content_hash(task)
    for field,value in payload.model_dump(exclude_unset=True).items():
        setattr(task,field,utc(value) if field == "due_at" else value)
    if before != content_hash(task):
        revoke_shares(db,task_id=task.id,reason="task_content_changed")
    task.updated_at=datetime.now(timezone.utc)
    db.commit()
    return _task_out(task)


@router.get("/{task_id}/shares")
def list_shares(task_id: str,account: Account=Depends(get_current_account),db: Session=Depends(get_db)):
    aid=account.id
    _guard_task(db,aid,task_id)
    _owned(db,task_id,aid)
    return [_share_out(db,share) for share in db.scalars(select(TaskShare).where(TaskShare.task_id==task_id)
            .order_by(TaskShare.consented_at.desc())).all()]


@router.post("/{task_id}/shares",status_code=201)
def create_share(task_id: str,payload: ShareCreate,response: Response,account: Account=Depends(get_current_account),db: Session=Depends(get_db)):
    aid=account.id
    _guard_task(db,aid,task_id)
    task=_owned(db,task_id,aid)
    account=db.get(Account,aid)
    if account.role != "elder":
        raise HTTPException(403,"Only elders can share tasks")
    request_hash=digest({"task_id":task_id,**payload.model_dump(exclude={"idempotency_key"})})
    existing=db.scalar(select(TaskShare).where(TaskShare.shared_by==aid,TaskShare.idempotency_key==payload.idempotency_key).with_for_update())
    if existing:
        if existing.request_hash != request_hash:
            raise HTTPException(409,"Idempotency key already used for another request")
        link=db.get(FamilyLink,existing.family_link_id)
        if existing.revoked_at is not None or not link or not active_share(db,existing,link.caregiver_id):
            raise HTTPException(409,"Consent was revoked; preview again with a new key")
        response.status_code=200
        return _share_out(db,existing)
    link=db.scalar(select(FamilyLink).where(FamilyLink.id==payload.family_link_id).with_for_update())
    recipient=db.get(Account,link.caregiver_id) if link else None
    from ..family_connection_service import pair_is_blocked
    if link and pair_is_blocked(db, link.elder_id, link.caregiver_id):
        raise HTTPException(403, "Recipient is not eligible for task sharing")
    if not link or link.elder_id != aid or link.status != "active" or "care_tasks" not in (link.scopes or []) or not recipient or not recipient.is_active or recipient.role != "caregiver":
        raise HTTPException(403,"Recipient is not eligible for task sharing")
    if payload.expected_content_hash != content_hash(task):
        raise HTTPException(409,"Task changed; preview the current content again")
    if db.scalar(select(TaskShare.id).where(TaskShare.task_id==task_id,TaskShare.family_link_id==link.id,TaskShare.revoked_at.is_(None))):
        raise HTTPException(409,"Task already shared with this recipient")
    share=TaskShare(task_id=task_id,family_link_id=link.id,shared_by=aid,content_hash=payload.expected_content_hash,
        request_hash=request_hash,idempotency_key=payload.idempotency_key)
    db.add(share)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409,"Consent conflicts with another request")
    return _share_out(db,share)


@router.delete("/{task_id}/shares/{share_id}")
def revoke_share(task_id: str,share_id: str,account: Account=Depends(get_current_account),db: Session=Depends(get_db)):
    aid=account.id
    _guard_task(db,aid,task_id)
    _owned(db,task_id,aid)
    share=db.get(TaskShare,share_id)
    if not share or share.task_id != task_id:
        raise HTTPException(404,"Share not found")
    if share.revoked_at is None:
        share.revoked_at=datetime.now(timezone.utc)
        share.revocation_reason="owner_revoked"
    db.commit()
    return _share_out(db,share)
