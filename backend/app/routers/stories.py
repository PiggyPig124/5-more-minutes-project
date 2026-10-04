from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, HTTPException, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..dependencies import require_elder
from ..memory_models import PersonalMemory, Story, StoryMemoryLink
from ..memory_service import (bump_memory_revision, lock_owner_account,
                              memory_revision, purge_stories, require_memory_revision,
                              withdraw_story_shares)
from ..models import Account

router = APIRouter(prefix="/stories", tags=["stories"])


class StoryText(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=240)
    content: str = Field(min_length=1, max_length=30000)

    @field_validator("title", "content")
    @classmethod
    def trim_text(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("story text cannot be blank")
        return value


class StoryCreate(StoryText):
    memory_ids: list[str] = Field(default_factory=list, max_length=50)


class StoryPatch(StoryText):
    """Editing changes text only; original source links remain immutable."""


class StoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    content: str
    memory_ids: list[str]
    created_at: datetime
    updated_at: datetime
    revision: int


def _utc_timestamp(value: datetime) -> datetime:
    # SQLite drops tzinfo on persisted DateTime values. Keep the API instant
    # and serialization stable between a create response and later edits.
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _story_out(db: Session, story: Story) -> StoryOut:
    memory_ids = list(
        db.scalars(select(StoryMemoryLink.memory_id).where(StoryMemoryLink.story_id == story.id)).all()
    )
    return StoryOut(
        id=story.id,
        title=story.title,
        content=story.content,
        memory_ids=memory_ids,
        created_at=_utc_timestamp(story.created_at),
        updated_at=_utc_timestamp(story.updated_at),
        revision=memory_revision(db, story.owner_id),
    )


def _owner_story(db: Session, owner_id: str, story_id: str) -> Story:
    story = db.get(Story, story_id)
    if story is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Story not found")
    if story.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Story is private to its owner")
    return story


def _confirmed_memory_ids(db: Session, owner_id: str, memory_ids: list[str]) -> set[str]:
    requested = set(memory_ids)
    if len(requested) != len(memory_ids):
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="memory_ids must be unique")
    if not requested:
        return set()
    rows = db.scalars(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.id.in_(requested),
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
        )
    ).all()
    found = {row.id for row in rows}
    if found != requested:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Stories can reference only the owner's confirmed, unsuppressed memories",
        )
    return found


@router.get("", response_model=list[StoryOut])
def list_stories(account: Account = Depends(require_elder), db: Session = Depends(get_db)) -> list[StoryOut]:
    lock_owner_account(db, account.id)
    rows = db.scalars(select(Story).where(Story.owner_id == account.id).order_by(Story.updated_at.desc())).all()
    return [_story_out(db, story) for story in rows]


@router.post("", response_model=StoryOut, status_code=status.HTTP_201_CREATED)
def create_story(
    payload: StoryCreate,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision"),
) -> StoryOut:
    lock_owner_account(db, account.id)
    require_memory_revision(db, account.id, expected_revision)
    memory_ids = _confirmed_memory_ids(db, account.id, payload.memory_ids)
    story = Story(owner_id=account.id, title=payload.title, content=payload.content)
    db.add(story)
    db.flush()
    for memory_id in memory_ids:
        db.add(StoryMemoryLink(story_id=story.id, memory_id=memory_id))
    db.flush()
    bump_memory_revision(db, account.id)
    output = _story_out(db, story)
    db.commit()
    return output


@router.get("/{story_id}", response_model=StoryOut)
def get_story(
    story_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> StoryOut:
    lock_owner_account(db, account.id)
    return _story_out(db, _owner_story(db, account.id, story_id))


@router.patch("/{story_id}", response_model=StoryOut)
def patch_story(
    story_id: str,
    payload: StoryPatch,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision", ge=0),
) -> StoryOut:
    lock_owner_account(db, account.id)
    require_memory_revision(db, account.id, expected_revision)
    story = _owner_story(db, account.id, story_id)
    source_ids = list(db.scalars(select(StoryMemoryLink.memory_id).where(
        StoryMemoryLink.story_id == story.id)).all())
    _confirmed_memory_ids(db, account.id, source_ids)
    story.title = payload.title
    story.content = payload.content
    # Updating a private card revokes the old delivered text atomically. The
    # new text is never resent without a fresh recipient/content review.
    withdraw_story_shares(db, [story.id], account.id)
    bump_memory_revision(db, account.id)
    output = _story_out(db, story)
    db.commit()
    return output


@router.delete("/{story_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_story(
    story_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision"),
) -> Response:
    lock_owner_account(db, account.id)
    require_memory_revision(db, account.id, expected_revision)
    story = _owner_story(db, account.id, story_id)
    purge_stories(db, [story.id])
    revision = bump_memory_revision(db, account.id)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT,
                    headers={"X-Memory-Revision": str(revision)})
