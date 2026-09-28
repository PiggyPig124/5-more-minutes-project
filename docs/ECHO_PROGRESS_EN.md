# Echo Progress Report

**Status as of 28 September 2026**

**Baseline:** Git commit `673342d` (20 September 2026). This report separates the previous prototype, separately developed changes, and work that remains open. It is a progress record, not a claim that the revised MVP is complete.

## Product direction

Echo is an AI-assisted companion and community product for older adults in Hong Kong. Its intended journey is conversation, user-confirmed memory, more relevant support, and stronger family and community connections. Older adults control what is remembered and shared. Echo does not replace family members, social workers, medical professionals, official services, or emergency support.

The revised requirements keep five main destinations: Home, Family, Community, Help, and Settings. Guests should be able to ask general questions before creating an account. Persistent memory, family connections, and personalized community features require the relevant account and separate consent.

## What existed at the Git baseline

The 20 September commit already had older-adult and caregiver accounts, private text conversations, basic confirmed memories, family invitations and revocation, selective private-story sharing, family messages, shared tasks, a small reviewed collection of official information sources, and Traditional Chinese and English interfaces. The default conversation adapter was a clearly labelled deterministic demonstration; live model quality had not been established.

## What has been added since that commit

| Area | Current working-tree change | Practical result |
| --- | --- | --- |
| Guest entry | Session-only guest conversations and public Help search | A visitor can ask a question without registration; the guest transcript does not become account history or long-term memory. Sessions expire after 30 minutes of inactivity and can be ended explicitly. |
| Memory consent | An explicit opt-in, disabled by default for new and existing older-adult accounts | Turning memory off stops new collection, recall, and skill discovery while leaving saved memories available to their owner for review and deletion. |
| Save flow | A transient suggestion in a new chat reply and an explicit Save endpoint | A new chat suggestion is not added to the Memory Library until the older adult selects Save. Legacy candidate and correction flows still need to be made consistent with this rule. |
| Community skills | Private skill suggestions derived from active, confirmed memories, with confirm, edit, and reject actions | An unconfirmed skill is not shared or used for opportunity matching. The extraction currently uses a limited phrase map rather than a validated model. |
| Client navigation | The revised five-destination older-adult interface, guest entry, memory setting, and Community screens | The new privacy and community flows can be reached from the Flutter client. |
| Public community search | A bounded implementation that read two selected public pages and displayed source, event date, cache, and outage states | Technical retrieval was demonstrated, but the source-rights review below blocks treating this as an approved production feed. |
| Documentation and checks | Updated API checks, regression tests, acceptance scripts, and Chinese requirements/feasibility notes | The new behavior and its limits have reproducible evidence. |

The latest recorded verification, run on 27 September, reported **41 passing backend tests**, **37 passing Flutter tests** with **two optional live-client tests skipped**, a clean Flutter analysis, and a successful ordinary web build. A separate privacy-and-permissions acceptance script passed **34 checks**. A nine-check live community-search trial succeeded at the time, but a successful HTTP fetch is not permission to reuse the source content. These results do not cover production deployment, real users, a physical device, a live conversational model, or a completed registration with an organization.

## Source-rights finding and current scope decision

The current code still contains an HTML scraper for the JC Volunteer Together Platform. Its [Terms of Service](https://www.jcvtplatform.hk/en/terms-conditions) restrict searching the platform through means other than provider-supported interfaces, explicitly giving scraping as an example, and restrict reuse of its content without written authorization. The second activity page is publicly readable, but permission for automated reuse has not been confirmed. **The scraper should be disabled before any external demonstration or deployment, and neither source should be presented as an authorized feed until its use is cleared.** Users can still be directed to an organization's official page. The source-rights review has been documented; disabling the running code has not yet been done.

The team has decided to defer Cantonese speech-input testing and further community feed work for now. This does not prevent progress on the text-based, consent-controlled core experience.

## Newly requested group chat

The first human-only group-chat prototype is implemented on the `codex/group-chat` branch. A signed-in person can create a private group, invite an already registered member by email, and exchange text messages after that person accepts. The chat interface lists groups and incoming invitations, shows members, refreshes messages, and supports declining invitations, leaving, closing a group, blocking future invitations from an account, and recording a report. Groups have at most 20 active members; invitations expire after seven days. A new or returning member cannot read messages sent before their latest join. Nonmembers cannot read group details, members, or messages. Private Echo conversations and confirmed memories are not copied into a group; no AI route is called for group messages.

This is an **account-based prototype**, not a verified matching service or public community feed. Invitations require the other person's registered email; no external invitation is sent. Reports are stored, but there is no staffed review queue, escalation process, or response-time commitment yet. The group feature must not be presented as a publicly moderated community service until moderation ownership, retention, abuse response, and privacy review are agreed. The group branch was built from the previously pushed progress-document commit, so it does not include the separate uncommitted guest, memory, or web-scraping work described earlier in this report.

## Next work without speech or community feeds

1. **Finish memory control.** Make the legacy candidate and correction paths obey the same confirm-before-save rule; add Delete All and verify withdrawal from recall, skills, sharing, and derived content. Complete the difference between turning memory off and deleting it.
2. **Create a private Memory Card.** Build a card only from confirmed memory, show exactly what will be shared and with whom, require event-specific approval, and test revocation of access.
3. **Deliver a portable sourced Answer Card.** Preserve the plain-language answer, official term, source, retrieval date, verification state, and next step when saving, printing, or sharing a single card. Complete the transport, healthcare-navigation, scam-guidance, and human-help routes without claiming to perform the official service itself.
4. **Complete family controls.** Add reject and block actions for connections, and a confirmed plan or accompaniment request with a caregiver reply. Do not expose private chat or the full memory library.
5. **Evaluate text quality and accessibility.** Keep typing fully usable, test patient responses and Hong Kong wording with a configured text model when credentials are available, and perform real-device usability checks. A configured API is not evidence of model quality.
6. **Prepare group chat for release.** Define who reviews recorded reports, escalation and retention rules, and an abuse-response process. Run accessibility and real-user checks before describing it as a moderated community feature.

Public memory maps, open help requests, proactive daily greetings, push delivery, direct social-worker messaging, and real-person matching remain outside this immediate work. They require additional consent, moderation, partner arrangements, or operational review. The [feasibility plan](ECHO_DEFERRED_FEATURES_FEASIBILITY_ZH.md) records their proposed gates.

## Git status at the time of writing

The guest, memory, and community-search changes described above are in a separate working tree and have not been included in the group-chat branch. Original reference documents supplied for review are also outside this branch. The group implementation and this report are the only new scope prepared for this push.
