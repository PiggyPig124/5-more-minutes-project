from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..dependencies import get_current_account, linked_elder_ids
from ..models import Account, Task
from ..schemas import TaskOut, TaskPatch

router = APIRouter(prefix="/tasks", tags=["tasks"])


def _task_out(task: Task) -> TaskOut:
    return TaskOut(
        id=task.id,
        owner_id=task.owner_id,
        created_by=task.created_by,
        source_action_id=task.source_action_id,
        task_type=task.task_type,
        title=task.title,
        description=task.description,
        due_at=task.due_at,
        status=task.status,
        created_at=task.created_at,
        updated_at=task.updated_at,
    )


def _can_access_task(db: Session, account: Account, task: Task) -> bool:
    if account.role == "elder":
        return task.owner_id == account.id
    return task.owner_id == account.id or task.owner_id in linked_elder_ids(db, account.id)


@router.get("", response_model=list[TaskOut])
def list_tasks(
    owner_id: str | None = Query(default=None),
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> list[TaskOut]:
    if account.role == "elder":
        if owner_id is not None and owner_id != account.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You can only view your own tasks")
        owner_ids = {account.id}
    else:
        owner_ids = linked_elder_ids(db, account.id) | {account.id}
        if owner_id is not None:
            if owner_id not in owner_ids:
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This caregiver link has no care_tasks scope")
            owner_ids = {owner_id}
    if not owner_ids:
        return []
    tasks = db.scalars(select(Task).where(Task.owner_id.in_(owner_ids)).order_by(Task.updated_at.desc())).all()
    return [_task_out(task) for task in tasks]


@router.patch("/{task_id}", response_model=TaskOut)
def patch_task(
    task_id: str,
    payload: TaskPatch,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> TaskOut:
    task = db.get(Task, task_id)
    if task is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")
    if not _can_access_task(db, account, task):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You do not have care_tasks access to this task")
    values = payload.model_dump(exclude_unset=True)
    for field, value in values.items():
        if field == "description" and value is None:
            value = ""
        setattr(task, field, value)
    task.updated_at = datetime.now(timezone.utc)
    db.commit()
    return _task_out(task)
