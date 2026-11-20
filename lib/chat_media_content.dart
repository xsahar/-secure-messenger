import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Loads files from PRIVATE Supabase Storage using Firebase ID tokens.
/// Never writes public or signed URLs into Firestore.
/// Standard-chat media is not end-to-end encrypted.
class ChatMediaContent extends StatefulWidget {
  const ChatMediaContent({
    super.key,
    required this.connectionId,
    required this.storagePath,
    required this.mediaType,
  });

  final String connectionId;
  final String storagePath;
  final String mediaType; // image, video, audio

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
    if (widget.mediaType == 'image') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
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
      final bytes = await Supabase.instance.client.storage
          .from('chat-media')
          .download(widget.storagePath);
      if (bytes.isEmpty || bytes.length > _limit) {
        throw StateError('Media missing or larger than the allowed size.');
      }
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
        if (!mounted) return;
        if (widget.mediaType == 'video') {
          final controller = VideoPlayerController.file(pending);
          await controller.initialize();
          if (!mounted) {
            await controller.dispose();
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
            return;
          }
          setState(() {
            _audio = player;
            _localFile = pending;
          });
          player.playerStateStream.listen((state) {
            if (!mounted) return;
            if (state.processingState == ProcessingState.completed) {
              unawaited(player.seek(Duration.zero));
              setState(() => _playing = false);
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
    final file = _localFile;
    final inlinePlayer = _video;
    if (file == null || inlinePlayer == null || !mounted) return;

    // Stop inline playback while the full-screen player is shown.
    await inlinePlayer.pause();
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _FullScreenVideoPage(filePath: file.path),
      ),
    );
  }

  Future<void> _toggleVideo() async {
    final controller = _video;
    if (controller == null) return;
    if (controller.value.isPlaying && !controller.value.isCompleted) {
      await controller.pause();
    } else {
      if (controller.value.isCompleted ||
          controller.value.position >= controller.value.duration) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
  }

  Future<void> _toggleAudio() async {
    final player = _audio;
    if (player == null) return;
    try {
      if (player.playing) {
        await player.pause();
        if (mounted) setState(() => _playing = false);
      } else {
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
    final image = _image;
    final video = _video;
    final audio = _audio;
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    if (_busy) {
      return const SizedBox(
        height: 70,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.mediaType == 'image' && image != null) {
      return Semantics(
        button: true,
        label: 'Open photo full screen',
        child: InkWell(
          onTap: _openImage,
          borderRadius: BorderRadius.circular(10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                Image.memory(
                  image,
                  width: 166,
                  height: 150,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Text('Unable to display image'),
                ),
                const Positioned(
                  right: 6,
                  top: 6,
                  child: Icon(
                    Icons.fullscreen,
                    color: Colors.white,
                    shadows: [
                      Shadow(color: Colors.black87, blurRadius: 7),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (widget.mediaType == 'video' && video != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: 'Open video full screen',
            child: InkWell(
              onTap: _openVideo,
              borderRadius: BorderRadius.circular(10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: [
                    SizedBox(
                      width: 175,
                      height: 125,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: video.value.size.width,
                          height: video.value.size.height,
                          child: VideoPlayer(video),
                        ),
                      ),
                    ),
                    const Positioned(
                      top: 5,
                      right: 5,
                      child: Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        shadows: [
                          Shadow(color: Colors.black87, blurRadius: 7),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: video,
            builder: (context, value, child) {
              final isPlaying = value.isPlaying && !value.isCompleted;
              return TextButton.icon(
                onPressed: _toggleVideo,
                icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                label: Text(isPlaying ? 'Pause video' : 'Play video'),
              );
            },
          ),
        ],
      );
    }
    if (widget.mediaType == 'audio' && audio != null) {
      return TextButton.icon(
        onPressed: _toggleAudio,
        icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
        label: Text(_playing ? 'Pause voice message' : 'Play voice message'),
      );
    }
    return TextButton.icon(
      onPressed: _load,
      icon: Icon(switch (widget.mediaType) {
        'video' => Icons.videocam_outlined,
        'audio' => Icons.mic_outlined,
        _ => Icons.image_outlined,
      }),
      label: Text(switch (widget.mediaType) {
        'video' => 'Load video',
        'audio' => 'Load voice message',
        _ => 'Load image',
      }),
    );
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
      if (mounted) {
        setState(() => _ready = true);
      }
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
      await _controller.play();
    }
  }

  @override
  void dispose() {
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
