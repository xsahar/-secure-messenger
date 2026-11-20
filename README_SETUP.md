# Secure Messenger — Free Supabase media storage patch

**Goal:** Keep Firebase Authentication, Firestore text chats, Secret Chat, biometrics, and existing Firestore rules. Replace *only* media-file storage (image/video/voice) from paid Firebase Cloud Storage with Supabase's Free Storage tier. **No Firebase Blaze upgrade.**

This was prepared against Batch 4 files; it has **not** been compiled or device-tested in the user's project. Use a Git backup first.

## 1. Keep Firebase as it is

- Leave the Firebase Blaze checkout screen. Do not create a billing account.
- **Do not** replace or republish `firestore.rules`. The Batch 4 Firestore rule already accepts the `connections/<connectionId>/<senderUid>/<messageId>.<ext>` media path, which we preserve.
- Do **not** publish `storage.rules` from Batch 4. That file applies to Firebase Cloud Storage; Supabase uses SQL policies instead.

## 2. Create the Supabase Free project

1. Go to https://supabase.com/dashboard and sign in/create a Supabase account.
2. **New project**, project name `secure-messenger-media`, choose the **Free ($0)** plan, region, and a strong database password. This password stays in the dashboard; **never put it into Flutter**.
3. Open **Authentication → Third-Party Auth** (may also be under Authentication settings). Add **Firebase Auth** and enter the **Firebase project ID** `messenger-ef774`. Save. This tells Supabase to verify Firebase's signed ID tokens.
4. Open **SQL Editor → New query**. Paste the **entire** `SUPABASE_SETUP.sql` file and click **Run**. The script creates a **private** `chat-media` bucket, limits uploads to 12 MB and selected MIME types, and creates three RLS policies.
5. In **Storage**, confirm the bucket **chat-media** is marked **Private**, not Public. Do **not** toggle it to Public, add an unrestricted policy, or use `service_role`/secret keys in Flutter.

**Important:** Because your existing Firebase tokens lack Supabase's `role` custom claim, the SQL policies explicitly allow the database's `anon` role only when the request has a verified Firebase JWT whose `iss`, `aud`, and UID match your Firebase project. An ordinary anonymous/public-key request will be denied. This avoids requiring paid Firebase Cloud Functions for custom claims; it still needs security testing before production deployment.

## 3. Get your Supabase public settings

In the Supabase dashboard, use **Project Settings → API Keys** (or the **Connect** panel) to find:

- **Project URL:** `https://<project-ref>.supabase.co`
- **Publishable key:** starts with `sb_publishable_...` (a legacy anon key can also be supported by the SDK, if that's all your dashboard offers).

Open `lib/supabase_config.dart` and replace the two placeholder strings. **Never paste a secret, database password, or `service_role` key.** The publishable key is not a secret; Row Level Security is the actual authorization barrier.

## 4. Install source files and Flutter package

1. Make a backup first: `git add -A && git commit -m "Working pre-Supabase media version"` (PowerShell supports these commands separately if `&&` isn't accepted).
2. From this ZIP, copy to your project's `lib` folder:
   - `chat_screen.dart` (**replaces** Batch 4 version)
   - `chat_media_content.dart` (**replaces** Batch 4 version)
   - `supabase_config.dart` (**new**)
3. Run in PowerShell:

   ```powershell
   cd C:\Projects\secure-messenger
   flutter pub add supabase_flutter
   flutter pub get
   ```

You can leave the old `firebase_storage` dependency installed until everything works, though these two files no longer use it.

## 5. One small change in `lib/main.dart`

Add these imports near your other imports:

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';
```

In `main()`, AFTER your existing `await Firebase.initializeApp(...)` and BEFORE `runApp(...)`, insert:

```dart
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
    accessToken: () async {
      return FirebaseAuth.instance.currentUser?.getIdToken();
    },
  );
```

**Do not** replace the rest of `main.dart`, `BiometricGate`, Firebase login, or secret-chat screens. This uses each already-logged-in Firebase user's ID token for Supabase Storage access. Their accounts are unchanged.

## 6. Analyze and test

```powershell
flutter analyze
flutter test test/secret_crypto_test.dart
```

Then in TWO PowerShell terminals:

```powershell
flutter run -d R5CXC3056AT
```

and in another terminal (use your actual emulator ID from `flutter devices`):

```powershell
flutter run -d emulator-5554
```

Log into your existing two accounts. Use **standard chat** (not Secret Chat):

1. Samsung → send a small photo (<=3MB), emulator → open it.
2. Emulator → send a short `.mp4` video (<=12MB), Samsung → play it.
3. Samsung → tap microphone, record a few seconds, tap again to send (<=2MB), emulator → play it.
4. Delete an attachment from its sender account; it should disappear in Firestore and the Supabase file should be removed.
5. Recheck a standard text message, Seen, typing, and Secret Chat to confirm nothing regressed.

If upload fails, copy the exact `Supabase upload failed...` message; don't disable policies to get around it.

## Security boundaries and limitations

- Supabase is a **private bucket**, verified Firebase ID tokens are required, and RLS checks the authenticated UID against the pair of UIDs encoded in the Firestore connection ID. A third Firebase user who is not a member of the encoded pair must not be able to download the file.
- **Supabase cannot query Firestore's `status == accepted` directly.** Therefore these rules enforce connection-ID pair membership, not a live check that the connection is accepted. Firestore rules still control who may write the message record. This is a graduation prototype; don't claim production-grade cross-service authorization.
- Firebase IDs with `_` (underscore) are not supported by this simple split-based policy. Your current Firebase-generated UIDs appear to be alphanumeric, but verify this if you encounter rejected uploads.
- Media in **standard chats is NOT end-to-end encrypted**. Secret Chat remains text-only with its previously described cryptographic limitations.
- Supabase Free currently includes **1 GB Storage**, free transfer limits, and **50 MB max upload size**; this patch imposes a stricter 12 MB bucket limit. The Free plan may pause inactive projects after approximately one week.
- The sender can attempt uploads even without a live accepted Firestore connection; the message record remains protected by Firestore, but orphaned uploads can accumulate. Add abuse controls, quotas, rate limits, and cross-service membership sync for real deployment.
- No security assessment has yet validated that Supabase enforces these third-party-auth policies in your project. Test as both members and as an unrelated signed-in Firebase test account; test no token/anon-key alone is rejected.
