# Anxin Companion user guide

This guide covers the current text-based app and its Traditional Chinese and English interface. Button names below use the English interface. Choose your language in Settings before following the steps.

## 1. Open the app and choose a language

For the local web preview, open http://127.0.0.1:8088/ while the preview server and backend are running. This address refers to the current computer; it is not a public link for teammates.

Open **Settings** from the sign-in screen or while signed in. Under **Interface language**, choose **繁體中文** or **English**. The interface updates immediately. Your choice is saved on this device or browser and remains after signing out or restarting the app. It does not synchronize to your other devices; clearing the app's local storage can remove it.

The language setting changes navigation, buttons, prompts, and other app interface text. It does not translate existing conversations, memories, stories, family messages, or official resource records. Server-generated text may remain in its original language. Choosing English does not set the language of AI replies or change your account, family permissions, or saved content.

## 2. Register and sign in

Select the registration option, enter your display name, email, and password, then choose the older-adult or caregiver role. If you already have an account, use the sign-in option. There is no shared default account or password. Open the account menu to check your signed-in identity or sign out.

Use separate accounts for the older adult and caregiver. Two browser sessions or devices are useful when trying the family features.

A **Demo mode** label means conversations use predefined demonstration replies rather than a live AI model. You can still try memory management, official resource search, family authorization, and messages, but the conversation is not representative of a live model.

## 3. Start a conversation as an older adult

1. On the home screen, open the chat section.
2. Start a new conversation, type a message, and send it. You can also reopen an existing conversation.
3. If the app proposes a care task, review its details before confirming it. It becomes a task only after confirmation.

The current version supports text input. Cantonese voice input, voice calls, and scheduled morning greetings are not yet available. If sending fails, check your connection and retry rather than repeatedly creating the same task.

## 4. Save and manage memories

Explicitly ask the app to remember something, for example: **Remember that I like morning tea.** This creates a memory candidate. Return to the home screen and open the memories section to review it.

| Action | What it does |
| --- | --- |
| Confirm a candidate | Makes suitable content available for reference in later conversations |
| Edit | Corrects the content; the new version needs confirmation again |
| Pause use | Stops the app using this memory in answers; you can resume it later |
| Resume use | Makes this memory available for use again |
| Delete | Deletes the memory; there is no undo in the app |

Only suitable memories belonging to you that are confirmed and not paused are eligible for long-term recall. Emotional entries are not treated as factual memories. Use the search box to look for related confirmed memories. Without an embedding service, search uses keywords; unrelated questions may return no results.

Correcting, pausing, or deleting a memory withdraws related stories and tracked conversation references so the app does not keep using the old content. Resuming a memory does not automatically recreate withdrawn stories. The app cannot remove screenshots, exports, or copies saved elsewhere by a recipient.

## 5. Create a story card

Open the story-card section from the home screen and choose the create option. Enter a title and story, select the confirmed memories it refers to, then save it. You write the story yourself; the current app does not generate a biography automatically.

To share a story, choose an authorized family member, check the recipient and complete text, then confirm sending. If no eligible family member is available, complete the family connection below first.

Deleting a story also withdraws the associated content sent through its story-sharing feature. Copies saved outside the app are not covered by withdrawal.

## 6. Connect with family

**Older adult:**

1. Open the family section and enter the caregiver's registered email address.
2. Explicitly enable the family-message permission if you want to exchange messages. It is unchecked by default; permission to view care tasks does not automatically permit messaging.
3. Send the invitation and give its one-time invitation code to that caregiver.

**Caregiver:**

1. Sign in with the caregiver account registered to that email address.
2. Open the family section and refresh the invitation list if needed.
3. Enter the one-time code and accept the corresponding invitation.

If an existing connection does not include messaging, send and accept a new invitation with that permission enabled. Revoking a connection blocks subsequent access to the affected shared content and new message sends.

Caregivers cannot see the older adult's private conversations or complete memory library. They can access only the content covered by the older adult's authorization.

## 7. Send family messages and manage tasks

Open family messages from the home screen, select a family member, and type your message. Preview the recipient and full text, then confirm sending. Story sharing follows the same confirmation flow. Refresh the messages screen to see new arrivals; push notifications are not implemented yet.

The tasks screen lists confirmed care tasks. Confirming a task does not contact a hospital, book an appointment, or submit a welfare application. The current app does not carry out those external actions for you.

## 8. Find Hong Kong resources

Open the resources section and enter your need, or choose a suggested search for medical fee waivers, caregiver support, or day respite.

Each result shows its title, verification date, official source link, and numbered next steps. Expand the service and eligibility section for details, or the application questions section to see information that still needs checking.

Results are application guidance, not eligibility decisions. Open the official source and check its current requirements before applying. The collection contains six reviewed official records; it does not cover every subsidy or service in Hong Kong. If no result appears, try shorter keywords or contact the relevant organization directly.

The official resource content is currently stored in Traditional Chinese. Switching the app to English translates its controls, not these source records.

## 9. Troubleshooting

| Problem | What to check |
| --- | --- |
| The local web page does not open | Keep the preview service running on port 8088. Another device cannot use this computer's localhost address. |
| The page opens but sign-in or search fails | Check that the backend is running. The local preview build connects to port 8012. Read the displayed error and retry. |
| Some content remains Chinese after choosing English | The setting translates the app interface. User content, server text, and official records keep their original language. |
| Settings says the language could not be saved | The interface has changed for this session, but the preference may reset later. Select **Retry saving**. |
| My language choice differs on another device | Language is a local preference. Choose it separately in that device's Settings. |
| No recipient is available for family messages | Check that the invitation has been accepted and explicitly includes family-message permission. |
| A saved memory is not recalled | Check whether it is still a candidate, paused, an emotional entry, or unrelated to the question. Edited memories need confirmation again. |
| A family member cannot see a new message | Refresh the messages screen and check that the connection is still active. |
| The Android test app cannot connect | The emulator build uses `10.0.2.2:8000`. A physical phone needs a build pointing to a reachable backend address. See the README. |

The current version does not provide automatic crisis alerts, continuous health monitoring, or real appointment booking. A task or demo reply does not mean that a family member or service organization has been notified.

For setup and configuration, see the [README](../README.md). For the interim milestone's completed checks and limits, see [Interim verification](../INTERIM_VERIFICATION.md). For the language-setting change, see [UI language verification](LOCALIZATION_VERIFICATION_EN.md).
