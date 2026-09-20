"""LangGraph conversation orchestration with a safe fallback path."""

from __future__ import annotations

from typing import Any, TypedDict

from .llm import AgentReply, make_adapter, sanitize_proposal

try:  # LangGraph is a production dependency, but import failure should not break demo startup.
    from langgraph.graph import END, START, StateGraph
except ImportError:  # pragma: no cover - exercised only in minimal installations
    END = START = StateGraph = None


class ConversationState(TypedDict, total=False):
    context: dict[str, Any]
    user_message: str
    reply: AgentReply


class ConversationOrchestrator:
    """Run the persisted-context conversation graph.

    The current graph has one model node, leaving explicit extension points for
    safety checks, memory retrieval, and tools in later milestones.  The task
    proposal is always gated a second time after that node.
    """

    def __init__(self, settings):
        self.adapter = make_adapter(settings)
        self._graph = None
        if StateGraph is not None:
            # A configured LangGraph dependency is part of the production
            # foundation. If its graph cannot compile, fail startup rather
            # than silently changing orchestration semantics.
            graph = StateGraph(ConversationState)
            graph.add_node("respond", self._respond)
            graph.add_edge(START, "respond")
            graph.add_edge("respond", END)
            self._graph = graph.compile()

    async def _respond(self, state: ConversationState) -> dict[str, Any]:
        reply = await self.adapter.reply(state.get("context", {}), state["user_message"])
        # Providers may be misconfigured or return an unsafe structured value;
        # enforce the explicit-intent policy at the orchestration boundary.
        reply.proposed_task = sanitize_proposal(state["user_message"], reply.proposed_task)
        return {"reply": reply}

    async def run(self, context: dict[str, Any], user_message: str) -> AgentReply:
        state: ConversationState = {"context": context, "user_message": user_message}
        if self._graph is not None:
            result = await self._graph.ainvoke(state)
            return result["reply"]
        return (await self._respond(state))["reply"]
