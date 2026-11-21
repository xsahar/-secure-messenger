# Secure Messenger

A Flutter graduation project for private, real-time one-to-one messaging on Android and iOS. Users can create profiles, discover contacts by username or QR code, exchange messages and media, and open a separate **Secret Chat** for end-to-end encrypted text.

**Project status:** Android features have been tested on a Samsung phone and Android emulator. An iOS Simulator build passed on GitHub Actions; running the app on a physical iPhone has **not** been verified.

## Features

| Area | What the app does |
| --- | --- |
| Accounts | Email/password sign-up and sign-in with Firebase Authentication |
| Profiles | Username, display name, bio, and saved profile photo |
| Contact discovery | Exact-username search, personal QR codes, and QR scanning |
| Contacts | Send, accept, or decline contact requests |
| Regular chat | Real-time one-to-one text messages; sender-only edit and delete-for-everyone |
| Chat activity | Read receipts and typing indicators |
| Media | Share images, videos, and voice recordings; open images full screen and play media in chat |
| Biometric protection | Fingerprint/face **app lock** for an already signed-in account |
| Secret Chat | Separate one-to-one **text-only** conversations encrypted on the device |

The app uses a dark Material 3 interface. Group chats and push notifications are **not implemented**.

## Technology and architecture

| Technology | Role |
| --- | --- |
| Flutter + Dart | Cross-platform mobile user interface and app logic |
| Firebase Authentication | Email/password authentication and user sessions |
| Cloud Firestore | Profiles, connections, regular chat metadata/messages, typing state, and encrypted Secret Chat envelopes |
| Supabase Storage | Private storage for regular-chat media and persisted profile pictures |
| Supabase Row Level Security (RLS) | Access policies for media and profile-photo objects |
| `local_auth` | Device-provided fingerprint/face authentication for app unlocking |
| `flutter_secure_storage` | Local private key and trusted-peer public key storage |
| `cryptography` | X25519 key agreement, HKDF-SHA256, and AES-256-GCM encryption |

### In simple English

1. Firebase Authentication confirms who is signed in.
2. Firestore saves profiles, contact requests, and chat data and delivers real-time updates.
3. Large photos, videos, and voice files go to **private** Supabase Storage; Firestore keeps the corresponding message metadata.
4. The biometric gate hides signed-in conversations when the app is locked.
5. In **Secret Chat only**, the sender encrypts the text *before* uploading it. The recipient decrypts it on their own device.

**Important:** Ordinary messages and regular-chat media are **not end-to-end encrypted**. A private storage bucket is not the same as E2EE.

## Run the project

### Prerequisites

- Flutter SDK and Dart, with a supported version of the Android development tools.
- An Android phone with USB debugging enabled **or** a configured Android emulator.
- A working Firebase project with Email/Password Authentication, Cloud Firestore, and the corresponding security rules.
- A Supabase project configured for Firebase third-party authentication, private storage buckets, and the included SQL access policies.
- Internet access for Firebase and Supabase.

The repository already contains this project's Firebase configuration and Supabase **publishable** settings. Deploying a separate copy with new cloud projects requires configuring those services for the new project; copying the Flutter source alone is not sufficient.

### Run on Android (Windows PowerShell)

From the repository root:

```powershell
flutter pub get
flutter analyze
flutter test test/secret_crypto_test.dart
flutter devices
flutter run -d <device-id>
```

Replace `<device-id>` with the ID reported by `flutter devices` (for example, your connected phone). To test two accounts simultaneously, open **two** terminals and run Flutter separately for the phone and emulator, each with its own device ID.

While `flutter run` is active, press `r` for hot reload. Test microphone recording on a device/emulator with its microphone permissions and input configured.

### Cloud configuration notes

**Firebase**
- Enable **Email/Password** in Firebase Authentication.
- Configure Firestore and publish the rules in [`firestore.rules`](firestore.rules).
- The Android project includes `android/app/google-services.json`; Flutter Firebase options are in `lib/firebase_options.dart`. If using a different Firebase project, regenerate the appropriate Firebase platform configuration instead of reusing these IDs.

