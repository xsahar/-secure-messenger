import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';


/// Small, process-memory-only LRU cache. Account-scoped to avoid mixing users;
/// no public URLs, persistence, or database changes. 24 MB max.
class _MediaCache {
  static final _stored = <String, Uint8List>{};
  static final _pending = <String, Future<Uint8List>>{};
  static int _bytes = 0;
  static const _maxBytes = 24 * 1024 * 1024;

  static void clear() {
    _stored.clear();
    _bytes = 0;
  }

  static void evict(String path) {
    for (final key in _stored.keys.where((key) => key.endsWith('|$path')).toList()) {
      _bytes -= _stored.remove(key)!.length;
    }
  }

  static Future<Uint8List> get(String path, int limit) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in to view media.');
    final key = '$uid|$path';
    final cached = _stored.remove(key);
    if (cached != null) {
      _stored[key] = cached;
      return Future<Uint8List>.value(cached);
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final task = _download(key, uid, path, limit);
    _pending[key] = task;
    return task.whenComplete(() => _pending.remove(key));
  }

  static Future<Uint8List> _download(
      String key, String uid, String path, int limit) async {
    final data = await Supabase.instance.client.storage
        .from('chat-media').download(path);
    if (data.isEmpty || data.length > limit) {
      throw StateError('Media missing or larger than allowed.');
    }
    // Do not retain the previous account's bytes after a login switch.
    if (FirebaseAuth.instance.currentUser?.uid == uid &&
        data.length <= _maxBytes) {
      while (_bytes + data.length > _maxBytes && _stored.isNotEmpty) {
        final oldest = _stored.keys.first;
        _bytes -= _stored.remove(oldest)!.length;
      }
      _stored[key] = data;
      _bytes += data.length;
    }
    return data;
  }
}

/// Only one voice/video player can be active across open message widgets.
class _PlaybackFocus {
  static Object? _owner;
  static Future<void> Function()? _pause;

  static Future<void> claim(Object owner, Future<void> Function() pause) async {
    if (identical(_owner, owner)) return;
    final previous = _pause;
    _owner = owner;
    _pause = pause;
    if (previous != null) {
      try { await previous(); } catch (_) {}
    }
  }

  static void release(Object owner) {
    if (identical(_owner, owner)) {
      _owner = null;
      _pause = null;
    }
  }

  static Future<void> stop() async {
    final previous = _pause;
    _owner = null;
    _pause = null;
    if (previous != null) {
      try { await previous(); } catch (_) {}
    }
  }
}

/// Loads files from PRIVATE Supabase Storage using Firebase ID tokens.
/// Never writes public or signed URLs into Firestore.
/// Standard-chat media is not end-to-end encrypted.
class ChatMediaContent extends StatefulWidget {
  const ChatMediaContent({
    super.key,
    required this.connectionId,
    required this.storagePath,
    required this.mediaType,
    this.consentReady,
  });

  final String connectionId;
  final String storagePath;
  final String mediaType; // image, video, audio
  final Future<void>? consentReady;

  /// Used when the sender deletes the original file or signs out.
  static void forgetMedia(String path) => _MediaCache.evict(path);
  static void clearSessionMedia() {
    _MediaCache.clear();
    unawaited(_PlaybackFocus.stop());
  }

  /// Stop the current voice/video when the app locks or leaves a chat.
  static Future<void> pauseAllMedia() => _PlaybackFocus.stop();

  @override
  State<ChatMediaContent> createState() => _ChatMediaContentState();
}

class _ChatMediaContentState extends State<ChatMediaContent> {
  Uint8List? _image;
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  File? _localFile;
  bool _busy = false;
  bool _playing = false;
  bool _resettingAudio = false;
  String? _error;

  bool get _validPath => widget.storagePath.startsWith(
        'connections/${widget.connectionId}/',
      ) && widget.storagePath.split('/').length == 4;

  int get _limit => switch (widget.mediaType) {
        'image' => 3 * 1024 * 1024,
        'audio' => 2 * 1024 * 1024,
        'video' => 12 * 1024 * 1024,
        _ => 0,
      };

  @override
  void initState() {
    super.initState();
    // Images and small voice notes prepare themselves in visible chat cells.
    // Large videos remain lazy, but opening them needs only one tap.
    if (widget.mediaType == 'image' || widget.mediaType == 'audio') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
  }

