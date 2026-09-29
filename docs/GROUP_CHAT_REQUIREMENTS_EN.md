# Human Group Chat: Requirement and Release Record

**Date:** 28 September 2026

**Requested by:** Product owner

**Status:** Prototype implemented; release review open

## Required behavior

Registered people can create private groups, invite other registered people by email, accept or decline invitations, view current members, and exchange text messages. The group owner can invite members and close the group. Members can leave, block future invitations from a person, and record a report. Group messages are between people: the AI assistant does not join, read, or answer them.

## Privacy and external-action review

| Decision | Prototype behavior | Release review |
| --- | --- | --- |
| Default visibility | A group is private. Invitees cannot read messages until they accept, and cannot read messages from before their latest join. Nonmembers cannot read group details or messages. | Verify in real-user privacy testing. |
| Private Echo data | Private AI chats and confirmed memories have separate storage and are never copied to group messages automatically. | Review any future sharing proposal as a separate change. |
| Invitation | The owner enters an existing account's email. The invitation appears inside that person's account; no email, SMS, push, or third-party message is sent. | Agree policy before adding any external delivery channel. |
| Member controls | Members can leave; owners can close; either can report; a person can block future invitations from another account. | Decide if blocking should also affect existing shared groups. |
| Reports | The system records the reporter, group, optional message, and reason. | Assign reviewers, review access, response times, escalation, and abuse handling before public release. |
| Retention | Group messages, invitations, and reports are stored in the application database; no automatic deletion is implemented. | Set retention periods and deletion/export rules before public release. |

This record documents the privacy defaults and in-app invitation behavior for the SRS Section 18 change review. It records implementation choices, **not approval for a public or moderated service**. The team still needs to identify a reviewer and record the release decision. Community web scraping and real-person matching are outside this change.
