#!/usr/bin/env python3
"""Black-box Foundation acceptance checks for the Anxin HTTP API.

The script talks only to a running server.  Start that server with a fresh
database (``DATABASE_URL``) before invoking this file; the runner creates
unique accounts and never deletes records from a shared database.  It prints
statuses and assertion names, while keeping private message bodies and bearer
tokens out of the report.

Examples::

    # PowerShell, from the repository root:
    $env:DATABASE_URL = "sqlite:///./acceptance-run.db"
    $env:DEMO_MODE = "1"
    .venv\\Scripts\\python.exe -m uvicorn app.main:app --app-dir backend --port 8000

    # In another terminal:
    .venv\\Scripts\\python.exe acceptance\\foundation_api_acceptance.py

The server process should be stopped and the temporary database removed by
the caller after the run.  A run against a shared environment is still safe
with respect to existing records because all created email addresses are
unique, but that environment will contain the run's test data.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import sys
import time
import uuid
from dataclasses import dataclass
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_TIMEOUT_SECONDS = 15.0
ACCEPTED_SUCCESS = (200, 201, 202, 204)
FORBIDDEN_OR_NOT_FOUND = (401, 403, 404)


@dataclass(frozen=True)
class HTTPResult:
    status: int
    body: Any
    raw: str = ""
    error: str | None = None


class APIClient:
    """Small JSON-only client with no third-party dependency."""

    def __init__(self, base_url: str, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.token: str | None = None

    def request(self, method: str, path: str, payload: Any | None = None) -> HTTPResult:
        url = self.base_url + "/" + path.lstrip("/")
        headers = {"Accept": "application/json"}
        if payload is not None:
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = Request(url, data=data, headers=headers, method=method.upper())
        try:
            with urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode("utf-8", errors="replace")
                return HTTPResult(response.status, _json_or_text(raw), raw)
        except HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            return HTTPResult(exc.code, _json_or_text(raw), raw, error=f"HTTP {exc.code}")
        except (URLError, TimeoutError, OSError) as exc:
            return HTTPResult(0, None, error=f"transport error: {exc}")

    def get(self, path: str) -> HTTPResult:
        return self.request("GET", path)

    def post(self, path: str, payload: Any | None = None) -> HTTPResult:
        return self.request("POST", path, payload)

    def delete(self, path: str) -> HTTPResult:
        return self.request("DELETE", path)


def _json_or_text(raw: str) -> Any:
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def _mapping(value: Any) -> dict[str, Any] | None:
    return value if isinstance(value, dict) else None


def _unwrap(value: Any) -> dict[str, Any]:
    """Accept the API's direct object or a conventional ``data`` wrapper."""

    current = _mapping(value) or {}
    for key in ("data", "result"):
        nested = _mapping(current.get(key))
        if nested is not None:
            return nested
    return current


