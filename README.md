# Secure Messenger — Picker/Video UI Fix (Supabase media batch)

This patch fixes two issues and moves the signed-in routes below the biometric lock.

## Replace only these four files in `lib/`
- `main.dart` (keeps Firebase + Supabase initialization)
- `biometric_gate.dart` (keeps cancel/retry behavior; adds a trusted media-picker scope)
- `chat_screen.dart` (wraps only the Android/iOS image/video picking activity)
- `chat_media_content.dart` (video play button uses `ValueListenableBuilder` and recognizes playback completion)

The other files, Firebase Firestore rules, Supabase SQL, Supabase config URL/key, and Secret Chat are untouched.
**Back up/commit before replacing.** The code in `main.dart` assumes your initialized app currently matches our prior version; if you've since customized that file, merge its two relevant changes rather than overwrite.

Run `flutter analyze`, then fully restart the Samsung and emulator Flutter sessions. Test: send image and short video, verify no unnecessary fingerprint prompt; play video to end and verify it says Play video; Home/back should still lock; cancel prompt in a chat must block chat contents (not reveal a pushed route).

Security caveat: system-picker exemption is scoped to the duration of file selection. Further adversarial lifecycle/security and media-authorization tests are needed before production use.
