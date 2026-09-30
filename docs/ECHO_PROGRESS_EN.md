# Echo Progress Report

**Update as of 30 September 2026.** Model-maintained Memory is implemented locally behind an explicit opt-in and configured text-model requirement. The model proposes structured save, suggest, correct, and forget actions; the server validates current-message evidence, ownership, current memory versions, and a bounded sensitive-content veto before writing. Demo mode never auto-saves. Memory retrieval still uses labelled keyword matching unless an embedding provider is configured; live model and embedding quality have not been tested. The default application no longer fetches either unapproved Community source. Backend tests: **48 passed**; the synthetic phase-one HTTP/restart acceptance: **34 checks passed**. Flutter tests and analysis were not rerun in this environment after these changes. Human-only realtime group chat is tracked separately in [PR #1](https://github.com/PiggyPig124/5-more-minutes-project/pull/1).

The following sections retain the **28 September historical snapshot** and its earlier verification figures. They should not be read as the current implementation status where they differ from the update above. Original reference documents supplied for review remain outside this report's intended publication scope.

**Historical baseline:** Git commit `673342d` (20 September 2026). This report separates the previous prototype, changes in the then-current working tree, and work that remained open.

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

The code contains HTML adapters for the JC Volunteer Together Platform and a second activity page, but neither is enabled in the default application. The [JC Volunteer Together Platform Terms of Service](https://www.jcvtplatform.hk/en/terms-conditions) restrict scraping and reuse without written authorization; permission for automated reuse of the second page is also unconfirmed. **Do not enable either adapter for an external demonstration or deployment until its use is cleared.** Users can still open an organization's official page. Synthetic adapter tests remain available without contacting those sites.

The team has decided to defer Cantonese speech-input testing and further community feed work for now. This does not prevent progress on the text-based, consent-controlled core experience.

## Newly requested group chat

The product owner has requested group conversations in the chat interface, with the ability to invite community members. The first version is **person-to-person group chat without AI participation**. This is a new requirement, not an implemented feature. It needs a separate SRS change record and privacy design before release: membership by invitation and acceptance, visible participants, leaving and blocking, report and moderation handling, and clear control over what each participant sees. Existing private Echo conversations and confirmed memories must not be copied into a group automatically. Until these controls are specified and tested, the current family messages and private chat should not be described as community group chat.

## Next work without speech or community feeds

1. **Finish memory control.** Make the legacy candidate and correction paths obey the same confirm-before-save rule; add Delete All and verify withdrawal from recall, skills, sharing, and derived content. Complete the difference between turning memory off and deleting it.
2. **Create a private Memory Card.** Build a card only from confirmed memory, show exactly what will be shared and with whom, require event-specific approval, and test revocation of access.
3. **Deliver a portable sourced Answer Card.** Preserve the plain-language answer, official term, source, retrieval date, verification state, and next step when saving, printing, or sharing a single card. Complete the transport, healthcare-navigation, scam-guidance, and human-help routes without claiming to perform the official service itself.
4. **Complete family controls.** Add reject and block actions for connections, and a confirmed plan or accompaniment request with a caregiver reply. Do not expose private chat or the full memory library.
5. **Evaluate text quality and accessibility.** Keep typing fully usable, test patient responses and Hong Kong wording with a configured text model when credentials are available, and perform real-device usability checks. A configured API is not evidence of model quality.
6. **Specify and build invitation-based group chat without AI.** Start with account membership, invitation acceptance, participant visibility, leave/block/report actions, and a moderation process; keep private chats and memories isolated.

Public memory maps, open help requests, proactive daily greetings, push delivery, direct social-worker messaging, and real-person matching remain outside this immediate work. They require additional consent, moderation, partner arrangements, or operational review. The [feasibility plan](ECHO_DEFERRED_FEATURES_FEASIBILITY_ZH.md) records their proposed gates.

## Git status at the time of writing

The changes above are present in the working tree but have not yet been committed. The original reference documents supplied for review are also untracked. This report does not imply that those original files should be published with the project.
