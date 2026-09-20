# Foundation Acceptance Gate

Scope: the Foundation stage in IMPLEMENTATION_PLAN_EN.md. Later-stage personal-memory RAG, welfare RAG, voice, notifications, and crisis escalation are not claimed by this gate.

| Requirement | Required evidence |
|---|---|
| Three-part architecture | Flutter elder and caregiver experiences connected to a running API; server-owned state. |
| Accounts | Register, login, persisted authenticated session, invalid credentials rejected. |
| Authorization | Linked caregivers cannot access elder conversations; task sharing restricted by explicit relationship and immediately revoked. |
| Text conversations | Send and reload messages; visible errors and clearly identified demo mode when no live model is configured. |
| Short-term context | Previous turns influence subsequent replies; context survives backend restart; rolling context stays bounded. |
| Task confirmation | Chat can propose a task; no task exists before confirmation; owner-only confirm/dismiss; retries cannot duplicate a task. |
| Flutter quality | Static analysis and meaningful widget tests pass; Android artifact builds. |
| Reproducibility | Setup commands, configuration example, test runner, and limitations documented. |

Foundation acceptance passed within the tested development scope. The final
[verification record](VERIFICATION.md) distinguishes automated checks, live HTTP
checks, build evidence, and physical-device checks that could not be performed.
