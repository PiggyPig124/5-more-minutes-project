from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..db import get_db
from ..task_due_at import parse_due_at as _parse_due_at
from ..memory_service import lock_owner_account
from ..dependencies import get_current_account
from ..models import Account, ActionProposal, Task
from ..schemas import ActionDecisionOut, ActionDecisionRequest, ActionOut, TaskOut

router = APIRouter(prefix="/actions", tags=["actions"])


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


def _task_out(task: Task | None) -> TaskOut | None:
    if task is None:
        return None
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


def _get_owned_action(db: Session, action_id: str, account: Account) -> ActionProposal:
    action = db.get(ActionProposal, action_id)
    if action is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Action proposal not found")
    if action.owner_id != account.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the action owner can decide")
    return action


@router.post("/{action_id}/confirm", response_model=ActionDecisionOut)
def confirm_action(
    action_id: str,
    payload: ActionDecisionRequest | None = None,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> ActionDecisionOut:
    """Confirm a task proposal exactly once.

    ``source_action_id`` is unique on tasks and the action row is locked on
    PostgreSQL. Therefore a retry, including a retry after a network timeout,
    returns the originally created task rather than creating a duplicate.
    """

    # The authentication dependency may have opened a read transaction. End it
    # before starting the explicit mutation transaction below.
    # Keep the same owner -> action lock order as memory withdrawal.
    lock_owner_account(db, account.id)
    action = db.scalar(select(ActionProposal).where(ActionProposal.id == action_id).with_for_update())
    if action is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Action proposal not found")
    if action.owner_id != account.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the action owner can decide")

    idempotency_key = payload.idempotency_key if payload else None
    if action.confirmation_key and idempotency_key and action.confirmation_key != idempotency_key:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Action was already confirmed with another key")
    if action.status == "invalidated":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="The source memory was withdrawn; this action is no longer available")
    if action.status == "dismissed":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Dismissed actions cannot be confirmed")
    if action.status == "failed":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="This action failed and cannot be retried")

    if action.status == "executed" and action.result_task_id:
        task = db.get(Task, action.result_task_id)
        return ActionDecisionOut(action=_action_out(action), task=_task_out(task))
    if action.status == "executed":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Action has already been executed")

    data = dict(action.payload or {})
    due_at = _parse_due_at(data.get('due_at'))
    scheduled = (data.get('due_at') is not None or
        action.action_type in {'reminder', 'appointment'} or
        data.get('type') in {'reminder', 'appointment'})
    if scheduled:
        if (due_at is None or due_at <= datetime.now(timezone.utc)):
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail='Please provide an unambiguous future date, time and UTC offset before confirming the reminder.')
        if not isinstance(data.get('title'), str) or not data['title'].strip():
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail='Please provide the event before confirming the reminder.')
    if idempotency_key:
        action.confirmation_key = idempotency_key
    task = Task(
        owner_id=action.owner_id,
        created_by=account.id,
        source_action_id=action.id,
        task_type=str(data.get("type") or action.action_type or "care_task"),
        title=str(data.get("title") or "Follow up on this request")[:240],
        description=str(data.get("description") or "")[:5000],
        due_at=due_at,
        status="pending",
    )
    try:
        db.add(task)
        db.flush()
        action.result_task_id = task.id
        action.status = "executed"
        action.confirmed_at = datetime.now(timezone.utc)
        db.commit()
    except IntegrityError:
        # A concurrent retry won the unique source_action_id race. Return the
        # winner's persisted result after refreshing this session.
        db.rollback()
        action = db.get(ActionProposal, action_id)
        task = db.get(Task, action.result_task_id) if action and action.result_task_id else None
        if action and action.status == "executed":
            return ActionDecisionOut(action=_action_out(action), task=_task_out(task))
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Action could not be confirmed")
    return ActionDecisionOut(action=_action_out(action), task=_task_out(task))


@router.post("/{action_id}/dismiss", response_model=ActionOut)
def dismiss_action(
    action_id: str,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> ActionOut:
    # Keep the same owner -> action lock order as memory withdrawal.
    lock_owner_account(db, account.id)
    action = db.scalar(select(ActionProposal).where(ActionProposal.id == action_id).with_for_update())
    if action is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Action proposal not found")
    if action.owner_id != account.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the action owner can decide")
    if action.status == "invalidated":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="The source memory was withdrawn; this action is no longer available")
    if action.status == "executed":
        return _action_out(action)
    if action.status != "dismissed":
        action.status = "dismissed"
        action.dismissed_at = datetime.now(timezone.utc)
        db.commit()
    return _action_out(action)
