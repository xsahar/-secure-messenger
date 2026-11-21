# Secure Messenger — Interface & Media Experience Upgrade

This is a **Flutter UI and media behavior patch**, based on the latest voice-permission/playback fix and the **Batch 5 Supabase bilateral-consent code**. It does NOT change the Firestore security rules, Supabase SQL, biometric gate, or experimental E2EE protocol.

## Files to replace in `C:\Projects\secure-messenger\lib`

Replace these existing files:

- `main.dart`
- `auth_screen.dart`
- `home_screen.dart`
- `contacts_screen.dart`
- `chat_screen.dart`
- `chat_media_content.dart`
- `profile_screen.dart`

Add one new file:

- `app_theme.dart`

Keep **all** other project files, including `biometric_gate.dart`, `secret_chat_screen.dart`, `secret_crypto.dart`, `secret_key_service.dart`, `supabase_config.dart`, `firebase_options.dart`, `SUPABASE_MEDIA_CONSENT_PATCH.sql`, and your Firestore rules. Do not replace or re-run those configurations.

## Behavior changes

- Photos auto-render and open full-screen for zoom.
- Voice messages automatically prepare when visible, with a compact Play/Pause control, a timer, and scrubbing.
- Video messages no longer have a separate **Load** button. Tap the video preview once to download/open the full-screen video player. Large video downloads are intentionally lazy to conserve the Supabase Free bandwidth allowance.
- Playback coordinator pauses a previously playing voice message/video before another one starts. Playback also stops when the app goes inactive/locks or you enter Secret Chat.
- Process-memory-only LRU cache, 24 MB budget, scoped to Firebase UID; files are still retrieved from private Supabase with the Firebase token. Cache cleared on authentication changes/sign-out, media deleted from cache when a message is deleted. A cache is not an E2EE guarantee.
- All media downloads wait for this client's Batch 5 consent registration attempt to finish; **both accepted contacts** must still open the standard chat once.
- Visual redesign of sign-in, conversations, chats, profile and navigation with a dark/navy/teal Material 3 theme, modern message bubbles, timestamps, seen indicators, and a compact composer.
- Secret Chat features remain implemented exactly as before; it adopts the global Material 3 theme. Existing disclosure that standard chat is not E2EE is preserved.
- No new dependencies or packages; no paid services or SQL changes.

## Before installing

1. Stop both Flutter sessions by pressing `q`.
2. Create a Git commit or backup of your **working** project.
3. Copy the seven replacement files plus the new `app_theme.dart` into the project's `lib` folder.
4. Run in a PowerShell terminal:

```powershell
cd C:\Projects\secure-messenger
flutter analyze
flutter test test/secret_crypto_test.dart
```

5. **Only if the checks pass**, run separately on Samsung and emulator, one device build at a time:

```powershell
flutter run -d R5CXC3056AT
```

Second terminal:

```powershell
flutter run -d emulator-5554
```

## Required two-device manual regression tests

- Sign in and biometric lock/unlock; cancel fingerprint on a pushed chat and confirm the screen stays hidden.
- Find, request and accept a contact; open an existing conversation.
- Send/receive text, edit/delete, read receipts, typing indicator.
- Send a voice from Samsung, hear it on emulator; and vice versa. Confirm it plays with ONE tap after opening chat.
- Start voice A then voice B: A must stop. Leave app/lock: currently playing voice/video must pause.
- Tap a video once: loading indicator then full-screen video; no separate Load button. Repeat to verify cache where possible.
- Photos should appear automatically; full-screen pinch-to-zoom still works.
- Open Secret Chat; existing X25519/AES-GCM text decrypts on both devices.
- Sign out; sign in to the other account, confirm biometric gate still works.

## Limitations / audit notes

- This archive was statically reviewed for basic structure, **not compiled or run with Flutter here**. If `flutter analyze` reports an error, stop and share the exact output before building.
- A visual makeover is not a completed security audit. Still test Firestore/Supabase unauthorized access, rate limits, lifecycle edge cases, and other graduation requirements.
- Standard chats and private Supabase media are **not end-to-end encrypted**. Only experimental Secret Chat text uses E2EE, without a Double Ratchet/forward secrecy.
- Supabase consent records still do **not** automatically mirror changes to Firestore accepted status; revocation is incomplete.
- Profile photo is explicitly still **local preview only**; no cloud persistence.
- No persistent on-device media-cache encryption; memory cache exists only during the running app. Temporary video/audio files are in the OS cache and deleted on player disposal on a best-effort basis.
