# Anxin Companion: Needs-First Brainstorm

**Working question:** How might we help older adults in Hong Kong feel connected, valued, and in control while helping families navigate care and healthcare costs together?

**Status:** Product exploration. The ideas in this document are hypotheses and possible directions, not a list of implemented features or claims about what every older adult needs. The [implementation plan](../IMPLEMENTATION_PLAN_EN.md) defines delivery scope; the [English user guide](USER_GUIDE_EN.md) describes the current app.

The central design rule is **needs first, technology second**. A conversation, a reminder, a family message, a social worker, or an official information source might each solve a different part of the same problem. AI should help select and coordinate the appropriate response.

## 1. Who are we designing for?

| Person or organization | What they may need | What we should learn before designing for them |
| --- | --- | --- |
| Older adult living alone | Connection, predictable contact, easy access to help, control over what family sees | Which relationships already matter? When is contact welcome? What feels intrusive? |
| Older adult living with family | Privacy, dignity, a say in care decisions, relief from feeling like a burden | Which decisions do they want to make independently? What conflict does technology currently create? |
| Older adult with low digital confidence | Large, understandable controls and recoverable mistakes | Can they complete a task without coaching? Do they prefer voice, text, or another person? |
| Family caregiver | Clarity about requests, shared responsibilities, time and cost planning | What information helps them act without turning the older adult into a dashboard? |
| Distant family member | Ways to maintain a real relationship across schedules and locations | What kind of update invites conversation rather than passive checking? |
| Social worker or community centre staff | A clear handoff, relevant context with consent, fewer repeated explanations | Which referrals can they actually accept? What information is useful and appropriate? |
| Healthcare provider | Prepared questions and accurate patient-reported information | Which parts of the appointment journey can a companion support without practicing medicine? |
| Public service provider | Clear pathways to current, authoritative service information | How frequently do eligibility rules, fees, forms, and contacts change? |

The older adult is the primary decision maker for their own stories, routine check-ins, and sharing permissions. A caregiver has legitimate needs, but those needs do not automatically grant access to private conversations or emotional interpretations.

## 2. What do older adults need, and when?

The same person may want different kinds of support at different moments. The agent should ask whether the person wants to **talk, find information, make a plan, contact someone, or be left alone for now**.

| Moment | Possible need | Product opportunity | What could go wrong? |
| --- | --- | --- | --- |
| “My children are already doing too much for me.” | To be heard without being dismissed; to retain dignity | Reflect the specific worry, ask what makes it feel heavy, then offer practical exploration only by invitation | Immediate reassurance or a subsidy checklist can feel like the agent did not listen |
| A quiet evening after a family visit | Companionship and continuity | Revisit a chosen story or ask about a meaningful person, place, or tradition | Repetitive questions and false familiarity feel artificial |
| An upcoming hospital visit | Confidence and preparation | Collect questions, transport needs, documents, and who will accompany them | The app may imply that an appointment is booked when it is not |
| An unfamiliar bill or letter | Understanding and agency | Explain plain-language terms, identify what remains unclear, prepare questions for the issuer | Incorrect extraction could cause financial harm |
| A change in an agreed routine | A respectful check-in | Ask the person directly before involving family, according to their preferences | An appliance or missed reply can have many harmless explanations |
| A birthday, festival, or remembered anniversary | Belonging | Invite the person to tell a story or send a message | Unwanted prompts can intensify grief or loneliness |
| “Nobody needs me anymore.” | Purpose and contribution | Help them teach a recipe, advise a grandchild, share a skill, or participate in a family decision | Treating their knowledge as mere content to archive misses the relationship |
| A disagreement about care | Control and a voice in the decision | Help each person state options and preferences before a family conversation | The agent must not appoint itself arbiter of family disputes |
| A request to stop | Quiet, privacy, and trust | Stop prompts promptly and make settings easy to change | Hidden or difficult-to-disable monitoring breaks trust |

### Needs beneath the visible problem

- **Connection:** being contacted because someone wants to hear from them, not only because something might be wrong.
- **Continuity:** being remembered accurately across conversations without repeating the same facts.
- **Purpose:** having a role as a parent, grandparent, neighbour, friend, or mentor.
- **Independence:** being able to understand options and decide what happens next.
- **Financial clarity:** knowing the size of an expense, available support paths, and what is still uncertain.
- **Trust:** knowing exactly what the agent stores, shares, infers, and does.
- **Access:** being able to use the service with limited vision, hearing, dexterity, literacy, or digital confidence.

## 3. How can the agent help?

### A. Emotional support: listen, remember, and reconnect

