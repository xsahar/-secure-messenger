import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'secret_chat_screen.dart';
import 'chat_media_content.dart';

/// Standard Firestore chat. Messages are NOT end-to-end encrypted.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.connectionId,
    required this.otherName,
  });

  final String connectionId;
  final String otherName;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver {
  final _message = TextEditingController();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  Timer? _recordLimitTimer;
  bool _recording = false;
  final _readUpdateQueued = <String>{};

  late final String _myUid;
  String? _otherUid;
  Timer? _typingTimer;
  bool _typing = false;
  bool _sending = false;

  DocumentReference<Map<String, dynamic>> get _connection =>
      FirebaseFirestore.instance
          .collection('connections')
          .doc(widget.connectionId);

  CollectionReference<Map<String, dynamic>> get _messages =>
      _connection.collection('messages');

  DocumentReference<Map<String, dynamic>> get _myTyping =>
      _connection.collection('typing').doc(_myUid);

  @override
  void initState() {
    super.initState();
    _myUid = FirebaseAuth.instance.currentUser!.uid;
    WidgetsBinding.instance.addObserver(this);
    _loadOtherUid();
  }

  Future<void> _loadOtherUid() async {
    try {
      final connection = await _connection.get();
      final members = List<String>.from(
        connection.data()?['members'] as List? ?? [],
      );
      if (!mounted) return;
      setState(() {
        for (final uid in members) {
          if (uid != _myUid) {
            _otherUid = uid;
            break;
          }
        }
      });
    } on FirebaseException catch (error) {
      _notice('Cannot load contact: ${error.code}');
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // Small, short-lived Firestore document for the typing indicator.
  Future<void> _writeTyping(bool value) async {
    try {
      await _myTyping.set({
        'typing': value,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      // A stale indicator is not worth crashing the conversation.
      if (mounted) _notice('Typing status: ${error.code}');
    }
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    if (!_typing) return;
    _typing = false;
    unawaited(_writeTyping(false));
  }

  void _onTextChanged(String text) {
    if (text.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (!_typing) {
      _typing = true;
      unawaited(_writeTyping(true));
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), _stopTyping);
  }

  // Mark incoming, loaded messages as read, at most once per chat visit.
  // This is a basic audit implementation; more advanced applications track
  // a visible-range/read cursor to reduce writes for large conversations.
  void _queueReadReceipts(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final unread = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final doc in docs) {
      final data = doc.data();
      if (data['senderId'] != _myUid &&
          data['readAt'] == null &&
          _readUpdateQueued.add(doc.id)) {
        unread.add(doc);
      }
      if (unread.length == 20) break;
    }
    if (unread.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final doc in unread) {
        unawaited(_markRead(doc.reference));
      }
    });
  }

  Future<void> _markRead(
    DocumentReference<Map<String, dynamic>> reference,
  ) async {
    try {
      await reference.update({
        'readAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      _notice('Read receipt failed: ${error.code}');
    }
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (_sending || text.isEmpty || text.length > 2000) return;
    setState(() => _sending = true);
    try {
      await _messages.add({
        'senderId': _myUid,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        _message.clear();
        _stopTyping();
      }
    } on FirebaseException catch (error) {
      _notice('Message failed: ${error.code}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Sends a standard (not E2EE) image, video or voice message.
  /// Files are stored in PRIVATE Supabase Storage and metadata in Firestore.
  Future<void> _sendMediaFile(File file, String mediaType) async {
    if (_sending) return;
    final maxBytes = switch (mediaType) {
      'image' => 3 * 1024 * 1024,
      'video' => 12 * 1024 * 1024,
      'audio' => 2 * 1024 * 1024,
      _ => 0,
    };
    final bytes = await file.length();
    if (maxBytes == 0 || bytes == 0 || bytes > maxBytes) {
      _notice('File too large or unsupported. Max: image 3 MB, '
          'video 12 MB, voice 2 MB.');
      return;
    }
    final ext = file.path.split('.').last.toLowerCase();
    final contentType = switch (mediaType) {
      'image' => switch (ext) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => '',
        },
      'video' => switch (ext) {
          'mp4' => 'video/mp4',
          'mov' => 'video/quicktime',
          _ => '',
        },
      'audio' => ext == 'm4a' ? 'audio/mp4' : '',
      _ => '',
    };
    if (contentType.isEmpty) {
      _notice('Unsupported file format: .$ext');
      return;
    }

    setState(() => _sending = true);
    final docRef = _messages.doc();
    final storagePath =
        'connections/${widget.connectionId}/$_myUid/${docRef.id}.$ext';
    final mediaStore = Supabase.instance.client.storage.from('chat-media');
    var uploaded = false;
    try {
      await mediaStore.upload(
        storagePath,
        file,
        fileOptions: FileOptions(contentType: contentType, upsert: false),
      );
      uploaded = true;
      await docRef.set({
        'senderId': _myUid,
        'mediaType': mediaType,
        'storagePath': storagePath,
        'mediaSize': bytes,
        'contentType': contentType,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) _stopTyping();
    } on StorageException catch (error) {
      _notice('Supabase upload failed: ${error.message}. Check the private bucket/policies.');
      if (uploaded) {
        try { await mediaStore.remove([storagePath]); } catch (_) {}
      }
    } on FirebaseException catch (error) {
      _notice('Message metadata failed (${error.code}).');
      if (uploaded) {
        try { await mediaStore.remove([storagePath]); } catch (_) {}
      }
    } catch (error) {
      _notice('Could not send media: $error');
      if (uploaded) {
        try { await mediaStore.remove([storagePath]); } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickMedia(String type) async {
    if (_sending || _recording) return;
    try {
      final XFile? picked;
      if (type == 'image') {
        picked = await _picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 65,
          maxWidth: 1600,
          maxHeight: 1600,
        );
      } else {
        picked = await _picker.pickVideo(source: ImageSource.gallery);
      }
      if (picked == null || !mounted) return;
      await _sendMediaFile(File(picked.path), type);
    } catch (_) {
      _notice('Unable to select media. Check device permissions.');
    }
  }

  /// First tap starts recording; next tap stops and uploads (up to 60 s).
  Future<void> _toggleRecording() async {
    if (_sending) return;
    if (_recording) {
      _recordLimitTimer?.cancel();
      setState(() => _recording = false);
      try {
        final path = await _recorder.stop();
        if (path != null && path.isNotEmpty) {
          await _sendMediaFile(File(path), 'audio');
          try { await File(path).delete(); } catch (_) {}
        }
      } catch (_) {
        _notice('Unable to finish voice recording.');
      }
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        _notice('Microphone access is required for voice messages.');
        return;
      }
      final temp = await getTemporaryDirectory();
      final path =
          '${temp.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      if (!mounted) {
        await _recorder.stop();
        return;
      }
      setState(() => _recording = true);
      _recordLimitTimer = Timer(const Duration(seconds: 60), () {
        if (mounted && _recording) unawaited(_toggleRecording());
      });
    } catch (_) {
      _notice('Unable to start microphone recording.');
    }
  }

  Future<void> _editMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) async {
    if (!document.data().containsKey('text')) return;
    var draft = document.data()['text'] as String? ?? '';
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit message'),
        content: TextFormField(
          initialValue: draft,
          onChanged: (value) => draft = value,
          maxLength: 2000,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (edited == null || edited.isEmpty || edited.length > 2000) return;
    try {
      await document.reference.update({
        'text': edited,
        'editedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      _notice('Edit failed: ${error.code}');
    }
  }

  Future<void> _deleteMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete for everyone?'),
        content: const Text(
          'The message will disappear from this chat for both accounts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final path = document.data()['storagePath'] as String?;
    try {
      await document.reference.delete();
      if (path != null && path.startsWith('connections/${widget.connectionId}/$_myUid/')) {
        try {
          await Supabase.instance.client.storage
              .from('chat-media')
              .remove([path]);
        } catch (_) {
          _notice('Message removed, but the uploaded file cleanup failed.');
        }
      }
    } on FirebaseException catch (error) {
      _notice('Delete failed: ${error.code}');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _stopTyping();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTyping();
    _typingTimer?.cancel();
    _recordLimitTimer?.cancel();
    if (_recording) {
      unawaited(() async {
        try { await _recorder.stop(); } catch (_) {}
        await _recorder.dispose();
      }());
    } else {
      unawaited(_recorder.dispose());
    }
    _message.dispose();
    super.dispose();
  }

  Widget _bubble(QueryDocumentSnapshot<Map<String, dynamic>> document) {
    final data = document.data();
    final mine = data['senderId'] == _myUid;
    final text = data['text'] as String? ?? '';
    final edited = data['editedAt'] != null;
    final seen = data['readAt'] != null;
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: data['mediaType'] is String
                      ? ChatMediaContent(
                          key: ValueKey(document.id),
                          connectionId: widget.connectionId,
                          storagePath: data['storagePath'] as String? ?? '',
                          mediaType: data['mediaType'] as String,
                        )
                      : Text(
                          '$text${edited ? ' (edited)' : ''}',
                          style: TextStyle(
                            color: mine
                                ? scheme.onPrimaryContainer
                                : scheme.onSurface,
                          ),
                        ),
                ),
                if (mine)
                  PopupMenuButton<String>(
                    tooltip: 'Message actions',
                    icon: const Icon(Icons.more_vert, size: 18),
                    itemBuilder: (_) => [
                      if (data['mediaType'] == null)
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete for everyone'),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'edit') _editMessage(document);
                      if (value == 'delete') _deleteMessage(document);
                    },
                  ),
              ],
            ),
            if (mine)
              Text(
                seen ? 'Seen' : 'Sent',
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _otherTypingIndicator() {
    final otherUid = _otherUid;
    if (otherUid == null) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _connection.collection('typing').doc(otherUid).snapshots(),
      builder: (context, snapshot) {
        final state = snapshot.data?.data();
        final updated = state?['updatedAt'];
        final recent = updated is Timestamp &&
            DateTime.now().difference(updated.toDate()).inSeconds < 10;
        final typing = state?['typing'] == true && recent;
        if (!typing) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '${widget.otherName} is typing…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.otherName),
        actions: [
          IconButton(
            tooltip: 'Open encrypted secret chat',
            icon: const Icon(Icons.lock_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SecretChatScreen(
                    connectionId: widget.connectionId,
                    otherName: widget.otherName,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              'Standard chat — NOT end-to-end encrypted yet',
              style: TextStyle(fontSize: 12),
            ),
          ),
          _otherTypingIndicator(),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _messages
                  .orderBy('createdAt', descending: true)
                  .limit(80)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Could not load messages. Check Firestore rules.'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snapshot.data!.docs;
                _queueReadReceipts(docs);
                if (docs.isEmpty) {
                  return const Center(child: Text('Say hello!'));
                }
                return ListView.builder(
                  reverse: true,
                  itemCount: docs.length,
                  itemBuilder: (_, i) => _bubble(docs[i]),
                );
              },
            ),
          ),
          if (_sending) const LinearProgressIndicator(),
          if (_recording)
            const Padding(
              padding: EdgeInsets.all(6),
              child: Text('Recording voice message… Tap microphone to send (max 60s).'),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Row(
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Attach image or video',
                    enabled: !_sending && !_recording,
                    icon: const Icon(Icons.attach_file),
                    onSelected: _pickMedia,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'image', child: Text('Photo')),
                      PopupMenuItem(value: 'video', child: Text('Video (max 12 MB)')),
                    ],
                  ),
                  IconButton(
                    tooltip: _recording ? 'Stop and send recording' : 'Record voice',
                    icon: Icon(_recording ? Icons.stop_circle : Icons.mic),
                    onPressed: _sending ? null : _toggleRecording,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _message,
                      onChanged: _onTextChanged,
                      enabled: !_recording && !_sending,
                      maxLength: 2000,
                      maxLines: null,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Type a message',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                  ),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: (_sending || _recording) ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