def _items(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    current = _mapping(value) or {}
    for key in ("items", "data", "results", "tasks", "conversations", "links"):
        candidate = current.get(key)
        if isinstance(candidate, list):
            return [item for item in candidate if isinstance(item, dict)]
    return []


def _token(value: Any) -> str | None:
    current = _unwrap(value)
    candidate = current.get("access_token") or current.get("token")
    return candidate if isinstance(candidate, str) and candidate else None


def _account(value: Any) -> dict[str, Any]:
    current = _unwrap(value)
    nested = _mapping(current.get("account")) or _mapping(current.get("user"))
    return nested or current


def _id(value: Any, *keys: str) -> str | None:
    current = _unwrap(value)
    for key in keys:
        candidate = current.get(key)
        if isinstance(candidate, str) and candidate:
            return candidate
    return None


def _status(value: Any) -> str | None:
    current = _unwrap(value)
    candidate = current.get("status")
    return candidate if isinstance(candidate, str) else None


class AcceptanceRun:
    def __init__(self, client: APIClient, verbose: bool = False) -> None:
        self.client = client
        self.verbose = verbose
        self.passed = 0
        self.failed = 0
        self.results: list[dict[str, Any]] = []

    def check(self, name: str, condition: bool, detail: str = "") -> None:
        result = {"name": name, "passed": condition}
        if detail:
            result["detail"] = detail
        self.results.append(result)
        if condition:
            self.passed += 1
            print(f"PASS {name}")
        else:
            self.failed += 1
            suffix = f": {detail}" if detail else ""
            print(f"FAIL {name}{suffix}")

    def status(self, name: str, response: HTTPResult, expected: Iterable[int]) -> bool:
        allowed = tuple(expected)
        ok = response.status in allowed
        detail = f"HTTP {response.status}; expected one of {allowed}"
        if response.error and response.status == 0:
            detail = response.error
        self.check(name, ok, detail if not ok else "")
        return ok

    def require_status(self, name: str, response: HTTPResult, expected: Iterable[int]) -> None:
        if not self.status(name, response, expected):
            raise RuntimeError(name)

    def require_value(self, name: str, value: Any, detail: str = "") -> Any:
        self.check(name, value is not None and value != "", detail)
        if value is None or value == "":
            raise RuntimeError(name)
        return value

    def run(self) -> int:
        try:
            self._run()
        except RuntimeError:
            # The failed assertion already explains the first dependent error.
            pass
        except Exception as exc:  # pragma: no cover - defensive runner guard
            self.check("runner completed without an unexpected exception", False, str(exc))
        print(f"\nAcceptance result: {self.passed} passed, {self.failed} failed")
        if self.verbose:
            print(json.dumps(self.results, ensure_ascii=False, indent=2))
        return 1 if self.failed else 0

    def _run(self) -> None:
        health = self.client.get("/health")
        self.require_status("server health endpoint", health, (200,))

        run_id = f"{int(time.time())}-{uuid.uuid4().hex[:10]}"
        elder_email = f"elder-{run_id}@example.invalid"
        caregiver_email = f"caregiver-{run_id}@example.invalid"
        password = "Foundation-acceptance-2026!"

        elder = self._register(
            "elder registration", elder_email, "Acceptance Elder", "elder", password
        )
        caregiver = self._register(
            "caregiver registration", caregiver_email, "Acceptance Caregiver", "caregiver", password
        )
        wrong_caregiver = self._register(
            "wrong caregiver registration",
            f"wrong-caregiver-{run_id}@example.invalid",
            "Wrong Acceptance Caregiver",
            "caregiver",
            password,
        )
        elder_client = APIClient(self.client.base_url, self.client.timeout)
        caregiver_client = APIClient(self.client.base_url, self.client.timeout)
        wrong_caregiver_client = APIClient(self.client.base_url, self.client.timeout)
        elder_client.token = elder["token"]
        caregiver_client.token = caregiver["token"]
        wrong_caregiver_client.token = wrong_caregiver["token"]

        bad_login = caregiver_client.request(
            "POST", "/auth/login", {"email": caregiver_email, "password": "wrong-password"}
        )
        self.status("invalid credentials rejected", bad_login, (401, 403))
        valid_login = self.client.post(
            "/auth/login", {"email": elder_email, "password": password}
        )
        self.require_status("valid credentials create a session", valid_login, (200,))
        self.check(
            "valid login identifies elder",
            _account(valid_login.body).get("email") == elder_email,
        )

        me = elder_client.get("/auth/me")
        self.require_status("authenticated session resolves elder", me, (200,))
        me_account = _account(me.body)
        self.check(
            "authenticated identity is the registered elder",
            me_account.get("email") == elder_email and me_account.get("role") == "elder",
        )

        invalid_token = APIClient(self.client.base_url, self.client.timeout)
        invalid_token.token = "invalid.acceptance.token"
        invalid_me = invalid_token.get("/auth/me")
        self.status("invalid bearer token rejected", invalid_me, (401,))

        conversation = elder_client.post("/conversations", {"title": "Foundation acceptance private chat"})
        self.require_status("elder creates private conversation", conversation, ACCEPTED_SUCCESS)
        conversation_id = self.require_value(
            "conversation id returned", _id(conversation.body, "id", "conversation_id")
        )

        combined = elder_client.post(
            f"/conversations/{conversation_id}/messages",
            {
                "content": (
                    "I feel lonely today and would like some support. "
                    "Please remind me tomorrow at 09:00 to call my doctor."
                )
            },
        )
        self.require_status("elder sends combined emotion and task message", combined, ACCEPTED_SUCCESS)
        combined_body = _unwrap(combined.body)
        assistant = _mapping(combined_body.get("assistant_message"))
        user_message = _mapping(combined_body.get("user_message"))
        self.check(
            "combined message returns a user turn and assistant reply",
            user_message is not None
            and assistant is not None
            and bool(assistant.get("content")),
        )
        assistant_text = str((assistant or {}).get("content") or "").casefold()
        self.check(
            "combined reply acknowledges the emotional disclosure",
            any(
                phrase in assistant_text
                for phrase in (
                    "lonely",
                    "sad",
                    "worried",
                    "support",
                    "難受",
                    "孤單",
                    "擔心",
                    "陪你",
                )
            ),
        )
        mode = combined_body.get("mode")
        self.check(
            "response identifies deterministic/demo or live model mode",
            mode in {"deterministic_demo", "openai_compatible", "error"},
            f"mode={mode!r}",
        )
        action = _mapping(combined_body.get("action"))
        self.check(
            "combined message creates a pending action preview",
            action is not None and _status(action) == "pending",
        )
        action_id = _id(action or {}, "id", "action_id")
        self.require_value("pending action id returned", action_id)
        action_owner = _id(action or {}, "owner_id")
        elder_id = _id(_account(elder["body"]), "id")
        self.check("action belongs to the elder", action_owner == elder_id)

        tasks_before = elder_client.get("/tasks")
        self.require_status("elder task list available before confirmation", tasks_before, ACCEPTED_SUCCESS)
        task_items_before = _items(tasks_before.body)
        self.check(
            "pending action has not created a task before confirmation",
            not any(_id(item, "source_action_id") == action_id for item in task_items_before),
        )

        # A clock time in a memory statement is not an action request.
        memory_conversation = elder_client.post("/conversations", {"title": "No action memory"})
        self.require_status("elder creates no-action memory conversation", memory_conversation, ACCEPTED_SUCCESS)
        memory_id = self.require_value(
            "no-action conversation id returned", _id(memory_conversation.body, "id", "conversation_id")
        )
        memory_message = elder_client.post(
            f"/conversations/{memory_id}/messages",
            {"content": "I remember my old appointment was at 09:00 last year; no action is needed."},
        )
        self.require_status("elder sends memory statement", memory_message, ACCEPTED_SUCCESS)
        self.check(
            "memory statement with a clock time creates no action",
            _unwrap(memory_message.body).get("action") is None,
        )
        reminiscence = elder_client.post(
            f"/conversations/{memory_id}/messages",
            {"content": "My story says I should call the clinic tomorrow; I am only remembering it."},
        )
        self.require_status("elder sends reminiscence statement", reminiscence, ACCEPTED_SUCCESS)
        self.check(
            "reminiscence statement does not create an action",
            _unwrap(reminiscence.body).get("action") is None,
        )
        remembered_future = elder_client.post(
            f"/conversations/{memory_id}/messages",
            {"content": "I remember to call my doctor tomorrow; this is a memory, not a request."},
        )
        self.require_status("elder sends remembered-future statement", remembered_future, ACCEPTED_SUCCESS)
        self.check(
            "remembered-future statement does not create an action",
            _unwrap(remembered_future.body).get("action") is None,
        )

        retry_conversation = elder_client.post("/conversations", {"title": "Message retry"})
        self.require_status("elder creates message-retry conversation", retry_conversation, ACCEPTED_SUCCESS)
        retry_conversation_id = self.require_value(
            "message-retry conversation id returned",
            _id(retry_conversation.body, "id", "conversation_id"),
        )
        retry_message_id = f"message-{run_id}"
        retry_payload = {
            "content": "This is a harmless message whose network response may be retried.",
            "client_message_id": retry_message_id,
        }
        first_send = elder_client.post(
            f"/conversations/{retry_conversation_id}/messages", retry_payload
        )
        self.require_status("first client-id message send succeeds", first_send, ACCEPTED_SUCCESS)
        second_send = elder_client.post(
            f"/conversations/{retry_conversation_id}/messages", retry_payload
        )
        self.require_status("retry client-id message send succeeds", second_send, ACCEPTED_SUCCESS)
        first_send_body = _unwrap(first_send.body)
        second_send_body = _unwrap(second_send.body)
        first_user_id = _id(_mapping(first_send_body.get("user_message")) or {}, "id", "message_id")
        second_user_id = _id(_mapping(second_send_body.get("user_message")) or {}, "id", "message_id")
        first_assistant_id = _id(
            _mapping(first_send_body.get("assistant_message")) or {}, "id", "message_id"
        )
        second_assistant_id = _id(
            _mapping(second_send_body.get("assistant_message")) or {}, "id", "message_id"
        )
        self.check("message retry returns the same user turn", first_user_id == second_user_id)
        self.check("message retry returns the same assistant turn", first_assistant_id == second_assistant_id)
        retry_history = elder_client.get(f"/conversations/{retry_conversation_id}/messages")
        self.require_status("message-retry history reloads", retry_history, ACCEPTED_SUCCESS)
        self.check("message retry does not append duplicate turns", len(_items(retry_history.body)) == 2)

        # Invitation is accepted before confirmation so private-chat isolation
        # is checked for an explicitly linked caregiver.
        invitation = elder_client.post(
            "/family-links/invitations", {"email": caregiver_email, "scopes": ["care_tasks"]}
        )
        self.require_status("elder creates caregiver invitation", invitation, ACCEPTED_SUCCESS)
        invitation_body = _unwrap(invitation.body)
        invitation_id = self.require_value("invitation id returned", _id(invitation_body, "id", "invitation_id"))
        invite_token = self.require_value(
            "invitation returns one-time acceptance token", _token(invitation_body)
        )
        self.check("invitation is pending", _status(invitation_body) == "pending")
        self.check("invitation shares only care tasks", invitation_body.get("scopes") == ["care_tasks"])

        wrong_accept = wrong_caregiver_client.post(
            "/family-links/invitations/accept", {"token": invite_token}
        )
        self.status(
            "wrong caregiver cannot accept invitation token",
            wrong_accept,
            (400, 401, 403, 404, 410),
        )

        revoked_invitation = elder_client.post(
            "/family-links/invitations", {"email": caregiver_email, "scopes": ["care_tasks"]}
        )
        self.require_status("elder creates invitation for revoke replay check", revoked_invitation, ACCEPTED_SUCCESS)
        revoked_invitation_body = _unwrap(revoked_invitation.body)
        revoked_invitation_id = self.require_value(
            "revocable invitation id returned",
            _id(revoked_invitation_body, "id", "invitation_id"),
        )
        revoked_invitation_token = self.require_value(
            "revocable invitation token returned", _token(revoked_invitation_body)
        )
        revoke_invitation = elder_client.post(
            f"/family-links/invitations/{revoked_invitation_id}/revoke"
        )
        self.require_status("elder revokes pending invitation", revoke_invitation, ACCEPTED_SUCCESS)
        self.check("invitation revoke reports revoked status", _status(revoke_invitation.body) == "revoked")
        replay_revoked = caregiver_client.post(
            "/family-links/invitations/accept", {"token": revoked_invitation_token}
        )
        self.status(
            "revoked invitation token cannot be replayed",
            replay_revoked,
            (400, 401, 403, 404, 410),
        )

        # The frozen Foundation contract accepts the raw token without making
        # clients persist an invitation id.  This is intentionally a direct
        # assertion: silently falling back to an older id-addressed route
        # would hide a client/server contract mismatch.
        accepted = caregiver_client.post("/family-links/invitations/accept", {"token": invite_token})
        self.require_status("caregiver accepts invitation", accepted, ACCEPTED_SUCCESS)
        link_id = self.require_value("active family link id returned", _id(accepted.body, "id", "link_id"))
        self.check("accepted invitation creates active link", _status(accepted.body) in {"active", "accepted"})
        self.check("active family link shares only care tasks", _unwrap(accepted.body).get("scopes") == ["care_tasks"])

        linked_conversation_list = caregiver_client.get("/conversations")
        self.require_status("linked caregiver conversation list available", linked_conversation_list, ACCEPTED_SUCCESS)
        self.check(
            "linked caregiver conversation list excludes elder conversation",
            not any(
                _id(item, "id", "conversation_id") == conversation_id
                for item in _items(linked_conversation_list.body)
            ),
        )
        linked_private_read = caregiver_client.get(f"/conversations/{conversation_id}")
        self.status(
            "linked caregiver cannot read elder private conversation",
            linked_private_read,
            FORBIDDEN_OR_NOT_FOUND,
        )
        if linked_private_read.status == 200:
            self.check(
                "private conversation response contains no elder message text",
                not _contains_private_content(linked_private_read.body),
            )

        caregiver_confirm = caregiver_client.post(
            f"/actions/{action_id}/confirm", {"idempotency_key": f"caregiver-{run_id}"}
        )
        self.status("caregiver cannot confirm elder action", caregiver_confirm, FORBIDDEN_OR_NOT_FOUND)

        confirm_key = f"foundation-{run_id}"

        def confirm_concurrently(_: int) -> HTTPResult:
            concurrent_client = APIClient(self.client.base_url, self.client.timeout)
            concurrent_client.token = elder_client.token
            return concurrent_client.post(
                f"/actions/{action_id}/confirm", {"idempotency_key": confirm_key}
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            concurrent_confirmations = list(executor.map(confirm_concurrently, (1, 2)))
        concurrent_statuses = [result.status for result in concurrent_confirmations]
        self.check(
            "concurrent confirmations both complete successfully",
            all(status_code in ACCEPTED_SUCCESS for status_code in concurrent_statuses),
            f"HTTP statuses={concurrent_statuses}",
        )
        concurrent_task_ids = [
            _id(_mapping(_unwrap(result.body).get("task")) or _unwrap(result.body), "id", "task_id")
            for result in concurrent_confirmations
        ]
        task_id = self.require_value("concurrent confirmation returns task id", concurrent_task_ids[0])
        self.check(
            "concurrent confirmation responses identify one task",
            all(candidate == task_id for candidate in concurrent_task_ids),
        )

        confirmed = concurrent_confirmations[0]
        confirmed_body = _unwrap(confirmed.body)
        confirmed_action = _mapping(confirmed_body.get("action")) or confirmed_body
        self.check(
            "action reaches confirmed terminal state",
            _status(confirmed_action) in {"confirmed", "executed"},
            f"status={_status(confirmed_action)!r}",
        )

        retry = elder_client.post(
            f"/actions/{action_id}/confirm", {"idempotency_key": confirm_key}
        )
        self.require_status("repeating confirmation is idempotent", retry, ACCEPTED_SUCCESS)
        retry_body = _unwrap(retry.body)
        retry_task = _mapping(retry_body.get("task"))
        retry_task_id = _id(retry_task or retry_body, "id", "task_id")
        self.check("confirmation retry returns the same task", retry_task_id == task_id)

        elder_tasks = elder_client.get("/tasks")
        self.require_status("elder task list available after confirmation", elder_tasks, ACCEPTED_SUCCESS)
        elder_task_items = _items(elder_tasks.body)
        matching_elder_tasks = [item for item in elder_task_items if _id(item, "id", "task_id") == task_id]
        self.check("elder sees confirmed care task", len(matching_elder_tasks) == 1)
        self.check(
            "task is linked to exactly one source action",
            sum(_id(item, "source_action_id") == action_id for item in elder_task_items) == 1,
        )

        caregiver_tasks = caregiver_client.get("/tasks")
        self.require_status("linked caregiver task list available", caregiver_tasks, ACCEPTED_SUCCESS)
        caregiver_task_items = _items(caregiver_tasks.body)
        self.check(
            "linked caregiver can see explicitly shared care task",
            any(_id(item, "id", "task_id") == task_id for item in caregiver_task_items),
        )

        elder_conversation_after_reconnect = APIClient(self.client.base_url, self.client.timeout)
        elder_conversation_after_reconnect.token = elder_client.token
        reloaded = elder_conversation_after_reconnect.get(f"/conversations/{conversation_id}")
        self.require_status("conversation reload succeeds for owner", reloaded, ACCEPTED_SUCCESS)
        self.check(
            "conversation reload includes persisted user turn",
            _contains_private_content(reloaded.body),
        )

        revoked = elder_client.post(f"/family-links/{link_id}/revoke")
        self.require_status("elder revokes active family link", revoked, ACCEPTED_SUCCESS)
        revoked_body = _unwrap(revoked.body)
        self.check("revoked link reports revoked status", _status(revoked_body) in {"revoked", "inactive"})

        caregiver_tasks_after_revoke = caregiver_client.get("/tasks")
        # The resource may be represented as an empty 200 list or denied.  What
        # matters is that the old elder task is no longer disclosed.
        self.status(
            "caregiver task access is re-evaluated after revocation",
            caregiver_tasks_after_revoke,
            ACCEPTED_SUCCESS + FORBIDDEN_OR_NOT_FOUND,
        )
        if caregiver_tasks_after_revoke.status in ACCEPTED_SUCCESS:
            self.check(
                "revoked caregiver no longer sees elder care task",
                not any(
                    _id(item, "id", "task_id") == task_id
                    for item in _items(caregiver_tasks_after_revoke.body)
                ),
            )

        elder_tasks_after_revoke = elder_client.get("/tasks")
        self.require_status("elder retains task after sharing revoke", elder_tasks_after_revoke, ACCEPTED_SUCCESS)
        self.check(
            "elder still sees own task after revoke",
            any(_id(item, "id", "task_id") == task_id for item in _items(elder_tasks_after_revoke.body)),
        )

    def _register(
        self, label: str, email: str, display_name: str, role: str, password: str
    ) -> dict[str, Any]:
        response = self.client.post(
            "/auth/register",
            {"email": email, "password": password, "display_name": display_name, "role": role},
        )
        self.require_status(label, response, (200, 201))
        token = self.require_value(f"{label} returns access token", _token(response.body))
        account = _account(response.body)
        self.check(f"{label} returns requested role", account.get("role") == role)
        self.check(f"{label} returns requested email", account.get("email") == email)
        return {"token": token, "body": response.body}


def _contains_private_content(value: Any) -> bool:
    """Return true only for the known acceptance marker, never print it."""

    if isinstance(value, str):
        return "I feel lonely today" in value or "call my doctor" in value
    if isinstance(value, dict):
        return any(_contains_private_content(item) for item in value.values())
    if isinstance(value, list):
        return any(_contains_private_content(item) for item in value)
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:8000",
        help="running API base URL (default: %(default)s)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="per-request timeout in seconds (default: %(default)s)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="also print the machine-readable assertion summary; no tokens or private bodies are included",
    )
    args = parser.parse_args(argv)
    return AcceptanceRun(APIClient(args.base_url, args.timeout), args.verbose).run()


if __name__ == "__main__":
    sys.exit(main())