1. **Companionship with choice.** Begin with an open question; let the person choose a topic or skip the conversation. Avoid scripted cheerfulness.
2. **A “listen or plan?” turn.** When guilt or worry appears, ask whether the person wants a listening ear, information, or help contacting someone.
3. **Memory with consent.** Offer a candidate memory, show its wording, and let the older adult confirm, correct, pause, or delete it. Keep temporary feelings separate from lasting facts.
4. **Meaningful reminiscence.** Ask about festivals, work, favourite places, family traditions, music, or lessons learned. Let the person name stories they do not want revisited.
5. **Small relationship prompts.** Suggest a specific, low-pressure action: “Would you like to ask your daughter about her new job?” rather than “You should talk to your family more.”
6. **A sense of contribution.** Help create a recipe card, practical tip, oral history, or message answering a family member’s question.
7. **Human handoff.** When the person wants human company, facilitate contact with an agreed person or service. Show the exact message and recipient before sending.
8. **After-conversation reflection.** Offer an optional private summary: “What would you like to remember from today?” The user chooses whether it becomes long-term memory.

Questions to test: Does a familiar voice or familiar topic feel comforting or intrusive? Do people prefer the agent to ask about emotions directly? What kinds of replies make guilt worse?

### B. Physical wellbeing: notice, remind, and connect carefully

1. **Self-reported wellbeing check-ins.** Ask simple questions about energy, sleep, appetite, pain, or daily difficulties only when relevant and welcome.
2. **User-chosen routines.** Offer medication, water, movement, and appointment reminders that can be delayed, dismissed, or turned off.
3. **Appointment preparation.** Help list symptoms in the user’s own words, questions, medicines to bring, transport needs, and a chosen companion.
4. **Follow-up after a visit.** Ask what instructions the person received and whether they want help turning them into reminders. Preserve uncertainty if the instruction is unclear.
5. **Change detection as a prompt for inquiry.** Optional appliance or activity data might trigger a gentle check-in against an individual baseline. It must never be treated as proof of dehydration, depression, or neglect.
6. **Voice as an input method.** Cantonese speech can make the app easier to use. A transcript should be editable before saving or sharing.
7. **Optional audio observations.** Any future cough, breathing, or voice analysis needs separate consent, strong evidence, and clear limits. A raw audio stream should not be a default requirement for using the companion.
8. **Escalation preferences.** Let the older adult and caregiver agree in advance when an unanswered check-in should prompt a follow-up, who is contacted, and how they can pause the arrangement.

Questions to test: Which check-ins are useful without feeling like surveillance? What false alarm rate would families tolerate? Would the user rather contact a person directly than have AI interpret a signal?

### C. Practical support: turn uncertainty into manageable action

1. **Official information retrieval.** Search Hong Kong healthcare fee assistance, home care, respite, caregiver support, and community services. Show the source and verification date.
2. **A three-step pathway.** Start with a short checklist: what to check, what to prepare, and whom to contact. Place details behind an expandable explanation.
3. **Eligibility questions, not promises.** Identify missing age, residence, household, care-need, income, or assessment information. Explain that an authority makes the final decision.
4. **Document preparation.** Help make a checklist of required papers and questions, without sending a welfare application or private document automatically.
5. **Cost conversation support.** Help older adults and families discuss expected costs, what is known, what needs a quote, and what support they can ask about.
6. **Task coordination.** Ask who will call, accompany, collect documents, or follow up. Record accepted tasks and their status.
7. **Appointment coordination.** Assemble questions, reminders, travel time, and a request for accompaniment. Show a booking as confirmed only after an actual booking channel confirms it.
8. **Plain-language explanation.** Explain a confusing form or service page, preserve the official link, and let the user ask follow-up questions.
9. **Fallback to a person.** When sources conflict, information is missing, or a case is unusual, prepare a concise enquiry for a social worker or service provider.

Questions to test: Which practical problem creates the most anxiety today? Can users follow the first step unassisted? Do source links and dates increase confidence or overwhelm them?

### D. Social and family connection: create two-way participation

1. **Stories with an audience chosen by the older adult.** A private memory is not automatically a family story. Preview both the story and recipient before sharing.
2. **Two-way messages.** Family can reply with their own news, questions, and requests for advice. The relationship should not consist only of status reports.
3. **Specific invitations.** Suggest “Would you like to cook together on Sunday?” or “Could you tell me how you made this dish?”
4. **Care tasks with mutual agreement.** A family member can offer help; the older adult can accept, decline, or suggest another time.
5. **Community discovery.** Filter activities by district, interest, mobility, cost, language, and transport needs. Confirm that an event still exists before recommending travel.
6. **Shared traditions.** Turn festivals, recipes, photos, and oral histories into opportunities for ongoing conversation.
7. **Caregiver support.** Help a family member find respite, prepare for a difficult conversation, or ask another relative for a specific contribution.
8. **Consent-based updates.** Let the older adult decide whether family sees a story, a task, a check-in result, or nothing. Give them a preview of the family view.

