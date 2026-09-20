# Anxin Companion backend

This directory contains the FastAPI foundation for identity, invitation-based
family authorization, private text conversations, persisted short-term
context, and explicitly confirmed care tasks.

Run the service from the repository root with:

```powershell
.\.venv\Scripts\python.exe -m uvicorn app.main:app --app-dir backend --reload
```

`DATABASE_URL` can point to PostgreSQL using the `postgresql+psycopg://` form.
SQLite is used when no database URL is configured. The schema is created on
startup for this foundation; production deployments should add migrations
before changing existing tables.

When `MODEL_API_KEY` or `OPENAI_API_KEY` is absent, responses use the
deterministic adapter and include `mode: "deterministic_demo"` plus a visible
`DEMO MODE` label. When a key is configured, the server calls the configured
OpenAI-compatible `/chat/completions` endpoint directly over HTTP. The API
returns a complete JSON response for text messages; streaming is intentionally
not part of this foundation contract.

## HTTP contract

All protected endpoints use `Authorization: Bearer <access_token>`.

* `POST /auth/register` and `POST /auth/login` return
  `{access_token, token_type, account}`. `GET /auth/me` returns the account.
* `POST /family-links/invitations` creates a seven-day invitation and returns
  its one-time raw `token`. `GET /family-links/invitations` lists invitations
  visible to the elder or addressed caregiver. A caregiver accepts with
  `POST /family-links/invitations/accept` and `{token}` (the id-specific
  `/family-links/invitations/{id}/accept` form is also supported). `GET
  /family-links` lists links, and `POST /family-links/{id}/revoke` revokes a
  link. Only the `care_tasks` scope exists; private chat is never shared.
* `POST /conversations` creates a private conversation. `GET /conversations`
  lists the current account's conversations. `GET /conversations/{id}` and
  `GET /conversations/{id}/messages` read one conversation. `POST
  /conversations/{id}/messages` accepts `{content, client_message_id?}` and
  returns `{conversation, user_message, assistant_message, action, mode}`.
* A message can produce a pending task proposal. `POST
  /actions/{id}/confirm` with optional `{idempotency_key}` creates its task in
  one transaction and is safe to retry. `POST /actions/{id}/dismiss` declines
  it. A date in a reminiscence does not create an action.
* `GET /tasks` lists the elder's tasks or linked caregivers' care tasks.
  `PATCH /tasks/{id}` updates an authorized task.

The foundation keeps messages and a rolling summary in the database. Family
links authorize care-task records only, and revocation is checked on every
task request.
