Secure Messenger — Photo/video fullscreen viewer

Replace ONLY lib/chat_media_content.dart.
This file is based on your working Supabase media version after the video-button and biometric picker fixes.

New behavior:
- Compact photo thumbnail; tap to view full screen and pinch-to-zoom.
- Compact video preview; tap to play in a full-screen player with scrubbing.
- Existing inline Play/Pause button stays working.
- Audio messages and Supabase loading remain unchanged.
- No new packages, database migrations, or Firebase/Supabase rules.

Windows PowerShell:
  flutter analyze
  flutter run -d R5CXC3056AT

Test on phone:
1. Open standard chat; tap an image to open it full screen, zoom, go back.
2. Tap a video thumbnail; play, scrub and return.
3. Verify inline Play/Pause still works and becomes Play after completion.
4. Confirm biometrics still lock on Home/resume, and Secret Chat is unaffected.

Media in standard chat is not end-to-end encrypted.