Questions to test: Would the older adult prefer a report, a message they wrote, or a chance to ask the family a question? Which family updates prompt useful action without feeling invasive?

### E. Independence: make the agent a tool the person controls

1. Offer text and, later, voice without making either mandatory.
2. Use large controls, plain terms, visible progress, and one main decision per step.
3. Explain why an item was suggested and which source or memory was used.
4. Provide “not now,” “ask me later,” “that is wrong,” and “do not remember this” controls.
5. Keep a clear distinction between **drafted**, **approved**, **sent**, and **completed** actions.
6. Allow preferences to change; someone may welcome family help this month and want more privacy later.
7. Let the person see and change who has access to each kind of information.
8. Keep a useful core experience even when no sensor, wearable, or smart speaker is connected.

## 4. What does the family need?

| Family situation | Product idea | Boundary to preserve |
| --- | --- | --- |
| “I only have ten minutes today.” | A concise list of agreed requests and one suggested next action | Do not turn every conversation into a caregiver report |
| “We cannot afford everything.” | A shared cost and support-enquiry checklist with official sources | Do not infer or reveal the older adult’s finances without permission |
| “I do not know what my sibling is doing.” | An agreed task board with owners and due dates | Do not assign obligations automatically |
| “I am worried when I do not hear back.” | A jointly agreed check-in plan with a fallback contact | Silence alone is not evidence of an emergency |
| “We only talk about illness.” | Shared stories, questions, and plans for ordinary time together | Do not make connection dependent on producing content |
| “I need a break.” | Respite information and a way to ask for specific help | Avoid framing caregiver strain as a failure of care |

Caregiver value should be measured partly by whether they can take useful, agreed action, not by how much private information the system reveals.

## 5. What should AI not do?

### Safety

- Diagnose depression, dehydration, dementia, breathing problems, or any other illness from speech or appliance patterns.
- Present a risk score as a clinical assessment or wait for an AI score before offering ordinary human help.
- Claim that a family member, social worker, hospital, or emergency service has been contacted unless there is a recorded confirmation.
- Promise that a welfare application will be accepted, a service place is available, or an appointment is booked.
- Provide a confident answer when public sources are stale, contradictory, or silent.

### Privacy and agency

- Continuously listen or collect household activity by default.
- Share raw conversations, recordings, private memories, emotional labels, or financial details with family simply because they are caregivers.
- Convert a passing statement such as “I feel lonely tonight” into a permanent identity or diagnosis.
- Send a story or message without showing the exact recipient and content first.
- Make declining monitoring, reminders, or family sharing difficult.

### Relationships

- Present the agent as a replacement for family, friends, community workers, or clinical care.
- Interpret every older adult’s wish to be independent as refusal of help.
- Treat ordinary differences in routine as misconduct by the older adult or their family.
- Reward more engagement at the cost of real-world relationships.

## 6. How might the agent work across these needs?

Use a small set of understandable roles inside one coordinated service. These are **responsibilities**, not necessarily separate autonomous models.

| Responsibility | Input | Output | Requires approval? |
| --- | --- | --- | --- |
| Conversation guide | User message and recent context | A supportive response and a question about desired help | No, for an ordinary reply |
| Memory steward | User-approved memory candidate and provenance | A confirmed, correctable private memory | Yes, before long-term saving |
| Public-information researcher | A practical question and vetted source collection | Cited answer, gaps, and next steps | No to read; yes before external action |
| Family coordinator | A chosen task, story, or message | Recipient preview, permission check, send or task record | Yes, before sharing or creating a task |
| Routine assistant | Agreed schedule and reminder preferences | Reminder or check-in | Yes to configure; respect pause and quiet hours |
| Human-support router | User request or a pre-agreed escalation trigger | A prepared handoff to the chosen person or service | Follow the agreed contact rules and log the result |

The agent should recognize that one message can carry several needs. For example, “I do not want my daughter to miss work for my hospital visit” includes guilt, appointment logistics, and a family conversation. A useful response might listen first, ask what help is wanted, then offer a small practical step. It should not silently create a task or notify the daughter.

### Information boundaries

