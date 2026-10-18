# Foundation API acceptance runner

`foundation_api_acceptance.py` is a dependency-free black-box check for the
Foundation stage.  It creates a unique elder and caregiver account, exercises
the token-only invitation flow, creates a private conversation, confirms one
care task, retries that confirmation, checks linked-task visibility, and
revokes the family link.  It deliberately checks that a linked caregiver
cannot read the elder's private conversation.

The runner does not open a database, call ORM models, or delete records.  Run
the server with a fresh temporary database under the server operator's
control, then point the runner at that URL.  On PowerShell:

```powershell
$dbPath = Join-Path $env:TEMP ("anxin-acceptance-" + [guid]::NewGuid().ToString() + ".db")
$env:DATABASE_URL = "sqlite:///" + ($dbPath -replace '\\', '/')
$env:DEMO_MODE = "1"
$env:AUTH_SECRET = "replace-with-a-local-only-stable-secret"

# Keep this process running in one terminal.
.venv\Scripts\python.exe -m uvicorn app.main:app --app-dir backend --port 8000

# Run in another terminal from the repository root.
.venv\Scripts\python.exe acceptance\foundation_api_acceptance.py --base-url http://127.0.0.1:8000
```

The temporary database path should be removed by the operator after stopping
the server.  If the runner is pointed at a shared environment, its accounts
are still unique but the resulting test records remain there.

The expected wire contract is recorded in
[`FOUNDATION_API_CONTRACT.md`](FOUNDATION_API_CONTRACT.md).  The acceptance
script intentionally fails when the frozen token-only invitation acceptance
route (`POST /family-links/invitations/accept`) or idempotent confirmation
semantics are missing.  A failure is evidence about the running server; it is
not evidence that an unstarted or unreachable server passed.

Use `--verbose` to print a JSON assertion summary.  The report does not print
bearer tokens or private message bodies.

For a process-lifecycle check, run
`.venv\Scripts\python.exe acceptance\process_restart_acceptance.py`.  This
script launches two short-lived API processes against the same temporary
SQLite database and signing secret, then removes its fixture.  It verifies
old-token validity, reloads bounded context and pending proposals, and checks
that the deterministic reply can recall a persisted marker after restart.

The interim journey runner adds confirmed personal memory recall, suppression,
correction, story sharing, replies, deletion propagation, official resource
provenance, abstention, and family-message revocation:

```powershell
.venv\Scripts\python.exe acceptance\interim_api_acceptance.py --base-url http://127.0.0.1:8013
```

Use a disposable demo-mode server. This script creates synthetic users and
deletes only memories and stories it creates during the test.

Run `.venv\Scripts\python.exe acceptance\interim_restart_acceptance.py` for
the interim lifecycle check. It starts three short-lived API processes against
one temporary SQLite database, verifies confirmed memory and story persistence,
then checks that withdrawal and conversation sanitization survive another restart.
It removes its own temporary fixture after completion.

## Community and phase-1 contract (2026-10-15)

Run `acceptance/echo_mvp_phase1_acceptance.py --report <output.json>` for the
offline, disposable-process phase-1 journey. It retains the guest privacy,
memory consent/Save, private skill review, caregiver denial, deletion and
restart assertions. Only the community provider transport is a synthetic
SmartPLAY-shaped fixture, visibly named "Synthetic acceptance". The real
parser, cache, HTTP routes and persistence/permission code still run. This is
not a live provider or event-availability verification.

The current application enables the fixed official SmartPLAY activity snapshot
by default. It preserves original activity URLs and retrieval/event dates,
marks availability unverified, and does not invent registration links. A second
read must use the cache without rewriting its retrieval date. Opportunity
providers remain disabled: the correct result is `unavailable` with
`sources_disabled`, no listings, no citations and no retrieval date. An activity
must not be relabeled as a volunteering opportunity.

`GET /community/activities` synchronously waits for a completed search. There is
no 202/job identifier or progress-polling API. `live`, `cache` and `unavailable`
describe the returned data, not pending/running states. Do not retry or poll a
slow request until it reports `live`, and do not accept `unavailable` as success
in the controlled enabled-source fixture.

The older phase-1 check used the generic 15-second HTTP request timeout for a
real external download; a historical run returned a valid snapshot in 38.188
seconds, then would have hit an obsolete disabled-source assertion. That does
not establish an acceptable product-latency target. The generic 15-second
client timeout is unchanged. Offline phase-1 has an independent 60-second
whole-worker deadline (including two process starts and its consent/restart
journey); timeout or any failed assertion remains a nonzero result.

The separate live smoke check remains opt-in:

```powershell
.venv\Scripts\python.exe acceptance\community_live_search_acceptance.py --live --report <output.json>
```

It has a 90-second whole-worker deadline, rather than an enlarged per-read
HTTP timeout or a retry-until-success loop. The current adapter checks a
45-second stream/processing budget and uses a 12-second read timeout; startup,
a final blocked read and subsequent cached/private checks also need room.
The worker deadline is the independent hard stop, not a claim that the adapter
always finishes in 45 seconds. A failed download, bad schema, wrong source,
or unavailable provider still fails the live smoke check. A valid empty
snapshot may report `no_matches`; that is different from provider failure.

Both runners strip provider credentials, force deterministic chat, and create
only synthetic accounts/databases inside an owned temporary directory. Hidden
workers and descendant API processes are stopped on deadline. Their JSON
report retains outcome, elapsed time, deadline, exit code and a bounded output
tail even on failure/timeout. The report path is printed; choose a task-local
path for retained diagnostics. These reports contain only this runner's
synthetic fixture, never point the scripts at an existing user database.
On Windows a kill-on-close Job Object owns the worker before a stdin handshake
allows its target code to run, so descendants are still stopped if the worker
crashes first. A worker deadline can be followed by up to five seconds of output
drain/cleanup; any cleanup error is retained in the report and prevents success.
The process lifecycle regression is verified on Windows; this does not certify
other operating systems.

Regression tests for the validators and absolute deadline (no live network):

```powershell
.venv\Scripts\python.exe -m pytest acceptance\test_community_acceptance.py -q
```
