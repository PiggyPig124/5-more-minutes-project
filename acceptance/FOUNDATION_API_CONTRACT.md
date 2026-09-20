# Foundation API acceptance contract

This contract is the wire-level boundary used by `foundation_api_acceptance.py`.
It deliberately covers only the Foundation stage in `IMPLEMENTATION_PLAN_EN.md`:
identity, invitation links, private conversations, short-term context, and
confirmed care tasks.  The runner uses a fresh server-side database for each
run; it does not delete data from a shared environment.

## Transport and authentication

The server is expected at a caller-supplied base URL (for example,
`http://127.0.0.1:8000`).  JSON requests use `Content-Type: application/json`.
Protected requests use `Authorization: Bearer <access_token>`.

`GET /health` returns HTTP 200 while the API is ready.  A successful protected
request with an invalid or expired token returns HTTP 401.  A valid account
that does not own or have an explicit scope for a resource returns HTTP 403 or
404; either status is acceptable for preventing resource disclosure.

## Required endpoints

| Method | Path | Request | Required result |
| --- | --- | --- | --- |
| POST | `/auth/register` | `{email,password,display_name,role}` | 201/200 and `{access_token,account}` |
| POST | `/auth/login` | `{email,password}` | 200 and `{access_token,account}`; wrong password is 401/403 |
| GET | `/auth/me` | — | 200 and the authenticated account |
| POST | `/family-links/invitations` | `{email,scopes:["care_tasks"]}` | 201/200 and invitation `id`, `status=pending`, and a one-time `token` |
| POST | `/family-links/invitations/accept` | `{token}` | 200/201 and an active family link |
| GET | `/family-links` | — | 200 list of links visible to the caller |
| DELETE | `/family-links/{id}` | — | 200/204; link becomes revoked immediately |
| POST | `/conversations` | `{title}` | 201/200 and conversation `id` owned by caller |
| GET | `/conversations/{id}` | — | 200 for owner; 403/404 for an unauthorized caller |
| POST | `/conversations/{id}/messages` | `{content}` | 200/201 with `user_message`, `assistant_message`, optional `action`, and `mode` |
| GET | `/tasks` | — | 200 list filtered by owner and active `care_tasks` authorization |
| POST | `/actions/{id}/confirm` | `{idempotency_key}` | 200; pending action reaches a confirmed/executed terminal state and creates one task |
| POST | `/actions/{id}/dismiss` | — or `{}` | 200; pending action is dismissed and creates no task |

The invitation acceptance route intentionally takes the token directly.  The
caller must not be required to expose or persist the invitation id after
creation.  The implementation may expose an additional explicit revoke path,
but the runner uses the frozen `POST /family-links/{id}/revoke` route so
revocation is easy to replay and verify.  If an API elects to use a different
method/path, it should be documented next to the server entry point before
acceptance is run.

## Behavioral assertions

1. A caregiver linked to an elder through `care_tasks` still cannot read the
   elder's private conversation or its messages, and the elder's conversation
   does not appear in the caregiver's conversation list.
2. An elder's task list contains a task only after the owner confirms its
   pending action.  The same confirmation key and a retry of the same action
   return the same task/action outcome rather than creating a duplicate. Two
   simultaneous confirmations of one action must also resolve to one task.
3. A caregiver may see a shared elder care task while the link is active.  A
   successful revoke takes effect on the next request: the caregiver can no
   longer see that task, while the elder retains it.
4. An invitation token is bound to its target caregiver. A different
   caregiver cannot accept it, and a token from a revoked pending invitation
   cannot be replayed.
5. Conversation history includes the user and assistant turns and remains
   available after the caller reconnects.  Responses must include a visible
   deterministic/demo mode when the server is not configured with a live model.
6. A message containing an emotional disclosure and an explicit reminder is
   handled as a reply plus a pending action preview.  Merely mentioning a
   clock time in a non-action memory statement must not create an action.
7. A retried message with the same `client_message_id` returns the original
   user/assistant result and does not append duplicate turns.
