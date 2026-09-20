# Anxin Companion — Interim Report

## Problem and proposed contribution

Older adults may experience loneliness, guilt about relying on family, and
anxiety about the cost of care. Anxin Companion combines private conversation,
user-controlled memory, practical resource information, and explicit family
communication. The current prototype supports text in a Traditional Chinese
interface. It is intended to support human relationships and informed enquiries.

## Prototype journey

1. An older adult signs in and talks privately. Care tasks are proposed for
   confirmation rather than executed from a passing reference to a date.
2. The older adult reviews a candidate memory and confirms whether it should
   be used in later conversations. Temporary feelings are not permanent facts.
3. A later conversation retrieves relevant confirmed memories with visible
   evidence. Memories can be corrected, suppressed, or deleted.
4. The older adult can create a private story and preview it before sharing
   with a specifically authorized family member. The family member can reply.
5. A welfare enquiry retrieves verified official material, surfaces conditions
   that still need checking, and provides three next steps and source links.

## Implementation

The Flutter application contains separate older-adult and caregiver experiences.
FastAPI enforces access permissions and persists the shared state. LangGraph
runs the response step using current conversation context and retrieved evidence.
Personal memories and public resource documents use separate data collections.

The retrieval design combines keyword matching with configurable model-generated
embeddings. When no embedding service is configured, the application identifies
keyword retrieval explicitly. A demonstration conversation adapter is similarly
labelled when no live conversational model is configured. These modes make the
prototype testable without claiming that deterministic replies demonstrate
natural conversational quality or semantic retrieval quality.

Memory confirmation and family-message authorization are separate choices.
Care-task sharing does not implicitly authorize access to private conversation,
personal memory, or messages. Sending a story requires a recipient/content preview.

## Evaluation and evidence

The foundation was evaluated using backend regressions, 85 live API assertions,
29 restart assertions, Flutter tests, real Dart/API integration, browser checks,
and Android compilation. The interim milestone extends testing to memory
correction, suppression and deletion, retrieval evidence, source attribution,
and family communication after authorization revocation.

The final interim verification record accompanies this report. No participant
study has been performed, and no improvement in loneliness, wellbeing, or care
costs is claimed. Demonstrations use fictional people and local test data.

## Next evaluation steps

With consent, test whether older adults can review remembered information,
correct it, understand sharing permissions, and distinguish a suggested resource
from confirmed eligibility. Record task completion, retrieval errors, mistaken
sharing attempts, perceived control, and caregiver comprehension. Evaluate live
model responses for unsupported claims and preservation of empathy when a
conversation also contains a practical request.

## Remaining work

Cantonese speech input, a broader community directory, proactive follow-up and
safety-assistance workflows belong to the next milestone. Real-device testing,
deployment hardening, live-provider evaluation, presentation materials, and a
demonstration video remain before submission. No autonomous welfare application,
hospital booking, acoustic diagnosis, or emergency dispatch is claimed.
