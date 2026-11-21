import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'profile_photo_service.dart';

/// Displays a private profile photo using a Firebase-verified Supabase request.
/// There is no public URL, and a missing photo falls back to a user's initial.
class ProfileAvatar extends StatefulWidget {
  const ProfileAvatar({
    super.key,
    required this.userId,
    required this.storagePath,
    required this.displayName,
    this.radius = 23,
  });

  final String userId;
  final String storagePath;
  final String displayName;
  final double radius;

  @override
  State<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<ProfileAvatar> {
  late Future<Uint8List?> _photo;

  void _refresh() {
    _photo = ProfilePhotoService.download(widget.userId, widget.storagePath);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.storagePath != widget.storagePath) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.displayName.trim();
    final first = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    final diameter = widget.radius * 2;
    return FutureBuilder<Uint8List?>(
      future: _photo,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        return CircleAvatar(
          radius: widget.radius,
          backgroundColor: AppTheme.mine,
          child: bytes == null
              ? Text(
                  first,
                  style: TextStyle(
                    color: AppTheme.accent,
                    fontSize: widget.radius * 0.85,
                    fontWeight: FontWeight.w800,
                  ),
                )
              : ClipOval(
                  child: Image.memory(
                    bytes,
                    width: diameter,
                    height: diameter,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => Text(
                      first,
                      style: TextStyle(
                        color: AppTheme.accent,
                        fontSize: widget.radius * 0.85,
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