**Supabase**
- Configure **Firebase third-party authentication** for the Firebase project used by the app.
- Keep both `chat-media` and `profile-photos` buckets **private**.
- For a *new* Supabase database, review and apply the repository's SQL scripts in this order:
  1. [`SUPABASE_SETUP.sql`](SUPABASE_SETUP.sql)
  2. [`SUPABASE_MEDIA_CONSENT_PATCH.sql`](SUPABASE_MEDIA_CONSENT_PATCH.sql)
  3. [`SUPABASE_PROFILE_PHOTOS.sql`](SUPABASE_PROFILE_PHOTOS.sql)
- Configure the app's Supabase URL and **publishable** key in `lib/supabase_config.dart`.

**Do not re-run setup SQL on a working production database without reviewing its effects.** Never put a Supabase `service_role` key, database password, or other secret in the Flutter client. Storage access relies on verified Firebase identity and database policies, not on the publishable key being secret.

### iOS build verification

An iOS Simulator build is available through [the GitHub Actions workflow](.github/workflows/ios-build.yml):

- Open the repository's **Actions** tab.
- Choose **Verify iOS Build** and select **Run workflow** on `main`.
- The workflow runs `flutter pub get` and `flutter build ios --simulator --debug` on a macOS runner.

**Evidence:** [Successful iOS Simulator build — run #1](https://github.com/xsahar/-secure-messenger/actions/runs/44910679966).

A successful simulator **build** confirms compilation; it does **not** prove all functions have been tested on a running iOS simulator or physical iPhone. Running or distributing an iOS app requires the relevant Apple tooling and, where applicable, signing.

## User guide

### 1. Sign up and create a profile

1. Open the app, choose **Create an account**, and register with email and password.
2. Sign in; if biometric verification is set up on the device, the app requests fingerprint/face verification to **unlock the signed-in app**.
3. Open **Profile**, enter a username, display name, and optional bio.
4. Choose a profile picture and tap **Save profile** to upload and save it.
5. Select **Show my QR code** to display a QR containing non-secret profile information.

**Biometrics are an app lock, not a substitute for the initial Firebase email/password sign-in.** The device needs enrolled biometrics; there is no separate biometric enable switch in the app.

### 2. Add a contact

- **Search:** Open Contacts, enter an **exact** username, and send a request.
- **QR:** Open the QR scanner, scan another user's Secure Messenger profile QR, and choose **Send Request**.
- The recipient opens their contact requests and **accepts** the request. An accepted connection enables the one-to-one chat.

### 3. Send messages and media

1. Open an accepted contact's chat.
2. Type and send a text message; messages update in real time.
3. Use the media controls to send an image or video, or record and send a voice message.
4. Tap an image for the full-screen viewer, a video preview to play it, or a voice message's playback control.
5. Watch for **typing** and **seen/read** indicators.
6. Use a sent message's action menu to **edit** a text message or **delete for everyone**.

Limits enforced by the client include **3 MB images**, **12 MB videos**, and **2 MB voice clips**; recordings stop after up to **60 seconds**. Media requires an internet connection and valid private-storage permissions. For a new accepted chat, **both** participants may need to open the regular chat once so the Supabase media-consent records can be established.

### 4. Use Secret Chat

1. Open an accepted contact's regular conversation.
2. Tap the **lock** icon to enter **Secret Chat**.
3. Both users must initialize Secret Chat on their devices; if the peer has not yet published their public key, follow the on-screen Retry guidance.
4. Send **text** messages. Firestore stores `ciphertext`, `nonce`, `mac`, `version`, `senderId`, and `createdAt`, **not plaintext**.
5. Use the **key fingerprint** control to compare fingerprints with the other participant using a separate trusted channel.

**Secret Chat is text-only.** Regular-chat media, typing indicators, and ordinary messages are not covered by its E2EE. Secret Chat private keys are specific to the device installation; recovering or synchronizing them across devices is not implemented.

## Security design and limitations

### Implemented protections

- Firebase sign-in protects account access.
- Firestore rules restrict connection and chat access to accepted members and control message ownership, edits, deletes, and Secret Chat writes.
- Biometric app locking prevents casual access to the signed-in UI when locked.
- Profile photos and ordinary-chat media use **private** Supabase Storage buckets with RLS policies.
- The media authorization design records consent from both Firebase-identified participants before access.
- Secret Chat derives a conversation-bound shared key using **X25519 + HKDF-SHA256** and encrypts text using **AES-256-GCM**.
- Device-local private key storage and public-key fingerprint comparison help protect Secret Chat identity.

### Important limitations

- This is an **educational/prototype E2EE implementation**, **not Signal** or a Double Ratchet. It does **not** offer forward secrecy, automatic key rotation, or multi-device key recovery.
- Public-key fingerprints must be compared over a trusted channel to reduce first-contact impersonation risk.
- Firestore still stores Secret Chat metadata such as sender and timestamp; E2EE hides message **content**, not all metadata.
- Regular-chat text and media are **not** end-to-end encrypted.
- Supabase media consent does **not** automatically track later Firestore connection-status changes. Automatic revocation/blocking synchronization and production-grade abuse prevention are not implemented.
- Unauthorized-access simulations are valuable but are **not** a full penetration test or stress test.
- iOS compilation is confirmed; actual iOS device/runtime behavior is not confirmed.

## Tests and audit evidence

### Completed checks

- Android device + emulator: sign-in, profiles, contact/QR request flow, one-to-one text and media exchange, read receipts, typing, edit, delete, and Secret Chat demonstrated.
- Android biometric unlocking demonstrated.
- `flutter analyze` and `flutter test test/secret_crypto_test.dart` previously completed successfully on the development machine.
- The cryptography tests check that both participants derive a compatible key, that the recipient recovers the plaintext, and that tampered ciphertext metadata or a wrong conversation context is rejected.
- **13 Firestore Rules Playground simulations passed**: unauthorized and authenticated reads, accepted-member reads, connection access, message ownership/deletion, and Secret Chat access/deletion. These are scoped simulations of particular requests, not a comprehensive security audit.
- [iOS Simulator build passed on GitHub Actions](https://github.com/xsahar/-secure-messenger/actions/runs/44910679966).

### Suggested audit demonstration

1. Launch the app on two Android devices/emulators and sign in to two accounts.
2. Show saved profile information, profile picture, personal QR, and username search.
3. Scan a QR or send/accept a contact request.
4. Exchange text, image, video, and voice messages.
5. Demonstrate real-time delivery, typing, read receipts, edit, and delete-for-everyone.
6. Demonstrate biometric lock/unlock.
7. Open Secret Chat on both devices; exchange encrypted text and show that Firestore contains an encrypted envelope rather than plaintext.
8. Show the passing cryptography tests, Firestore security-rule simulations, and successful iOS build workflow.

## Main source files

| Path | Responsibility |
| --- | --- |
| `lib/main.dart` | Initialize Firebase/Supabase and route by login state |
| `lib/auth_screen.dart` | Sign-up and sign-in UI |
| `lib/biometric_gate.dart` | Biometric app-lock lifecycle |
| `lib/profile_screen.dart`, `lib/profile_photo_service.dart` | Profile, QR, and cloud profile picture |
| `lib/contacts_screen.dart`, `lib/scan_qr_screen.dart`, `lib/connection_service.dart` | User discovery, QR scanning, and contact requests |
| `lib/chat_screen.dart`, `lib/chat_media_content.dart` | Regular messages and media |
| `lib/secret_chat_screen.dart`, `lib/secret_crypto.dart`, `lib/secret_key_service.dart` | Encrypted text chat, cryptography, and device keys |
| `firestore.rules` | Firestore authorization rules |
| `SUPABASE_*.sql` | Supabase private-storage and access-policy setup |
| `test/secret_crypto_test.dart` | Cryptography tests |
| `.github/workflows/ios-build.yml` | Cloud-based iOS simulator compilation check |

## Project scope

This project implements the **core functional requirements** for one-to-one secure messaging. **Group chats** and **push notifications** are optional bonus features and have not been added.

Some additional repository files (`README_SETUP.md`, `README.txt`, `BATCH4_README.md`) are **historical development/patch notes**. This `README.md` documents the current completed project and should be used first.
