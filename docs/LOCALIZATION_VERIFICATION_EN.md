# UI language settings verification

Target version: 0.2.1+3. Scope: Traditional Chinese and English interface text, accessible language settings before and after sign-in, and a device-local language preference.

## Expected behavior

- Settings are available on the sign-in screen and in the authenticated app.
- Choosing Traditional Chinese or English updates interface labels and controls.
- The selected language remains after signing out and reopening the app.
- Language is stored locally; it is not an account preference synchronized across devices.
- Existing conversations, memories, stories, family messages, and official resource records retain their original content.
- Language changes do not modify family permissions or send messages.
- The [English user guide](USER_GUIDE_EN.md) explains these boundaries and existing product limitations.

## Completed verification

Reviewed on September 20, 2026 by the coordinating agent after implementation.

- Flutter analysis: no issues.
- Full client suite: 31 passed, 2 optional live-API tests skipped.
- The new coverage includes 7 locale persistence/race/failure tests and 3 UI flow tests.
- The UI flow checks cover English login input preservation, the Settings language control, open-route and session preservation, and 390 × 844 layouts at 1.3 text scale. Home, chat, tasks, family, memories, stories, resources, family messages and settings were exercised. The existing caregiver regression passed; a separate real caregiver browser journey was not run.
- The expanded phone-navigation flow was rerun after adding its assertions: 3 passed.
- Actual browser review: switched Traditional Chinese to English through the signed-in account menu, checked the Settings page and English home at 390-pixel width, refreshed and confirmed English persisted with the existing session, then switched back to Traditional Chinese. The temporary viewport override was reset.
- Preference survival after sign-out and reopening was verified using local-store tests. The real user's browser session was not signed out.
- Web JavaScript build and Android debug APK build succeeded. The Wasm compatibility scan reports existing secure-storage dependencies unsupported by Wasm; this is a JavaScript web build.
- Git whitespace checks passed. No backend code or API contract changed, so backend acceptance was not repeated.

## Deliverables

- App version: `0.2.1+3`.
- Android debug APK: `dist/anxin-companion-settings.apk` (156,031,873 bytes), using the emulator API at `http://10.0.2.2:8000`.
- APK SHA-256: `6a867289556fbc4cf1dd51e44143b659cb769e0f8cc6ca693958e102752b1283`.
- Web preview: http://127.0.0.1:8088/ (local backend: port 8012).
- Earlier APK artifacts are retained. Build outputs remain excluded from Git.
- English user guide: [USER_GUIDE_EN.md](USER_GUIDE_EN.md).

## Limits

This is interface localization, not automatic translation of user or server content. Browser verification and a successful APK build do not establish acceptance on a physical Android device. Live-model multilingual response quality requires separate evaluation.
