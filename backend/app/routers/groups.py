"""Closed human group conversations. No AI or private-memory context enters here."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..db import get_db
from ..dependencies import get_current_account
from ..group_models import ChatGroup, GroupBlock, GroupInvitation, GroupMember, GroupMessage, GroupReport
from ..models import Account, utc_now
from ..security import decode_access_token

router = APIRouter(prefix="/groups", tags=["human-groups"])
INVITATION_DAYS = 7
MAX_MEMBERS = 20
WS_UNAUTHENTICATED = 4401
WS_NOT_FOUND = 4404


class CreateGroup(BaseModel):
    title: str = Field(min_length=1, max_length=100)

    @field_validator("title")
    @classmethod
    def clean_title(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Group title cannot be blank")
        return value


class InviteMember(BaseModel):
    email: str = Field(min_length=3, max_length=320)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class SendGroupMessage(BaseModel):
    content: str = Field(min_length=1, max_length=4000)
    client_message_id: str = Field(min_length=1, max_length=200)

    @field_validator("content")
    @classmethod
    def clean_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Message cannot be blank")
        return value


class CreateReport(BaseModel):
    reason: str = Field(min_length=3, max_length=500)
    message_id: str | None = Field(default=None, max_length=36)

    @field_validator("reason")
    @classmethod
    def clean_reason(cls, value: str) -> str:
        value = value.strip()
        if len(value) < 3:
            raise ValueError("Report reason is too short")
        return value


class BlockAccount(BaseModel):
    account_id: str = Field(min_length=36, max_length=36)


class GroupOut(BaseModel):
    id: str
    title: str
    owner_id: str
    owner_name: str
    member_count: int
    created_at: datetime


class MemberOut(BaseModel):
    account_id: str
    display_name: str
    role: str
    joined_at: datetime


class InvitationOut(BaseModel):
    id: str
    group_id: str
    group_title: str
    inviter_id: str
    inviter_name: str
    invitee_id: str
    status: str
    expires_at: datetime


class MessageOut(BaseModel):
    id: str
    group_id: str
    sender_id: str
    sender_name: str
    ordinal: int
    content: str
    created_at: datetime


def _write_lock(db: Session) -> None:
    # Authentication has already read from this Session. Restart the
    # transaction so invite acceptance, leave, and send checks are atomic.
    db.rollback()
    if db.bind.dialect.name == "sqlite":
        db.connection().exec_driver_sql("BEGIN IMMEDIATE")


def _group(db: Session, group_id: str) -> ChatGroup:
    group = db.get(ChatGroup, group_id)
    if group is None or group.status != "active":
        raise HTTPException(404, "Group not found")
    return group


def _locked_group(db: Session, group_id: str) -> ChatGroup:
    if db.bind.dialect.name == "postgresql":
        group = db.scalar(select(ChatGroup).where(ChatGroup.id == group_id)
                          .with_for_update().execution_options(populate_existing=True))
        if group is None or group.status != "active":
            raise HTTPException(404, "Group not found")
        return group
    return _group(db, group_id)


def _member(db: Session, group_id: str, account_id: str) -> tuple[ChatGroup, GroupMember]:
    group = _group(db, group_id)
    membership = db.scalar(select(GroupMember).where(
        GroupMember.group_id == group_id, GroupMember.account_id == account_id,
        GroupMember.status == "active",
    ))
    if membership is None:
        # Do not reveal whether a private group exists.
        raise HTTPException(404, "Group not found")
    return group, membership


def _out(db: Session, group: ChatGroup) -> GroupOut:
    owner = db.get(Account, group.owner_id)
    count = db.scalar(select(func.count()).select_from(GroupMember).where(
        GroupMember.group_id == group.id, GroupMember.status == "active",
    )) or 0
    return GroupOut(id=group.id, title=group.title, owner_id=group.owner_id,
                    owner_name=owner.display_name if owner else "Member",
                    member_count=count, created_at=group.created_at)


def _invitation_out(db: Session, invitation: GroupInvitation) -> InvitationOut:
    group = db.get(ChatGroup, invitation.group_id)
    inviter = db.get(Account, invitation.inviter_id)
    return InvitationOut(id=invitation.id, group_id=invitation.group_id,
                         group_title=group.title if group else "Group",
                         inviter_id=invitation.inviter_id,
                         inviter_name=inviter.display_name if inviter else "Member",
                         invitee_id=invitation.invitee_id, status=invitation.status,
                         expires_at=invitation.expires_at)


def _message_out(db: Session, message: GroupMessage) -> MessageOut:
    sender = db.get(Account, message.sender_id)
    return MessageOut(id=message.id, group_id=message.group_id,
                      sender_id=message.sender_id,
                      sender_name=sender.display_name if sender else "Member",
                      ordinal=message.ordinal, content=message.content,
                      created_at=message.created_at)


@router.post("", response_model=GroupOut, status_code=status.HTTP_201_CREATED)
def create_group(payload: CreateGroup, account: Account = Depends(get_current_account),
                 db: Session = Depends(get_db)) -> GroupOut:
    account_id = account.id
    _write_lock(db)
    group = ChatGroup(owner_id=account_id, title=payload.title)
    db.add(group)
    db.flush()
    db.add(GroupMember(group_id=group.id, account_id=account_id, role="owner"))
    db.commit()
    return _out(db, group)


@router.get("", response_model=list[GroupOut])
def list_groups(account: Account = Depends(get_current_account),
                db: Session = Depends(get_db)) -> list[GroupOut]:
    rows = db.scalars(select(ChatGroup).join(GroupMember, GroupMember.group_id == ChatGroup.id).where(
        GroupMember.account_id == account.id, GroupMember.status == "active",
        ChatGroup.status == "active",
    ).order_by(ChatGroup.created_at.desc()).limit(100)).all()
    return [_out(db, row) for row in rows]


@router.get("/invitations", response_model=list[InvitationOut])
def list_invitations(account: Account = Depends(get_current_account),
                     db: Session = Depends(get_db)) -> list[InvitationOut]:
    now = utc_now()
    rows = db.scalars(select(GroupInvitation).join(ChatGroup, ChatGroup.id == GroupInvitation.group_id).where(
        GroupInvitation.invitee_id == account.id, GroupInvitation.status == "pending",
        GroupInvitation.expires_at > now, ChatGroup.status == "active",
    ).order_by(GroupInvitation.created_at.desc()).limit(100)).all()
    return [_invitation_out(db, row) for row in rows]


@router.post("/invitations/{invitation_id}/accept", response_model=GroupOut)
def accept_invitation(invitation_id: str, request: Request,
                      account: Account = Depends(get_current_account),
                      db: Session = Depends(get_db)) -> GroupOut:
    account_id = account.id
    _write_lock(db)
    invitation = db.scalar(select(GroupInvitation).where(GroupInvitation.id == invitation_id)
                           .with_for_update())
    if invitation is None or invitation.invitee_id != account_id or invitation.status != "pending":
        raise HTTPException(404, "Invitation not found")
    group = _locked_group(db, invitation.group_id)
    if invitation.expires_at.replace(tzinfo=timezone.utc) <= utc_now():
        raise HTTPException(410, "Invitation expired")
    if _is_blocked(db, account_id, group.owner_id):
        raise HTTPException(403, "Invitation blocked")
    count = db.scalar(select(func.count()).select_from(GroupMember).where(
        GroupMember.group_id == group.id, GroupMember.status == "active",
    )) or 0
    if count >= MAX_MEMBERS:
        raise HTTPException(409, "Group is full")
    membership = db.scalar(select(GroupMember).where(
        GroupMember.group_id == group.id, GroupMember.account_id == account_id,
    ))
    if membership is None:
        membership = GroupMember(group_id=group.id, account_id=account_id,
                                 joined_after=group.next_ordinal)
        db.add(membership)
    else:
        if membership.status == "active":
            raise HTTPException(409, "Already a member")
        membership.status = "active"
        membership.joined_after = group.next_ordinal
        membership.joined_at = utc_now()
    invitation.status = "accepted"
    db.commit()
    request.app.state.group_realtime.messages_changed(group.id)
    return _out(db, group)


@router.post("/invitations/{invitation_id}/decline", status_code=204)
def decline_invitation(invitation_id: str, account: Account = Depends(get_current_account),
                       db: Session = Depends(get_db)) -> None:
    account_id = account.id
    _write_lock(db)
    invitation = db.scalar(select(GroupInvitation).where(GroupInvitation.id == invitation_id)
                           .with_for_update())
    if invitation is None or invitation.invitee_id != account_id or invitation.status != "pending":
        raise HTTPException(404, "Invitation not found")
    invitation.status = "declined"
    db.commit()


def _is_blocked(db: Session, one_id: str, other_id: str) -> bool:
    return db.scalar(select(GroupBlock.id).where(or_(
        (GroupBlock.blocker_id == one_id) & (GroupBlock.blocked_id == other_id),
        (GroupBlock.blocker_id == other_id) & (GroupBlock.blocked_id == one_id),
    ))) is not None


@router.post("/{group_id}/invitations", response_model=InvitationOut, status_code=201)
def invite_member(group_id: str, payload: InviteMember,
                  account: Account = Depends(get_current_account),
                  db: Session = Depends(get_db)) -> InvitationOut:
    account_id = account.id
    _write_lock(db)
    group = _locked_group(db, group_id)
    _member(db, group_id, account_id)
    if group.owner_id != account_id:
        raise HTTPException(403, "Only the group owner can invite members")
    invitee = db.scalar(select(Account).where(Account.email == payload.email, Account.is_active.is_(True)))
    if invitee is None or invitee.id == account_id:
        raise HTTPException(404, "No eligible registered account found")
    if _is_blocked(db, account_id, invitee.id):
        raise HTTPException(403, "Invitation blocked")
    active = db.scalar(select(GroupMember.id).where(
        GroupMember.group_id == group_id, GroupMember.account_id == invitee.id,
        GroupMember.status == "active",
    ))
    if active:
        raise HTTPException(409, "Already a member")
    count = db.scalar(select(func.count()).select_from(GroupMember).where(
        GroupMember.group_id == group_id, GroupMember.status == "active",
    )) or 0
    if count >= MAX_MEMBERS:
        raise HTTPException(409, "Group is full")
    pending = db.scalar(select(GroupInvitation).where(
        GroupInvitation.group_id == group_id, GroupInvitation.invitee_id == invitee.id,
        GroupInvitation.status == "pending", GroupInvitation.expires_at > utc_now(),
    ))
    if pending:
        return _invitation_out(db, pending)
    invitation = GroupInvitation(group_id=group_id, inviter_id=account_id,
                                 invitee_id=invitee.id,
                                 expires_at=utc_now() + timedelta(days=INVITATION_DAYS))
    db.add(invitation)
    db.commit()
    return _invitation_out(db, invitation)


@router.get("/{group_id}", response_model=GroupOut)
def get_group(group_id: str, account: Account = Depends(get_current_account),
              db: Session = Depends(get_db)) -> GroupOut:
    group, _ = _member(db, group_id, account.id)
    return _out(db, group)


@router.get("/{group_id}/members", response_model=list[MemberOut])
def list_members(group_id: str, account: Account = Depends(get_current_account),
                 db: Session = Depends(get_db)) -> list[MemberOut]:
    _member(db, group_id, account.id)
    rows = db.execute(select(GroupMember, Account).join(Account, Account.id == GroupMember.account_id).where(
        GroupMember.group_id == group_id, GroupMember.status == "active",
    ).order_by(GroupMember.joined_at)).all()
    return [MemberOut(account_id=person.id, display_name=person.display_name,
                      role=member.role, joined_at=member.joined_at)
            for member, person in rows]


@router.get("/{group_id}/messages", response_model=list[MessageOut])
def list_messages(group_id: str, account: Account = Depends(get_current_account),
                  db: Session = Depends(get_db)) -> list[MessageOut]:
    _, membership = _member(db, group_id, account.id)
    rows = db.scalars(select(GroupMessage).where(
        GroupMessage.group_id == group_id, GroupMessage.ordinal > membership.joined_after,
    ).order_by(GroupMessage.ordinal.desc()).limit(200)).all()
    return [_message_out(db, row) for row in reversed(rows)]


@router.websocket("/{group_id}/live")
async def group_live(websocket: WebSocket, group_id: str) -> None:
    """Notify a member to reload messages; never transmit private content here."""
    await websocket.accept()
    try:
        auth = await asyncio.wait_for(websocket.receive_json(), timeout=10)
    except WebSocketDisconnect:
        return
    except (asyncio.TimeoutError, ValueError):
        await websocket.close(code=WS_UNAUTHENTICATED)
        return
    if not isinstance(auth, dict) or auth.get("type") != "auth":
        await websocket.close(code=WS_UNAUTHENTICATED)
        return
    token = auth.get("token")
    if not isinstance(token, str):
        await websocket.close(code=WS_UNAUTHENTICATED)
        return
    account_id, close_code = _live_identity(websocket, group_id, token)
    if account_id is None:
        await websocket.close(code=close_code or WS_NOT_FOUND)
        return

    subscriber = websocket.app.state.group_realtime.subscribe(group_id, account_id)

    async def forward_events() -> None:
        while True:
            event = await subscriber.queue.get()
            if event == "access_revoked":
                await websocket.close(code=WS_NOT_FOUND)
                return
            await websocket.send_json({"type": event})

    async def monitor_connection() -> None:
        while True:
            try:
                await asyncio.wait_for(websocket.receive_text(), timeout=30)
            except asyncio.TimeoutError:
                pass
            except WebSocketDisconnect:
                return
            _, revoked_code = _live_identity(websocket, group_id, token)
            if revoked_code is not None:
                await websocket.close(code=revoked_code)
                return

    sender: asyncio.Task[None] | None = None
    monitor: asyncio.Task[None] | None = None
    try:
        await websocket.send_json({"type": "ready"})
        sender = asyncio.create_task(forward_events())
        monitor = asyncio.create_task(monitor_connection())
        # Waiting for either task means a membership revocation can finish the
        # request immediately instead of leaving receive_text blocked for up to
        # 30 seconds. The finally block also removes idle disconnected clients.
        await asyncio.wait({sender, monitor}, return_when=asyncio.FIRST_COMPLETED)
    except WebSocketDisconnect:
        pass
    finally:
        websocket.app.state.group_realtime.unsubscribe(subscriber)
        tasks = [task for task in (sender, monitor) if task is not None]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


def _live_identity(websocket: WebSocket, group_id: str, token: str) -> tuple[str | None, int | None]:
    payload = decode_access_token(token, websocket.app.state.settings.auth_secret)
    if payload is None:
        return None, WS_UNAUTHENTICATED
    account_id = str(payload["sub"])
    with websocket.app.state.session_factory() as db:
        account = db.get(Account, account_id)
        if account is None or not account.is_active:
            return None, WS_UNAUTHENTICATED
        try:
            _member(db, group_id, account_id)
        except HTTPException:
            return None, WS_NOT_FOUND
    return account_id, None


@router.post("/{group_id}/messages", response_model=MessageOut, status_code=201)
def send_message(group_id: str, payload: SendGroupMessage, request: Request,
                 account: Account = Depends(get_current_account),
                 db: Session = Depends(get_db)) -> MessageOut:
    account_id = account.id
    _write_lock(db)
    group = _locked_group(db, group_id)
    _, membership = _member(db, group_id, account_id)
    previous = db.scalar(select(GroupMessage).where(
        GroupMessage.group_id == group_id, GroupMessage.sender_id == account_id,
        GroupMessage.client_message_id == payload.client_message_id,
    ))
    if previous:
        if previous.ordinal <= membership.joined_after:
            raise HTTPException(409, "Retry ID belongs to an earlier membership")
        if previous.content != payload.content:
            raise HTTPException(409, "This retry ID was used for another message")
        return _message_out(db, previous)
    group.next_ordinal += 1
    message = GroupMessage(group_id=group_id, sender_id=account_id,
                           ordinal=group.next_ordinal, content=payload.content,
                           client_message_id=payload.client_message_id)
    db.add(message)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "Message retry conflict")
    request.app.state.group_realtime.messages_changed(group_id)
    return _message_out(db, message)


@router.post("/{group_id}/leave", status_code=204)
def leave_group(group_id: str, request: Request,
                account: Account = Depends(get_current_account),
                db: Session = Depends(get_db)) -> None:
    account_id = account.id
    _write_lock(db)
    group = _locked_group(db, group_id)
    _, membership = _member(db, group_id, account_id)
    if group.owner_id == account_id:
        raise HTTPException(409, "Owner must close the group")
    membership.status = "left"
    db.commit()
    request.app.state.group_realtime.member_left(group_id, account_id)
    request.app.state.group_realtime.messages_changed(group_id)


@router.post("/{group_id}/close", status_code=204)
def close_group(group_id: str, request: Request,
                account: Account = Depends(get_current_account),
                db: Session = Depends(get_db)) -> None:
    account_id = account.id
    _write_lock(db)
    group = _locked_group(db, group_id)
    _member(db, group_id, account_id)
    if group.owner_id != account_id:
        raise HTTPException(403, "Only the owner can close the group")
    group.status = "closed"
    db.commit()
    request.app.state.group_realtime.group_closed(group_id)


@router.post("/{group_id}/reports", status_code=201)
def report_group(group_id: str, payload: CreateReport,
                 account: Account = Depends(get_current_account),
                 db: Session = Depends(get_db)) -> dict[str, str]:
    account_id = account.id
    _write_lock(db)
    _, membership = _member(db, group_id, account_id)
    if payload.message_id:
        message = db.get(GroupMessage, payload.message_id)
        if (message is None or message.group_id != group_id
                or message.ordinal <= membership.joined_after):
            raise HTTPException(404, "Message not found")
    report = GroupReport(reporter_id=account_id, group_id=group_id,
                         message_id=payload.message_id, reason=payload.reason)
    db.add(report)
    db.commit()
    return {"id": report.id, "status": "recorded"}


@router.post("/blocks", status_code=201)
def block_invitations(payload: BlockAccount,
                      account: Account = Depends(get_current_account),
                      db: Session = Depends(get_db)) -> dict[str, str]:
    account_id = account.id
    _write_lock(db)
    other = db.get(Account, payload.account_id)
    if other is None or other.id == account_id:
        raise HTTPException(404, "Account not found")
    existing = db.scalar(select(GroupBlock).where(
        GroupBlock.blocker_id == account_id, GroupBlock.blocked_id == other.id,
    ))
    if existing is None:
        db.add(GroupBlock(blocker_id=account_id, blocked_id=other.id))
        db.commit()
    return {"status": "blocked"}