  Future<void> _load() async {
    if (_busy || _limit == 0 || !_validPath) {
      if (mounted && !_validPath) {
        setState(() => _error = 'Invalid media location.');
      }
      return;
    }
    if (_image != null || _localFile != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    File? pending;
    try {
      // Bucket limits files to 12 MB; Firestore rules additionally restrict
      // each media type to its smaller app-specific maximum. Downloaded files
      // are bounded again after retrieval, before display or playback.
      final ready = widget.consentReady;
      if (ready != null) await ready;
      if (!mounted) return;
      final bytes = await _MediaCache.get(widget.storagePath, _limit);
      if (widget.mediaType == 'image') {
        if (mounted) setState(() => _image = bytes);
      } else {
        final cache = await getTemporaryDirectory();
        final suffix = widget.mediaType == 'video' ? 'mp4' : 'm4a';
        // Do not use untrusted file names as filesystem paths.
        pending = File(
          '${cache.path}/secure_media_${DateTime.now().microsecondsSinceEpoch}.$suffix',
        );
        await pending.writeAsBytes(bytes, flush: true);
        if (await pending.length() > _limit) {
          throw StateError('The downloaded file exceeds the allowed size.');
        }
        if (!mounted) {
          if (await pending.exists()) await pending.delete();
          return;
        }
        if (widget.mediaType == 'video') {
          final controller = VideoPlayerController.file(pending);
          await controller.initialize();
          if (!mounted) {
            await controller.dispose();
            if (await pending.exists()) await pending.delete();
            return;
          }
          setState(() {
            _video = controller;
            _localFile = pending;
          });
        } else {
          final player = AudioPlayer();
          await player.setFilePath(pending.path);
          if (!mounted) {
            await player.dispose();
            if (await pending.exists()) await pending.delete();
            return;
          }
          setState(() {
            _audio = player;
            _localFile = pending;
          });
          player.playerStateStream.listen((state) {
            if (!mounted) return;
            if (state.processingState == ProcessingState.completed &&
                !_resettingAudio) {
              // just_audio can keep `playing == true` at end-of-file.
              // Pause AND seek back to zero so Replay really starts again.
              unawaited(_resetCompletedAudio(player));
            }
          });
        }
      }
    } catch (error) {
      if (pending != null) {
        try {
          if (await pending.exists()) await pending.delete();
        } catch (_) { /* cache cleanup best-effort */ }
      }
      if (mounted) {
        setState(() => _error = error is StorageException
            ? 'Supabase media unavailable: ${error.message}'
            : 'Could not open media: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // The compact preview uses the already downloaded bytes/file.
  // Opening the viewer never creates public download URLs.
  void _openImage() {
    final bytes = _image;
    if (bytes == null || !mounted) return;

    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _FullScreenImagePage(bytes: bytes),
        ),
      ),
    );
  }

  Future<void> _openVideo() async {
    if (_busy) return;
    if (_video == null) await _load();
    final file = _localFile;
    if (file == null || !mounted) return;
    await _PlaybackFocus.stop();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _FullScreenVideoPage(filePath: file.path),
      ),
    );
  }

  Future<void> _resetCompletedAudio(AudioPlayer player) async {
    if (_resettingAudio) return;
    _resettingAudio = true;
    try {
      await player.pause();
      await player.seek(Duration.zero);
    } catch (_) {
      // A disposed player should not crash the chat.
    } finally {
      _resettingAudio = false;
      if (mounted) setState(() => _playing = false);
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _toggleAudio() async {
    final player = _audio;
    if (player == null || _resettingAudio) return;
    try {
      if (player.playing &&
          player.processingState != ProcessingState.completed) {
        await player.pause();
        _PlaybackFocus.release(this);
        if (mounted) setState(() => _playing = false);
      } else {
        if (player.processingState == ProcessingState.completed) {
          await player.seek(Duration.zero);
        }
        await _PlaybackFocus.claim(this, () async {
          await player.pause();
          if (mounted) setState(() => _playing = false);
        });
        // Do not await play(): it may finish only after playback completes.
        if (mounted) setState(() => _playing = true);
        unawaited(player.play().catchError((Object error) {
          if (mounted) {
            setState(() {
              _playing = false;
              _error = 'Audio playback failed.';
            });
          }
        }));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
        _playing = false;
        _error = 'Audio playback failed.';
      });
      }
    }
  }

