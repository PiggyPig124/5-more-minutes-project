"""Consent checks shared by memory, chat, and community features."""

from __future__ import annotations

from sqlalchemy.orm import Session

from .memory_models import MemoryConsent


def memory_consent_enabled(db: Session, owner_id: str) -> bool:
    """Return explicit memory opt-in; absence of a row always means disabled."""

    consent = db.get(MemoryConsent, owner_id)
    return bool(consent and consent.enabled)
