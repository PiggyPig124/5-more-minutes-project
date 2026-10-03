"""Seed community activities and scam safety resources into the database.

Called from the application lifespan after initialize_database and
seed_resources.  Idempotent: existing rows with matching ids and content
hashes are skipped.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .activity_catalog_models import CommunityActivity
from .scam_models import ScamResource


def _content_hash(data: dict) -> str:
    payload = json.dumps(data, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def seed_community_activities(db: object) -> int:
    """Seed inherited activity examples, never mark them source-verified."""
    path = Path(__file__).resolve().parents[1] / "data" / "community_activities.json"
    try:
        records = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    changed = 0
    for record in records:
        row = db.get(CommunityActivity, record["id"])
        if row is None:
            db.add(CommunityActivity(
                id=record["id"],
                title=record["title"],
                description=record["description"],
                organizer=record["organizer"],
                district=record["district"],
                address=record.get("address", ""),
                url=record.get("url", ""),
                start_date=record.get("start_date"),
                end_date=record.get("end_date"),
                schedule_note=record.get("schedule_note", ""),
                mobility_note=record.get("mobility_note", ""),
                interest_tags=record.get("interest_tags", []),
                skill_tags=record.get("skill_tags", []),
                contribution_type=record.get("contribution_type", "participate"),
                # These inherited examples link to organization homepages;
                # they do not substantiate the stated event details.
                verified=False,
                verified_at=None,
            ))
            changed += 1
        elif row.verified:
            row.verified = False
            row.verified_at = None
            changed += 1
    db.commit()
    return changed


def seed_scam_resources(db: object) -> int:
    """Idempotently seed verified anti-scam guidance resources."""
    path = Path(__file__).resolve().parents[1] / "data" / "scam_resources.json"
    try:
        records = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    changed = 0
    for record in records:
        ch = _content_hash(record)
        row = db.get(ScamResource, record["id"])
        if row is None:
            db.add(ScamResource(
                id=record["id"],
                title=record["title"],
                excerpt=record["excerpt"],
                source_url=record["source_url"],
                verified_at=record["verified_at"],
                scam_type=record["scam_type"],
                warning_signs=record.get("warning_signs", []),
                verification_steps=record.get("verification_steps", []),
                next_steps=record.get("next_steps", []),
                official_contacts=record.get("official_contacts", []),
                search_terms=record.get("search_terms", []),
                source_authority=record.get("source_authority", ""),
                content_hash=ch,
            ))
            changed += 1
    db.commit()
    return changed
