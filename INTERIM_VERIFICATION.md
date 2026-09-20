# Interim milestone verification

Date: September 20, 2026. Scope: long-term personal memory retrieval, public
resource retrieval, stories, family messages, and an interim report.

## What is delivered

- Private memory candidates, explicit confirmation, correction, suppression,
  deletion, optional event dates, provenance, and cross-conversation retrieval.
- Separate public knowledge storage seeded with six verified HA/SWD records
  in Traditional Chinese, with official URLs and verification dates.
- Private story cards linked to confirmed memories, plus explicit recipient
  preview and confirmed sharing through a separate family-message permission.
- Two-way family text messages with idempotent retries and current permission
  checks. Existing care-task grants do not implicitly enable messaging.
- Chat responses receive retrieved evidence and display sources. Without a
  conversational key, replies remain a visibly labelled deterministic demo.
- [Interim report](INTERIM_REPORT_EN.md) and [source register](docs/KNOWLEDGE_SOURCES.md).

## Retrieval modes

Personal memory retrieval always filters ownership, confirmation, suppression,
deletion and supersession. Without embedding credentials it uses keyword
matching. A configured service supplies real vectors. SQLite computes cosine
similarity locally; PostgreSQL uses pgvector and a native cosine query, with an
HNSW index for supported dimensions. Reconfirm a memory to reindex after changing
the embedding model. Public retrieval conservatively finds lexical candidates
and optionally reranks them using embeddings; it does not claim unrestricted
semantic discovery of documents without lexical evidence.

The public seed SHA-256 is
`db33d44b08ae8fa4c5912d2e07304255f2bb4a8472cee46b7d0af00f04d063ca`.
Official source pages were checked by the research agent on the date above.
The directory record points to the official 18-district directory; individual
centre records have not all been imported into a searchable local directory.

## Verification

Completed against the final interim source:

| Check | Result |
| --- | --- |
| Backend tests | 28 passed |
| Foundation live API regression | 85 assertions passed |
| Interim live API journey | 55 assertions passed |
| Foundation process restart | 29 assertions passed |
| Interim memory/story persistence and withdrawal across restarts | 15 assertions passed |
| Flutter analysis | No issues found |
| Flutter tests | 21 passed; 2 opt-in live tests skipped |
| Separately enabled Dart live HTTP tests | 2 passed |
| Android debug APK and JavaScript web build | Both succeeded |

Browser inspection at 390 x 844 verified the home feature entries, memory
management empty state, and an official medical-fee-waiver resource result with
dates, conditions, next steps and a source button. Existing preview login and
account data were preserved; browser inspection did not create personal memories
or send family messages. Those mutations were tested with synthetic API and
Flutter fixtures. The preview backend successfully opened the existing foundation
SQLite database with the additional interim tables.

The app version is `0.2.0+2`. The debug APK is
`dist/anxin-companion-interim.apk` (154,334,141 bytes), SHA-256:
`feed825a63821bf9e8d2fe1588fb7d27d90d3489c323a5e101cbb66e256491b4`.
It targets the emulator API at `http://10.0.2.2:8000`. The web preview targets
`http://127.0.0.1:8012` and is served at `http://127.0.0.1:8088/`.
Build warnings include Android SDK XML tooling version mismatch and unsupported
Wasm dependencies; the delivered web build uses JavaScript, not Wasm.

Reproduce the new live checks against a disposable server/database:

```powershell
.\.venv\Scripts\python.exe -m pytest backend/tests -q
.\.venv\Scripts\python.exe acceptance/interim_api_acceptance.py --base-url http://127.0.0.1:8013
.\.venv\Scripts\python.exe acceptance/interim_restart_acceptance.py
cd app
flutter analyze
flutter test
flutter test test/live_api_test.dart --dart-define=RUN_LIVE_API_TESTS=true --dart-define=API_ORIGIN=http://127.0.0.1:8013
```

## Data lifecycle guarantees and limits

Correction produces a replacement candidate rather than silently confirming a
new fact. Withdrawal clears tracked chat references, summaries, derived stories,
their shared copies, and vector entries in application-controlled storage.
Memory revisions are checked before saving an in-flight response so a withdrawn
memory cannot be reintroduced by an answer generated from older context.
Standalone user-written text without memory/story provenance is not automatically
treated as a derivative of a memory. No deletion claim covers external screenshots,
exports, backups, or copies outside this application's control.

These checks do not establish live-model conversational quality, embedding
relevance on a representative corpus, clinical benefit, or welfare eligibility.
No live provider credentials were supplied. PostgreSQL/Docker runtime behavior
and physical Android interaction remain unverified in this environment; local
integration uses SQLite. Public deployment still requires migrations, rate
limiting, email verification, backup policy, and operational hardening.

Cantonese voice, push notifications, proactive greetings, a full local community
directory, safety assistance, real bookings, and welfare application submission
remain later-stage work. Family-message arrival is checked through refresh.
