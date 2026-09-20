# 安心伴 / Anxin Companion

Interim implementation of the [implementation plan](IMPLEMENTATION_PLAN_EN.md): a Flutter app with older-adult and caregiver experiences, backed by a Python API. It covers accounts, family authorization, text conversations, short-term context, confirmed personal memories, official resource retrieval, private stories, and consented family messages.

Cantonese voice, scheduled notifications, and crisis escalation belong to later stages. Personal retrieval supports a configurable embedding service; without credentials it is explicitly labelled keyword retrieval. The default conversational adapter is still a deterministic demo.

使用与演示操作请参阅 [中文使用指南](docs/USER_GUIDE_ZH.md)。

## Project layout

- `app/`: Flutter client with separate authenticated elder and caregiver experiences.
- `backend/`: FastAPI, SQLAlchemy persistence, and LangGraph conversation flow.
- `acceptance/`: independent live API acceptance checks.
- `scripts/`: local startup helpers.
- `FOUNDATION_ACCEPTANCE.md`: acceptance requirements and evidence scope.
- `VERIFICATION.md`: archived foundation verification results.
- `INTERIM_REPORT_EN.md`: interim project report.
- `INTERIM_VERIFICATION.md`: interim checks, reproduction, and remaining limits.
- `docs/KNOWLEDGE_SOURCES.md`: official source provenance and refresh procedure.

## Start the backend locally

Python 3.12 is recommended. From this folder in PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r backend\requirements.lock.txt
$env:AUTH_SECRET = .\.venv\Scripts\python.exe -c "import secrets; print(secrets.token_urlsafe(48))"
.\scripts\run-backend.ps1
```

Keep the same private `AUTH_SECRET` across restarts if existing login sessions should remain valid. Never commit it. The local backend uses SQLite unless `DATABASE_URL` is set. API documentation is available at `http://127.0.0.1:8000/docs` while the server is running.

### Model configuration

Without model credentials, the backend runs an explicitly labelled deterministic demonstration adapter. It is suitable for checking account, conversation, and confirmation flows; it is not a full AI companion. To use a live compatible model, set these variables before starting the backend:

```powershell
$env:MODEL_API_KEY = '<your-key>'
$env:MODEL_BASE_URL = 'https://your-provider.example/v1'
$env:MODEL_NAME = '<your-model>'
```

The key stays on the server. Configure a model that supports the backend's documented structured response contract. Provider errors are surfaced rather than silently treated as successful actions.

### Personal memory and public retrieval

Save a memory as a candidate, review it, then confirm it. Only confirmed,
unsuppressed facts, experiences, and preferences can be recalled across
conversations. Emotion entries are excluded from factual recall. Corrections
create a new candidate for review. Suppression, correction, and deletion withdraw
related story cards and sanitize their tracked chat references and shared copies.
Deletion also removes vectors and correction-chain content from application
storage. This does not erase screenshots, exports, or recipients' external copies.

For semantic retrieval, configure an embedding provider separately:

```powershell
$env:EMBEDDING_API_KEY = '<your-embedding-key>'
$env:EMBEDDING_BASE_URL = 'https://your-provider.example/v1'
$env:EMBEDDING_MODEL = '<multilingual-embedding-model>'
$env:EMBEDDING_DIMENSIONS = '1536'
```

Set the dimension to the model's output size before creating the PostgreSQL
schema. Changing the dimension on an existing PostgreSQL database requires a
migration and reindexing. Reconfirming an existing memory refreshes its embedding
after provider configuration or a model change. SQLite supports local development;
PostgreSQL uses the pgvector extension. Real provider quality requires separate
evaluation with Hong Kong Cantonese and Traditional Chinese examples.

The public knowledge collection contains six reviewed official source records.
It is seeded into separate public tables at startup. Results include conditions,
missing information, three next steps, and an official link. They are leads for
enquiry, not eligibility decisions. See the source register before updating them.

### Family messages and stories

New invitations can explicitly include `family_messages`; existing `care_tasks`
links gain no additional permissions automatically. Select the message permission
and accept a new invitation to enable it. Both roles can exchange text within
that scope. Sharing a private story requires a recipient/content preview and
confirmation. Retries reuse the original operation ID. Revoking a link blocks
subsequent reads and sends, including retries. Message updates currently require
refreshing the screen; push notifications belong to the following milestone.

## Start the Flutter client

Install Flutter and the Android SDK, then:

```powershell
cd app
flutter pub get
flutter run --dart-define=API_ORIGIN=http://10.0.2.2:8000
```

`10.0.2.2` is the Android emulator's route to the host. For a USB-connected Android phone, use `adb reverse tcp:8000 tcp:8000` and pass `http://127.0.0.1:8000`. For deployment, use an HTTPS API endpoint.

Create separate elder and caregiver accounts. The elder explicitly invites the caregiver to access care tasks; this does not grant access to private conversations. Use two app sessions/devices to test cross-account behavior.

## Checks

```powershell
.\.venv\Scripts\python.exe -m pytest backend\tests -q
cd app
flutter analyze
flutter test
flutter build apk --debug --dart-define=API_ORIGIN=http://10.0.2.2:8000
```

Run the independent acceptance script against a disposable backend database, not a real family's database. Consult `acceptance/` for its exact invocation.

The real Dart HTTP integration test is opt-in. With a disposable backend running:

```powershell
cd app
flutter test test/live_api_test.dart --dart-define=RUN_LIVE_API_TESTS=true --dart-define=API_ORIGIN=http://127.0.0.1:8000
```

The current debug APK at `dist/anxin-companion-interim.apk` targets
`http://10.0.2.2:8000` for the Android emulator. A physical phone needs a rebuild
with its reachable API address (for example the USB reverse address above).

## PostgreSQL deployment scaffold

`compose.yaml` supplies PostgreSQL with pgvector and the API. Set `POSTGRES_PASSWORD` to a URL-safe random password and `AUTH_SECRET` to a separate random secret before `docker compose up --build`. The API port binds only to host loopback; production access requires an HTTPS reverse proxy.

The service creates missing tables and seeds the reviewed public collection at
startup. The interim schema adds tables to the foundation without deleting its
accounts or conversations. Versioned migrations, operational hardening, email
verification, and public deployment review are required before broader real-user
rollout. Vector search requires configuring the embedding service; installing
pgvector alone does not create embeddings.

## Verification limits

Automated API tests, live HTTP checks, Flutter widget tests, static analysis, and APK builds establish different kinds of evidence. An APK build alone is not real-device acceptance, and demonstration-mode tests do not verify a live model provider. See the verification record delivered with this implementation for actual results.
