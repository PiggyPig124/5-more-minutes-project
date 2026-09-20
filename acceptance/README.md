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
