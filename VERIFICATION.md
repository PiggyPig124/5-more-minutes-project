# Foundation verification

Date: September 20, 2026. Scope: the Foundation milestone in
[IMPLEMENTATION_PLAN_EN.md](IMPLEMENTATION_PLAN_EN.md).

## Implemented behavior

- One Flutter application provides separate elder and caregiver experiences,
  with a FastAPI server owning authentication, permissions, chat, and tasks.
- An elder can register, sign in, open a private conversation, send text, and
  reload persisted history. The server supplies the latest 12 messages and a
  bounded extract of older messages to the conversation graph.
- A requested care task first appears as a proposal. Confirmation creates one
  task; dismissal creates none. Retrying a message or confirmation must not
  duplicate the completed operation.
- Family links require an invitation and grant only care-task access. Linked
  caregivers cannot read private conversations. Revoking a link removes
  access on subsequent server requests.
- Local drafts and pending retry identities use account-scoped secure storage.
  Responses from an earlier account cannot populate the current account's
  private conversation state.
- Missing model credentials select a visibly labelled deterministic demo.
  A compatible model adapter keeps its key on the server. Provider failures
  return a retryable error instead of saving a successful conversation turn.

## Verification results

All checks below were run by the primary reviewer against the final source.

| Check | Result | Evidence scope |
|---|---|---|
| Backend pytest suite | 10 passed | Auth, isolation, context, model failure/retry, concurrent message pairing, competing action decisions. |
| Fresh-process HTTP acceptance | 85 assertions passed | Actual server at local port 8012, fresh SQLite database, demo mode. |
| Process-restart acceptance | 29 assertions passed | Two real API processes, persistent token, context and pending proposal checks. |
| Flutter analysis | No issues found | Final Dart client source. |
| Flutter test suite | 12 passed; 1 opt-in integration test skipped | Widget navigation, failure states, account isolation and retry identities. |
| Opt-in Dart HTTP integration | 1 passed separately | Actual Dart client against the final API: invitation, private chat, confirmation, sharing and revoke. |
| Android debug build | Passed | Final APK copied to `dist/anxin-companion-foundation.apk`. |
| Flutter JavaScript web build | Passed | Final preview reloaded and login screen checked. |

The backend suite emits one dependency deprecation warning from Starlette/AnyIO.
The web build reports that the secure-storage web plugin does not support the
optional WebAssembly target, plus a Cupertino font discovery warning. The
delivered web build uses JavaScript; neither warning prevented that build.

Test commands are documented in the README and acceptance directory. The
earlier failed widget assertions and retry/intent defects were corrected before
these final checks. No implementation changes followed the final checks.

## Manual interface check

The actual Flutter web build was opened in the local browser and checked at
390 x 844 pixels. A synthetic elder account completed registration, opened a
conversation, sent a message, confirmed the resulting proposal, and viewed
the created task. The layout had no observed overflow in that flow. The
temporary viewport override was reset afterward.

The final web build was then reloaded against the final server and its login
screen inspected at the default viewport. The local preview is at
`http://127.0.0.1:8088` while the preview processes remain running.

## Delivery and reproduction

- [Setup and run commands](README.md)
- [Acceptance commands and contract](acceptance/README.md)
- Debug Android APK: `dist/anxin-companion-foundation.apk`
- Flutter web build: `app/build/web/`

APK SHA-256: `2fbf22a0a596e646c8f4622c6da2c5e9b125f09b873c1e13fbbd102f59341d41`.

The APK targets `http://10.0.2.2:8000`, the Android emulator's route to a
backend on the host. Start the API using the README. For a physical phone,
rebuild with a reachable API address. This debug APK is a development artifact.

## Limits of this acceptance

No Android phone or emulator was connected for device interaction. A successful
APK build is therefore build evidence, not physical-device testing. The manual
UI check used Flutter web, and the Dart HTTP integration check used the real API.

No live model credentials were supplied. Companion response quality and live
provider behavior have not been accepted; provider payload and failure handling
are covered with controlled test adapters. Local database checks use SQLite.
The PostgreSQL/pgvector Docker scaffold was not run because Docker is unavailable
in this environment. Production deployment, versioned schema migrations, email
verification, rate limiting, and operational hardening remain future work.

The short-term summary is a bounded textual extract, not semantic long-term
memory. Personal memory RAG, welfare RAG, Cantonese speech, family messages,
scheduled notifications, crisis escalation, and real appointment bookings are
outside this milestone. Creating a task does not schedule a notification or
book an external appointment. The LangGraph foundation currently has one
response node; confirmation state is persisted and enforced by the API.
