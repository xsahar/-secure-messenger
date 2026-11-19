# Secure Messenger — Batch 1: contacts and standard text chat

This package is **additive** to your existing Flutter + Firebase project. It is not a replacement for `main.dart`, `auth_screen.dart`, `profile_screen.dart`, or `firebase_options.dart`.

## Files to copy

Copy the Dart files into `C:\Projects\secure-messenger\lib\`:

- `connection_service.dart` — one deterministic connection per pair of accounts; contact request and acceptance operations
- `contacts_screen.dart` — search by username, requests, and contacts
- `chat_screen.dart` — live text messages, owner-only edit/delete controls
- `home_screen.dart` — profile/contacts navigation
- `scan_qr_screen.dart` — replace your existing scanner with a version that has Send Request

## Integrate main.dart

Find the signed-in `Scaffold` in your `StreamBuilder` in `lib/main.dart` (the one already containing the existing logout button).

Add near the top:

```dart
import 'home_screen.dart';
```

Inside that **existing signed-in Scaffold**, replace only the old profile body:

```dart
body: const ProfileScreen(),
```

with:

```dart
body: const HomeScreen(),
```

Keep your existing authentication stream, AppBar, and logout button untouched. `HomeScreen` has two tabs. If Dart warns that `import 'profile_screen.dart';` in `main.dart` is unused, remove that unused import; the new `home_screen.dart` imports it.

## Firestore rules — required before testing

Firebase Console → Cloud Firestore → Rules. Replace the **whole existing rules editor** with the contents of `firestore.rules`, then click **Publish**. Do not remove the existing `profiles` protection. The provided full file retains it and adds `/connections/{id}` and `/connections/{id}/messages/{id}` restrictions. Do not publish `allow read, write: if true;` or a broad signed-in allow rule.

Rule behavior: signed-in users can view public profiles, only profile owners can edit theirs; only connection members can see requests; only the recipient may accept/decline; only accepted members may read/send chat messages, and only the sender may edit/delete their own messages. Rules must still be tested (including denied attempts) before claiming the app is secure.

## How to run

No new dependencies: uses previously installed `cloud_firestore`, `firebase_auth`, `image_picker`, `qr_flutter`, and `mobile_scanner`.

```powershell
cd C:\Projects\secure-messenger
flutter analyze
flutter run -d R5CXC3056AT
```

If Flutter is still running and only Dart code changed, hot reload is enough; a full run is useful for a clean test.

## Two-account test on one Samsung

1. Original account is already `@s7x`. Make a second test account and save a new profile with a different username (e.g., `testuser2`).
2. While signed into original account, search `testuser2` under **Contacts & Chats** and tap **Request**, or scan its profile QR on the laptop and tap **Send Request**.
3. Sign out and sign into the second account. The incoming request should appear. Tap **Accept**.
4. Open the accepted contact, type a message, and tap **Send**.
5. Sign back into the first account. Open the same contact/chat: the message should be there. Reply.
6. On each account, edit your own message using its `⋮` menu, then delete one of your own messages. Both changes should sync to the same Firestore chat document/list.
7. In Firestore Console, inspect `connections/{sortedUidA_sortedUidB}/messages/{messageId}`. The `status` becomes `accepted`; messages store `senderId`, `text`, `createdAt`, optional `editedAt`.
8. Test invalid username, duplicate contact request, self-QR scan, and decline. Separately test denied writes with Firebase Rules Playground/emulator or a second signed-in client; admin console changes do not test Firestore client rules.

Live two-device messaging and denied-write rules tests have **not** been performed just by copying this code.

## Explicit limitations

- The standard text chat **is NOT end-to-end encrypted**. Firestore contains plaintext `text`; do not transmit secrets or imply this is a secret chat.
- Usernames are searchable but **not guaranteed unique yet**. Duplicate usernames can appear in search results; QR scanning uses the stable Firebase UID.
- Photo upload, attachments, audio/video messaging, read receipts, typing indicators, push notifications, biometric access, E2EE secret chats, user blocking/reporting/rate limiting, robust abuse prevention, and iOS testing remain open.
- A declined pair cannot send a new request in this first version; no request-reset or block-list UI yet.
- Full security testing, including cross-account permissions and actual simultaneous real-time chat tests, is still required.
- This project patch was authored from the snippets you supplied; I cannot run your Flutter project or publish rules from this environment. Run `flutter analyze` and report errors if any.