| Information | Why it exists | Access |
| --- | --- | --- |
| Current conversation | Understand the present request | The older adult and the conversation service |
| Confirmed personal memories | Provide continuity over time | The older adult; retrieval only for their own conversations |
| Care tasks | Coordinate agreed work | People given the relevant task permission |
| Shared stories and messages | Support relationships | The sender and explicitly authorized recipient |
| Official service knowledge | Support practical questions | Both roles; always show source and date |
| Optional sensor observations | Prompt a check-in if separately enabled | Narrow, time-limited access according to consent |

Personal memory retrieval and public-information retrieval remain separate. The former answers “What has this person chosen to let the agent remember?” The latter answers “What do vetted external sources say?” A public source cannot establish a person’s eligibility, and a private memory should never become a public knowledge record.

## 7. End-to-end experience concepts

### Journey A: guilt about care costs

1. An older adult says, “My children are spending too much on my treatment.”
2. The agent acknowledges the concern and asks whether they want to talk about it or explore costs and support.
3. If they choose practical help, the agent retrieves relevant official guidance with source dates and identifies missing eligibility details.
4. Together they prepare three questions for a medical social worker.
5. The older adult chooses whether to share a brief message or request a specific task from family.
6. A family member replies; the agent tracks only the agreed next step.

### Journey B: loneliness without a crisis

1. The person wants company after dinner.
2. The agent offers conversation topics or a remembered story, without insisting on a family call.
3. The person recalls a festival meal and chooses whether to save it as a memory.
4. Later, they can turn it into a story and invite a relative to add their own version.

### Journey C: an upcoming hospital visit

1. The person mentions a check-up date.
2. The agent offers a reminder and a question list; it confirms the date before saving either.
3. It asks whether anyone should accompany them and previews an optional request.
4. After the visit, it helps record instructions in the person’s words and flags anything unclear for the provider.

### Journey D: a broken routine

1. A user who opted into routine check-ins does not respond at the usual time.
2. The system follows the user’s chosen retry window and contact preferences.
3. It asks a neutral question rather than naming a suspected condition.
4. If the agreed escalation threshold is reached, it contacts only the designated person and reports the observable fact, such as “No response to two scheduled check-ins.”

### Journey E: a family caregiver under pressure

1. A caregiver asks where to find respite and how to explain the need without upsetting their parent.
2. The agent shows vetted support routes and helps draft a respectful conversation opener.
3. The caregiver checks the source and speaks with the older adult.
4. Any task or information shared between accounts requires the appropriate permission.

## 8. Questions to validate before expanding the product

1. **Desirability:** Which interaction makes an older adult want to return for its own value, rather than because family asks them to use it?
2. **Dignity:** Does “Are you okay?” feel caring, annoying, or alarming after a missed check-in?
3. **Consent:** Can users accurately predict what appears in the family view after sharing a story, task, or update?
4. **Memory quality:** Which memories feel useful to recall, and which feel too intimate or inaccurate?
5. **Language:** Is Cantonese voice needed for access, or is text adequate for the first group we can test? How should transcripts be reviewed?
6. **Practical value:** Can a person use a retrieved resource to make a real enquiry? Which missing details most often stop them?
7. **Family value:** Does a suggested message lead to a better conversation than a mood report?
8. **Safety:** How often would a passive signal cause a false alarm? What level of contact is acceptable to the older adult?
9. **Staff fit:** Would a social worker find a consented summary helpful, and what details should be omitted?
10. **Accessibility:** Can a first-time user complete one meaningful journey with enlarged text and without developer assistance?

For interviews, ask about recent real situations and decisions rather than asking people whether they like hypothetical AI features. Test the screens and wording with older adults, caregivers, and community workers separately; their preferences may conflict.

## 9. Candidate measures of success

| Outcome | Possible observation | Guardrail |
| --- | --- | --- |
| Feeling heard | Users say the agent understood their concern and let them choose a direction | Do not optimize for conversation length alone |
| Connection | A chosen story or message leads to a reply or shared activity | Count reciprocal contact, not automated reports |
| Practical progress | A user completes an agreed first step or prepares a useful question | Do not count a drafted checklist as an approved application |
| Independence | Users complete tasks or change settings without help | Check accessibility across language and device sizes |
| Trust | Users can explain who sees their data and can correct or withdraw it | Track permission errors and unwanted sharing |
| Caregiver relief | Families report clearer next actions and less repeated coordination | Confirm that relief does not come from excessive monitoring |
| Safety quality | Agreed check-ins follow the configured rules | Review false alarms, missed contacts, and user complaints |

The strongest prototype story connects the branches: **listen to a real worry, find trustworthy options, let the older adult choose, and help a human relationship carry the next step.**
