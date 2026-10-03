"""Process-local WebSocket notifications for the single-worker group-chat demo.

Every API worker must share a notification broker before this hub can support
multiple workers; reconnecting clients reload persisted history after outages.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from threading import Lock


@dataclass(eq=False)
class Subscriber:
    group_id: str
    account_id: str
    loop: asyncio.AbstractEventLoop
    queue: asyncio.Queue[str]


class GroupRealtimeHub:
    def __init__(self) -> None:
        self._lock = Lock()
        self._subscribers: dict[str, set[Subscriber]] = {}

    def subscribe(self, group_id: str, account_id: str) -> Subscriber:
        subscriber = Subscriber(group_id, account_id, asyncio.get_running_loop(),
                                asyncio.Queue(maxsize=1))
        with self._lock:
            self._subscribers.setdefault(group_id, set()).add(subscriber)
        return subscriber

    def unsubscribe(self, subscriber: Subscriber) -> None:
        with self._lock:
            group = self._subscribers.get(subscriber.group_id)
            if group is not None:
                group.discard(subscriber)
                if not group:
                    self._subscribers.pop(subscriber.group_id, None)

    @staticmethod
    def _offer(subscriber: Subscriber, event: str) -> None:
        if subscriber.queue.full():
            pending = subscriber.queue.get_nowait()
            if pending == "access_revoked":
                subscriber.queue.put_nowait(pending)
                return
        subscriber.queue.put_nowait(event)

    def _notify(self, group_id: str, event: str, account_id: str | None = None) -> None:
        with self._lock:
            subscribers = tuple(self._subscribers.get(group_id, ()))
        for subscriber in subscribers:
            if account_id is not None and subscriber.account_id != account_id:
                continue
            try:
                subscriber.loop.call_soon_threadsafe(self._offer, subscriber, event)
            except RuntimeError:
                # Its event loop has already closed; reconnecting clients reload history.
                self.unsubscribe(subscriber)

    def messages_changed(self, group_id: str) -> None:
        self._notify(group_id, "messages_changed")

    def member_left(self, group_id: str, account_id: str) -> None:
        self._notify(group_id, "access_revoked", account_id)

    def group_closed(self, group_id: str) -> None:
        self._notify(group_id, "access_revoked")
