# Backend explicit task sharing implementation plan

Design reviewed against current routes: care_tasks currently grants broad reads and writes. Replace that predicate with explicit per-item consent, retaining owner editing. No historical shares or notification consent inferred.

1. Add failing API isolation/consent/idempotency/notification tests.
2. Add additive TaskShare model with partial active uniqueness and request key uniqueness, canonical UTC fingerprints and serialized authorization service.
3. Implement private-owner and minimal shared-readonly task routes, owner preview and share CRUD; revoke on content edits.
4. Serialize family accept/revoke and permanently revoke on scope removal. Use share identity for shared reminders and live authorization before inbox limits/PATCH.
5. Extend race/restart/legacy/notification tests; replace obsolete broad access test and run complete backend suite with isolated temporary DBs.

No caregiver reply state, preference changes, real database writes or external services. SQLite uses BEGIN IMMEDIATE; PostgreSQL locks Account→FamilyLink→Task→TaskShare consistently.

## Completed implementation and verification

- New `task_share_models.py` and `task_share_service.py`; additive startup import in `db.py`. No existing task rows or historical consent backfilled.
- Owner task views expose UTC-normalized content fingerprints and `access_mode=owner`; shared views expose only task display fields, task/owner/share identifiers and `shared_readonly`. Source action/conversation/memory identifiers are omitted.
- Task content/type/due edits revoke consent; status-only/equivalent-UTC edits retain consent. PATCH rejects unknown fields.
- Family accept/revoke serialize against sharing; removal of care_tasks and reconnection permanently revoke old shares.
- Shared reminders use consent identity and live authorization; legacy task reminders are owner-only. Inbox visibility filters precede the 100-item limit and PATCH rechecks authorization under the same guard.
- Existing obsolete broad family-access test now verifies default private, explicit item consent, then revoked visibility.
- 19 new sharing cases cover isolation, readonly writes, idempotency, content changes, scope changes/reconnection, old DB initialization/restart, memory independence, fail-closed missing schema, active uniqueness, concurrent creates/edit/revoke, notification replay/authorization/limits.

Final command: `.venv/Scripts/python.exe -m pytest -q -p no:cacheprovider --basetemp C:/Users/Administrator/Documents/Codex/2026-10-03/task/sharing-full3` from backend, with PYTHONDONTWRITEBYTECODE=1 and model/OpenAI API keys cleared. Result: **213 passed in 68.58s**, one pre-existing Starlette BlockingPortal deprecation warning. `git diff --check` clean. PostgreSQL locking/index paths are implemented but were not runtime-tested; this verification uses separate file-backed SQLite databases. No deployment, external service, package install or real database access performed.