  @override
  void dispose() {
    _PlaybackFocus.release(this);
    final video = _video;
    final audio = _audio;
    final file = _localFile;
    if (video != null) video.dispose();
    if (audio != null) audio.dispose();
    if (file != null) {
      // Playback must stop before deleting its temporary file.
      // The temp folder is also cleared automatically by the OS.
      // Ignore errors during cleanup.
      () async {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = _image;
    final audio = _audio;
    final video = _video;
    if (_error != null) {
      return SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load media', style: TextStyle(color: scheme.error)),
            TextButton.icon(
              onPressed: () => unawaited(_load()),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (widget.mediaType == 'image') {
      if (image == null) {
        return const SizedBox(
          width: 200, height: 160,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      return InkWell(
        onTap: _openImage,
        borderRadius: BorderRadius.circular(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              Image.memory(image, width: 230, height: 170, fit: BoxFit.cover),
              const Positioned(
                right: 8, top: 8,
                child: Icon(Icons.open_in_full_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }
    if (widget.mediaType == 'video') {
      return InkWell(
        onTap: _busy ? null : _openVideo,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 230,
          height: 132,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1E4363), Color(0xFF152538)],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            children: [
              if (video != null)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: video.value.size.width,
                        height: video.value.size.height,
                        child: VideoPlayer(video),
                      ),
                    ),
                  ),
                ),
              Center(
                child: _busy
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 34),
                      ),
              ),
              const Positioned(
                left: 12, bottom: 9,
                child: Row(
                  children: [
                    Icon(Icons.videocam_rounded, color: Colors.white70, size: 16),
                    SizedBox(width: 5),
                    Text('Video · Tap to watch',
                      style: TextStyle(color: Colors.white, fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (widget.mediaType == 'audio') {
      if (audio == null) {
        return const SizedBox(
          width: 224, height: 54,
          child: Center(child: LinearProgressIndicator(minHeight: 2)),
        );
      }
      return SizedBox(
        width: 236,
        child: Row(
          children: [
            IconButton.filledTonal(
              tooltip: _playing ? 'Pause voice message' : 'Play voice message',
              onPressed: _toggleAudio,
              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Voice message',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  StreamBuilder<Duration>(
                    stream: audio.positionStream,
                    initialData: audio.position,
                    builder: (context, snapshot) {
                      final position = snapshot.data ?? Duration.zero;
                      final duration = audio.duration ?? Duration.zero;
                      final maxMs = duration.inMilliseconds > 0
                          ? duration.inMilliseconds.toDouble() : 1.0;
                      return Column(
                        children: [
                          SizedBox(
                            height: 18,
                            child: Slider(
                              value: position.inMilliseconds.toDouble().clamp(0.0, maxMs).toDouble(),
                              min: 0, max: maxMs,
                              onChanged: (value) => unawaited(
                                audio.seek(Duration(milliseconds: value.round()))),
                            ),
                          ),
                          Text('${_formatDuration(position)} / ${_formatDuration(duration)}',
                              style: TextStyle(fontSize: 11,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return const Text('Unsupported media type');
  }
}


/// Full-screen image viewer with pinch-to-zoom.
/// The already-downloaded bytes never leave the app.
class _FullScreenImagePage extends StatelessWidget {
  const _FullScreenImagePage({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Photo'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 5,
          child: Center(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Text('Unable to display photo',
                      style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen video player that reuses the cached PRIVATE media file.
/// A separate controller allows the inline preview to remain independent.
class _FullScreenVideoPage extends StatefulWidget {
  const _FullScreenVideoPage({required this.filePath});

  final String filePath;

  @override
  State<_FullScreenVideoPage> createState() => _FullScreenVideoPageState();
}

class _FullScreenVideoPageState extends State<_FullScreenVideoPage> {
  late final VideoPlayerController _controller;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath));
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      if (!mounted) return;
      setState(() => _ready = true);
      // Tapping a video preview opens AND starts it, without a second tap.
      await _PlaybackFocus.claim(this, () async {
        await _controller.pause();
      });
      if (mounted) await _controller.play();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to open video.');
      }
    }
  }

  Future<void> _toggle() async {
    if (!_ready) return;
    final value = _controller.value;
    if (value.isPlaying && !value.isCompleted) {
      await _controller.pause();
    } else {
      if (value.isCompleted || value.position >= value.duration) {
        await _controller.seekTo(Duration.zero);
      }
      await _PlaybackFocus.claim(this, () async {
        await _controller.pause();
      });
      await _controller.play();
    }
  }

  @override
  void dispose() {
    _PlaybackFocus.release(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Video'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.white),
                ),
              )
            : !_ready
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: _controller.value.aspectRatio,
                            child: VideoPlayer(_controller),
                          ),
                        ),
                      ),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: _controller,
                        builder: (context, value, child) {
                          final playing =
                              value.isPlaying && !value.isCompleted;
                          return TextButton.icon(
                            onPressed: _toggle,
                            icon: Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                            ),
                            label: Text(
                              playing ? 'Pause video' : 'Play video',
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                          );
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                        child: VideoProgressIndicator(
                          _controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Colors.white,
                            bufferedColor: Colors.white54,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
