# Current Memory policy and SRS applicability

## Confirmed product decision

The user chose ordinary preference auto-save: “自动保存偏好吧 每次点保存对于用户不太友好吧”. This confirms the product choice; it does not constitute whole-team approval or external review. MEM-CR-2026-09-29-01 records the exception and still has no evidence of completed team review.

Memory is off by default. An older adult who turns it on permits automatic saving of clear, ordinary, non-sensitive first-person preferences without a Save for each item. The owner can view provenance, edit, pause or delete memories. Turning Memory off stops collection, retrieval and personalization while preserving saved records for management. Sensitive, uncertain and non-preference suggestions require explicit item-level Save. Guest/caregiver accounts do not auto-save. Automatic saving does not authorize sharing, registration, external searches or contact; Family sharing retains recipient/full-content preview and separate confirmation.

With no configured model, deterministic demo mode does not infer or auto-save preferences. Current tests supply synthetic structured model decisions and cannot establish real-provider semantic quality. The model classifies meaning; the server checks exact current-turn evidence, owner, kind, sensitivity, bounded sensitive-content veto, revision and topic block. This is not complete language understanding or a guarantee against every model misclassification.

## Applying the original SRS

Source: `reference documents/Echo_Software_Requirements_Specification_v1.1_Corrected (1).md` (Markdown sections, no fixed pages).

| Original requirement | Current application |
|---|---|
| FR MEM 01; FR MEM 04–05 | Default off, owner controls and separate off/delete remain required. |
| FR MEM 02; AT 03 | Documented exception only for eligible ordinary preferences after opt-in. Other/sensitive/uncertain manual suggestions still require item-level Save. The original all-items wording is historical baseline, not the current product rule for ordinary preferences. |
| AT 04 | Auto-saved memories carry agent_auto provenance; status=confirmed means active storage, not individual user confirmation. UI and model must not describe them as personally confirmed. The owner can correct/pause/delete them. |
| FR MEM 06; FR FAM 02–03; AT 05 | A Memory Card is a separate private artifact; creating/saving it and sharing it remain explicit owner actions. No automatic family access. |
| FR CMT 02–04; AT 06 | Directory A accepts only complete standard skill labels backed by matching active owner-confirmed sources and independent skill confirmation. Free preference prose, including auto-saved prose, provides no positive personalized catalog reason. Unparsed confirmed evidence may force general suggestions. Existing community.py skill suggestion/external opportunity logic is outside the A guarantee. |
| §18 | User product decision confirmed; whole-team review still unverified. No signatures or compliance approval are invented. |

## Draft boundary and exact remaining gaps

1. The current chat manual Save editor and private Memory Card composer keep edited draft fields in RAM and make no memory/card write before Save; Cancel writes nothing. This does not promise that the already-stored authenticated chat message/suggestion metadata is absent from chat history.
2. Legacy `POST /memories` still creates a persistent `candidate` before later `/confirm`. Such a candidate is excluded from retrieval and positive directory evidence, but does not satisfy a claim of zero Memory persistence before confirmation. This route has not been removed or redesigned in this alignment task.
3. Owner `PATCH /memories/{id}` content edits explicitly saved with Save changes produce a superseding candidate requiring confirmation; model `correct_preference` can activate a replacement only for an existing agent_auto preference. These paths are different and not a universally unified candidate workflow. Model corrections require supported owner-scoped current records and current-turn evidence.
4. In-flight model replies are rejected after off/delete revision changes, including when no memories were originally retrieved. A later action for the same stored topic_key is blocked after pause/delete/correction. New withdrawal records also store a versioned owner/body fingerprint that preserves punctuation and word boundaries while normalizing case and whitespace runs (C++ is distinct from C, A B from AB). The same normalized body cannot be recaptured merely by changing the model topic key. Explicit owner Save/confirm/restore clears only its corresponding v2 body fence and topic fence. Legacy v1 body fingerprints stripped punctuation and are ambiguous: they remain checked and are never automatically cleared by matching new text. A legacy C++ fingerprint may therefore conservatively block C auto-capture, even after explicit owner management succeeds. Deleted original bodies cannot be reconstructed from those hashes; fixing this over-blocking would require a separately reviewed migration/recovery policy. No such migration or silent unblock was run; old topic-only records also are not backfilled. Topic keys are model-authored: simultaneous semantic paraphrase plus a different invented key is not a proven universal anti-relearning boundary. No new NLP claim is made; provider evaluation remains required.
5. Real provider quality/privacy, multilingual classification and independent team review remain outstanding. Ordinary auto-save does not mean all SRS requirements are complete.

## Verification scope

`backend/tests/test_auto_preference_policy.py`: synthetic opt-in/role guard, no story/family write, non-preference and sensitive veto, actual off/delete APIs during delayed model execution, same-key and same-body/different-key pause/delete recapture blocks, owner isolation and explicit owner Save after deletion. `test_preference_content_fence.py` covers C++/C independent capture, unrelated Save/restore retaining withdrawal barriers, punctuation/word boundaries and conservative legacy compatibility. Existing agent memory, version/race and private-card suites remain relevant.

`app/test/auto_preference_policy_copy_test.dart`: English/Traditional Chinese explanation, manageable auto-save receipt without a second Save, sensitive manual Cancel with no writes. Widget evidence is not real-model or physical-device evidence.
