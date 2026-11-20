# Secure Messenger — Batch 4: Photo, video & voice messages (standard chat)

**Status: implementation files prepared from the exact tested Batch 3 archive. NOT compiled or device-tested in this authoring environment. Keep your working Git backup.** This batch does not change Secret Chat, encryption keys, profiles, contacts, biometrics, or main.dart.

## Important cost and privacy decision

**Cloud Storage for Firebase requires the Blaze (pay-as-you-go) Firebase plan.** Enabling it requires a billing account; usage may incur charges even if some low-usage quotas apply. **No billing change was made for you.** See https://firebase.google.com/docs/storage/flutter/start . Set a small billing budget alert if you voluntarily enable it; an alert is **not** a hard spending cap. For this graduating-project prototype, use a test bucket with only tiny files. Without a Storage bucket, normal text and secret text chats keep working, but photo/video/voice uploads will fail.

Media is sent in **standard chats only** and is **NOT end-to-end encrypted**. Cloud Storage and privileged administrators can access it, and recipients can potentially save copies. We use Firebase Storage SDK authenticated `getData`/`writeToFile`, **not public download-token URLs**. Firebase Storage Security Rules restrict access to accepted contacts; confirm with authorization tests before production use.

## What to install

1. Stop both `flutter run` terminals with `q`. Back up working project with Git (check for secrets before committing).
2. In PowerShell inside `C:\Projects\secure-messenger`:

   ```powershell
   flutter pub add firebase_storage record path_provider video_player just_audio
   ```

   Already installed from previous batches: `image_picker`, `cloud_firestore`, `firebase_auth`.
3. Copy only the two Dart files from this ZIP:
   - `lib/chat_screen.dart` → **replace** existing `lib/chat_screen.dart` (preserves text, typing, Seen, edit/delete and Secret Chat lock icon)
   - `lib/chat_media_content.dart` → **new**

   Do **not** replace main.dart, profile, auth, secret-chat or biometric files.
4. Root `firestore.rules` → **replace the root file**. Then open **Firebase Console → Firestore Database → Rules** and **Publish** its **entire contents**. Existing secret-key / secret-message rules are retained.
5. `storage.rules` → **new root file** (SEPARATE from firestore.rules). In **Firebase Console → Storage → Rules**, publish its **entire contents**. Do NOT paste Storage rules into Firestore rules.
6. If Firebase Console shows **Get started** under Storage, provision the default bucket (this requires voluntarily enabling Blaze billing). Firebase may request permission to use Firestore data in Storage Rules; approve the necessary cross-service link if prompted. After the bucket exists, refresh Firebase Flutter config:

   ```powershell
   flutterfire configure --platforms=android,ios
   ```

   Ensure `DefaultFirebaseOptions.currentPlatform.storageBucket` is set and points to the actual Storage bucket. Do not replace your existing auth project.
7. Android: in `android/app/src/main/AndroidManifest.xml`, add this line **inside `<manifest>` above `<application>`**, keeping all other app entries:

   ```xml
   <uses-permission android:name="android.permission.RECORD_AUDIO" />
   ```

   Image/video picking from the gallery does not require asking for broad device storage permissions with the modern Android picker. `record` asks for microphone permission at runtime.
8. iOS (later): `ios/Runner/Info.plist` needs `NSMicrophoneUsageDescription` (e.g. `To record voice messages.`) and `NSPhotoLibraryUsageDescription` (`To send photos and videos.`). No iOS device tests have been done.

## Run checks and launch

```powershell
flutter pub get
flutter analyze
flutter run -d R5CXC3056AT
```

In another terminal (with emulator started):

```powershell
flutter run -d emulator-5554
```

Use `flutter devices` if the emulator ID changed. **Full rebuild** is necessary because of native packages.

## Quick one-batch test (both users already connected)

1. On Samsung (account @s7x) open a **standard** chat, tap the **paperclip**, choose a small photo. Confirm it appears on emulator, and vice versa. Limit image **3 MB**, accepted JPEG/PNG/WebP.
2. Paperclip → **Video**, select a short **MP4 under 12 MB**. On emulator tap **Load video**, then **Play video**. A selected 4K video may exceed the limit; use a short compressed clip. `.mov` may be supported on iOS, not every Android decoder.
3. Tap microphone to **start** recording; tap again to **stop and send** (max 60 seconds or 2 MB). On emulator tap **Load voice message**, then **Play voice message**. Microphone permission must be granted. The button records from the **device/emulator microphone**, which can be configured in Android emulator settings.
4. Check **Seen** status and **Delete for everyone** for a media message. Text editing stays available on text messages only.
5. Open your **Secret Chat** with the lock icon; verify existing encrypted TEXT messages still appear. Media from this batch does not enter Secret Chat.
6. If a request fails with `permission-denied`, verify both **Firestore** and **Storage** rules were published separately and the Storage bucket is configured in `firebase_options.dart`.

## Data model

`connections/{connectionId}/messages/{messageId}` now accepts **either**:

- Text: `{senderId, text, createdAt}` (old, untouched), or
- Media: `{senderId, mediaType: image|video|audio, storagePath, mediaSize, contentType, createdAt}`.

A recipient can set `readAt` under the original Seen rule. Sender can delete media docs and the app attempts to delete the corresponding Storage object. A failed cleanup can leave an orphan blob—needs an administrator garbage-collection job for production. The app does not place a Firebase Storage download-token URL in messages.

Storage path: `connections/{connectionId}/{senderUid}/{messageId}.{extension}`. `storage.rules` reads the accepted-membership document from default Firestore and restricts upload/read/delete by auth, type, file size, and uploader. A Firebase administrator or anyone with privileged service credentials can bypass client Security Rules. A malicious uploader can spoof declared MIME types; production should independently validate media content, scan uploads, add quotas and cleanup, and abuse-test rules. No automated integration tests have been run here.

## Limits/notes

- Standard media is **not encrypted end-to-end**. Never present it as Secret Chat content.
- Large media must not be stored in Firestore fields. The app downloads a selected audio/video file to the OS temporary directory for local playback; images load into memory. Android clears temporary files periodically and the viewer also attempts cleanup on disposal. It is not an encrypted local cache.
- Requires an online Firebase Storage bucket and network; Firestore caching alone cannot serve media files offline.
- For security/cost, this is a demo-sized implementation, not a production-ready secure media-sharing protocol. Test on both devices first, then verify authorization with Firebase emulators.

Reference docs: https://firebase.google.com/docs/storage/flutter/start ; https://firebase.google.com/docs/storage/security/rules-conditions ; https://pub.dev/packages/record ; https://pub.dev/packages/video_player
