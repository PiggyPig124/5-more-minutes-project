"""LangGraph conversation orchestration with a safety-first fallback path."""

from __future__ import annotations

from typing import Any, TypedDict

from .llm import (
    AgentReply,
    detect_urgent_risk,
    make_adapter,
    safety_intervention_reply,
    sanitize_proposal,
)

try:  # LangGraph is a production dependency, but import failure should not break demo startup.
    from langgraph.graph import END, START, StateGraph
except ImportError:  # pragma: no cover - exercised only in minimal installations
    END = START = StateGraph = None


class ConversationState(TypedDict, total=False):
    context: dict[str, Any]
    user_message: str
    reply: AgentReply
    urgent_risk: bool


class ConversationOrchestrator:
    """Run the persisted-context conversation graph.

    The graph now has two nodes:

    1. ``safety_check`` — runs before the model and inspects the user message
       for direct, non-negated risk statements.  When a risk is detected, the
       node returns a warm safety intervention and skips the model entirely,
       so no provider latency or hallucination can suppress the intervention.

    2. ``respond`` — the model adapter call with its task-proposal sanitization.

    The safety node is the first extension point documented in the foundation
    milestone; memory retrieval, tools, and proactive scheduling can be added
    as additional nodes in later milestones.
    """

    def __init__(self, settings):
        self.adapter = make_adapter(settings)
        self._graph = None
        if StateGraph is not None:
            # A configured LangGraph dependency is part of the production
            # foundation. If its graph cannot compile, fail startup rather
            # than silently changing orchestration semantics.
            graph = StateGraph(ConversationState)
            graph.add_node("safety_check", self._safety_check)
            graph.add_node("respond", self._respond)
            graph.add_edge(START, "safety_check")
            graph.add_conditional_edges(
                "safety_check",
                lambda state: "safety_intervention" if state.get("urgent_risk") else "respond",
                {"safety_intervention": END, "respond": "respond"},
            )
            graph.add_edge("respond", END)
            self._graph = graph.compile()

    async def _safety_check(self, state: ConversationState) -> dict[str, Any]:
        """Inspect the user message for urgent risk before the model runs.

        Returns ``{"urgent_risk": True, "reply": ...}`` when a risk is detected,
        which the conditional edge routes directly to END.  Otherwise returns
        ``{"urgent_risk": False}`` and the graph proceeds to ``respond``.
        """

        message = state.get("user_message", "")
        if detect_urgent_risk(message):
            return {"urgent_risk": True, "reply": safety_intervention_reply()}
        return {"urgent_risk": False}

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
        # Fallback when LangGraph is not installed: run nodes manually.
        safety = await self._safety_check(state)
        if safety.get("urgent_risk"):
            return safety["reply"]
        return (await self._respond(state))["reply"]
