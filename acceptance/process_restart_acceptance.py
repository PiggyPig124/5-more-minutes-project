#!/usr/bin/env python3
"""Verify Foundation state across a real API process restart.

This check owns its short-lived server and SQLite database.  It starts the API
with a generated signing secret, creates one account/conversation/pending
action, stops the process, starts a second process against the same database
and secret, then verifies old authentication, persisted context, and pending
action state.  No credentials or database paths are printed.
"""

from __future__ import annotations

import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from foundation_api_acceptance import (  # noqa: E402
    ACCEPTED_SUCCESS,
    APIClient,
    _account,
    _id,
    _mapping,
    _status,
    _token,
    _unwrap,
)


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _contains(value: object, marker: str) -> bool:
    if isinstance(value, str):
        return marker in value
    if isinstance(value, dict):
        return any(_contains(item, marker) for item in value.values())
    if isinstance(value, list):
        return any(_contains(item, marker) for item in value)
    return False


def _start_server(db_path: Path, secret: str, port: int) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env.update(
        {
            "DATABASE_URL": "sqlite:///" + db_path.as_posix(),
            "AUTH_SECRET": secret,
            "DEMO_MODE": "1",
            "APP_ENV": "development",
            "PYTHONUNBUFFERED": "1",
        }
    )
    return subprocess.Popen(
        [
            str(ROOT / ".venv" / "Scripts" / "python.exe"),
            "-m",
            "uvicorn",
            "app.main:app",
            "--app-dir",
            "backend",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
        ],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def _stop_server(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    # Windows may release SQLite handles just after process exit.  Closing the
    # captured stream and allowing one scheduler turn avoids a false cleanup
    # failure that would otherwise obscure the acceptance result.
    if process.stdout is not None:
        process.stdout.close()
    time.sleep(0.25)


def _wait_for_health(base_url: str, process: subprocess.Popen[str]) -> bool:
    client = APIClient(base_url, timeout=1.0)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        if client.get("/health").status == 200:
            return True
        time.sleep(0.15)
    return False


def main() -> int:
    checks: list[tuple[str, bool]] = []

    def check(name: str, passed: bool) -> None:
        checks.append((name, passed))
        print(f"PASS {name}" if passed else f"FAIL {name}")

    run_id = f"{int(time.time())}-{uuid.uuid4().hex[:10]}"
    email = f"restart-{run_id}@example.invalid"
    password = "Foundation-restart-2026!"
    marker = f"Evergreen Lantern {run_id}"
    secret = secrets.token_urlsafe(32)
    port = _free_port()
    base_url = f"http://127.0.0.1:{port}"

    with tempfile.TemporaryDirectory(prefix="anxin-restart-") as temp_dir:
        db_path = Path(temp_dir) / "state.db"
        first = _start_server(db_path, secret, port)
        try:
            check("first API process becomes healthy", _wait_for_health(base_url, first))
            if not checks[-1][1]:
                return 1

            api = APIClient(base_url)
            registered = api.post(
                "/auth/register",
                {
                    "email": email,
                    "password": password,
                    "display_name": "Restart Acceptance Elder",
                    "role": "elder",
                },
            )
            check("restart fixture account registers", registered.status in (200, 201))
            token = _token(registered.body)
            check("restart fixture receives token", bool(token))
            if not token:
                return 1
            api.token = token

            conversation = api.post("/conversations", {"title": "Restart context"})
            check("restart fixture conversation creates", conversation.status in ACCEPTED_SUCCESS)
            conversation_id = _id(conversation.body, "id", "conversation_id")
            check("restart fixture conversation id exists", bool(conversation_id))
            if not conversation_id:
                return 1

            # 14 persisted turns make the first marker part of rolling_summary
            # while leaving recent_context bounded to the latest 12 messages.
            for index in range(6):
                result = api.post(
                    f"/conversations/{conversation_id}/messages",
                    {"content": f"This is bounded context turn {index + 1}; no action is needed."},
                )
                check(f"context turn {index + 1} is accepted", result.status in ACCEPTED_SUCCESS)
            first_message = api.post(
                f"/conversations/{conversation_id}/messages",
                {"content": f"Please remember this private context marker: {marker}."},
            )
            check("context marker message is accepted", first_message.status in ACCEPTED_SUCCESS)

            action_conversation = api.post(
                "/conversations", {"title": "Restart pending action"}
            )
            check("pending-action conversation creates", action_conversation.status in ACCEPTED_SUCCESS)
            action_conversation_id = _id(action_conversation.body, "id", "conversation_id")
            check("pending-action conversation id exists", bool(action_conversation_id))
            if not action_conversation_id:
                return 1
            pending = api.post(
                f"/conversations/{action_conversation_id}/messages",
                {"content": "Please remind me tomorrow to call the clinic."},
            )
            check("pending action is accepted before restart", pending.status in ACCEPTED_SUCCESS)
            pending_action = _mapping(_unwrap(pending.body).get("action"))
            action_id = _id(pending_action or {}, "id", "action_id")
            check("pending action id survives fixture creation", bool(action_id))

            old_token = api.token
            before = api.get(f"/conversations/{conversation_id}")
            before_body = _unwrap(before.body)
            check("pre-restart conversation has rolling context", bool(before_body.get("rolling_summary")))
            check("pre-restart context contains marker", _contains(before.body, marker))

            _stop_server(first)
            second = _start_server(db_path, secret, port)
            try:
                check("second API process becomes healthy", _wait_for_health(base_url, second))
                restarted = APIClient(base_url)
                restarted.token = old_token
                old_token_me = restarted.get("/auth/me")
                check("old token remains valid after restart", old_token_me.status == 200)

                relogin = restarted.post("/auth/login", {"email": email, "password": password})
                check("re-login succeeds after restart", relogin.status == 200)
                restarted.token = _token(relogin.body) or old_token

                after = restarted.get(f"/conversations/{conversation_id}")
                after_body = _unwrap(after.body)
                check("conversation reloads after restart", after.status == 200)
                check("rolling context reloads after restart", bool(after_body.get("rolling_summary")))
                check("persisted marker is present after restart", _contains(after.body, marker))
                recent_context = after_body.get("recent_context")
                check(
                    "recent context remains bounded",
                    isinstance(recent_context, list) and len(recent_context) <= 12,
                )

                recalled = restarted.post(
                    f"/conversations/{conversation_id}/messages",
                    {"content": "What did I tell you earlier?"},
                )
                check("context recall request succeeds after restart", recalled.status in ACCEPTED_SUCCESS)
                recalled_body = _unwrap(recalled.body)
                assistant = _mapping(recalled_body.get("assistant_message")) or {}
                check("demo reply references persisted context", _contains(assistant.get("content"), marker))

                actions = restarted.get(f"/conversations/{action_conversation_id}/actions")
                check("pending action list reloads after restart", actions.status == 200)
                action_items = actions.body if isinstance(actions.body, list) else []
                matching = [item for item in action_items if _id(item, "id", "action_id") == action_id]
                check(
                    "pending proposal remains pending after restart",
                    len(matching) == 1 and _status(matching[0]) == "pending",
                )
            finally:
                _stop_server(second)
        finally:
            _stop_server(first)

    failed = sum(not passed for _, passed in checks)
    print(f"\nRestart acceptance result: {len(checks) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
