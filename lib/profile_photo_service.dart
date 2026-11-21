import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Private Supabase profile photos. Never put service-role keys or public URLs
/// into the Flutter app / Firestore profile documents.
abstract final class ProfilePhotoService {
  static const bucket = 'profile-photos';
  static const maxBytes = 2 * 1024 * 1024;

  static String get _uid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in again before saving a photo.');
    return uid;
  }

  static final _pathPattern = RegExp(
    r'^profiles/[^/]+/[0-9]{16,17}\.(jpg|jpeg|png|webp)$',
  );

  static bool validPathFor(String uid, String path) =>
      path.startsWith('profiles/$uid/') && _pathPattern.hasMatch(path);

  /// Upload first, then write the returned private path into profiles/{uid}.
  /// The unique path prevents stale images and accidental overwrites.
  static Future<String> upload(File file) async {
    final uid = _uid;
    final size = await file.length();
    if (size <= 0 || size > maxBytes) {
      throw StateError('Choose a profile photo smaller than 2 MB.');
    }
    final ext = file.path.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => null,
    };
    if (mime == null) {
      throw StateError('Choose a JPG, PNG or WebP photo.');
    }
    final path = 'profiles/$uid/${DateTime.now().microsecondsSinceEpoch}.$ext';
    await Supabase.instance.client.storage.from(bucket).upload(
      path,
      file,
      fileOptions: FileOptions(contentType: mime, upsert: false),
    );
    return path;
  }

  /// Only signed-in users may read avatars; this is enforced by Supabase RLS.
  /// The caller must supply the correct user id to prevent path confusion.
  static Future<Uint8List?> download(String uid, String path) async {
    if (!validPathFor(uid, path)) return null;
    try {
      final bytes = await Supabase.instance.client.storage
          .from(bucket)
          .download(path);
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
      return bytes;
    } catch (_) {
      // Missing/old avatar should gracefully fall back to an initial.
      return null;
    }
  }

  /// Best-effort cleanup of the owner's previous avatar (or an upload whose
  /// Firestore metadata write failed). Cannot delete anyone else's avatar.
  static Future<void> removeOwn(String path) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || !validPathFor(uid, path)) return;
    try {
      await Supabase.instance.client.storage.from(bucket).remove([path]);
    } catch (_) {
      // Failure to clean an old blob must never undo a saved profile.
    }
  }
}
