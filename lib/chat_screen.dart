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
import 'biometric_gate.dart';
import 'app_theme.dart';

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
  late final Future<void> _mediaConsentReady;
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
    // A media conversation is usable only after BOTH contacts have opened
    // their accepted chat on the patched client. The server enforces this
    // with two independent Firebase-identity-bound consent records.
    _mediaConsentReady = _registerMediaConsent();
    unawaited(_mediaConsentReady.catchError((Object _) {
      // Standard text chat can remain available if Supabase is offline.
    }));
  }

  Future<void> _registerMediaConsent() async {
    final snapshot = await _connection.get();
    final data = snapshot.data();
    final members = data?['members'];

    if (data?['status'] != 'accepted' ||
        members is! List ||
        members.length != 2 ||
        !members.contains(_myUid)) {
      throw StateError('Media is available only in accepted conversations.');
    }

    // Upsert with ON CONFLICT DO NOTHING: only INSERT RLS permission is needed.
    // Neither client can submit a consent for the other Firebase account.
    await Supabase.instance.client.from('media_consents').upsert(
      <String, dynamic>{
        'connection_id': widget.connectionId,
        'uid': _myUid,
      },
      onConflict: 'connection_id,uid',
      ignoreDuplicates: true,
    );
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

    try {
      await _registerMediaConsent();
      // Server checks the other participant's consent too. Client checks
      // alone would NOT protect the private Storage bucket.
      final bothConsented = await Supabase.instance.client.rpc(
        'sm_media_pair_consented',
        params: {'p_connection_id': widget.connectionId},
      );
      if (bothConsented != true) {
        _notice('Both people must open this chat once to enable media.');
        return;
      }
    } catch (_) {
      _notice('Media permission check failed. Check Supabase setup.');
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
        picked = await BiometricGate.withSystemPicker(
          context,
          () => _picker.pickImage(
            source: ImageSource.gallery,
            imageQuality: 65,
            maxWidth: 1600,
            maxHeight: 1600,
          ),
        );
      } else {
        picked = await BiometricGate.withSystemPicker(
          context,
          () => _picker.pickVideo(source: ImageSource.gallery),
        );
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
      // On first use, Android displays its own microphone permission dialog.
      // Treat this the same as the system media picker so that the biometric
      // gate does not mistake the dialog for leaving the app.
      final microphoneAllowed = await BiometricGate.withSystemPicker(
        context,
        () => _recorder.hasPermission(),
      );
      if (!mounted) return;
      if (!microphoneAllowed) {
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
        ChatMediaContent.forgetMedia(path);
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
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _stopTyping();
      unawaited(ChatMediaContent.pauseAllMedia());
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

  String _messageTime(dynamic raw) {
    if (raw is! Timestamp) return '';
    return TimeOfDay.fromDateTime(raw.toDate()).format(context);
  }

  Widget _bubble(QueryDocumentSnapshot<Map<String, dynamic>> document) {
    final data = document.data();
    final mine = data['senderId'] == _myUid;
    final text = data['text'] as String? ?? '';
    final edited = data['editedAt'] != null;
    final seen = data['readAt'] != null;
    final media = data['mediaType'] as String?;
    final time = _messageTime(data['createdAt']);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 304),
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
        padding: EdgeInsets.fromLTRB(media == null ? 15 : 9, 10, 9, 8),
        decoration: BoxDecoration(
          color: mine ? AppTheme.mine : AppTheme.theirs,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(19),
            topRight: const Radius.circular(19),
            bottomLeft: Radius.circular(mine ? 19 : 6),
            bottomRight: Radius.circular(mine ? 6 : 19),
          ),
          border: Border.all(
            color: mine ? const Color(0xFF257D79)
                        : const Color(0xFF2B4055),
            width: 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: media != null
                      ? ChatMediaContent(
                          key: ValueKey(document.id),
                          connectionId: widget.connectionId,
                          storagePath: data['storagePath'] as String? ?? '',
                          mediaType: media,
                          consentReady: _mediaConsentReady,
                        )
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(0, 3, 0, 2),
                          child: Text(text,
                            style: const TextStyle(
                              color: AppTheme.text,
                              height: 1.4,
                              fontSize: 14)),
                        ),
                ),
                if (mine)
                  SizedBox(
                    width: 29, height: 30,
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_vert_rounded,
                        color: Colors.white70, size: 17),
                      tooltip: 'Message actions',
                      onSelected: (value) {
                        if (value == 'edit') _editMessage(document);
                        if (value == 'delete') _deleteMessage(document);
                      },
                      itemBuilder: (_) => [
                        if (media == null) const PopupMenuItem(
                          value: 'edit', child: Text('Edit message')),
                        const PopupMenuItem(
                          value: 'delete', child: Text('Delete for everyone')),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (edited) const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Text('Edited', style: TextStyle(
                      color: Colors.white60, fontSize: 10))),
                Text(time, style: const TextStyle(
                    color: Colors.white60, fontSize: 10)),
                if (mine) ...[
                  const SizedBox(width: 5),
                  Icon(seen ? Icons.done_all_rounded : Icons.done_rounded,
                    size: 14,
                    color: seen ? AppTheme.accent : Colors.white60),
                ],
              ],
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
        if (state?['typing'] != true || !recent) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.fromLTRB(17, 3, 17, 9),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(color: AppTheme.theirs,
                borderRadius: BorderRadius.circular(18)),
            child: Text('${widget.otherName} is typing…',
              style: const TextStyle(
                color: AppTheme.secondary, fontSize: 12)),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.otherName.trim().isEmpty
        ? '?' : widget.otherName.trim()[0].toUpperCase();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppTheme.mine,
              radius: 20,
              child: Text(initial, style: const TextStyle(
                color: AppTheme.accent, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 11),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.otherName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17,
                    fontWeight: FontWeight.w800)),
                const Text('Standard conversation',
                  style: TextStyle(fontSize: 11,
                    color: AppTheme.secondary)),
              ],
            )),
          ],
        ),
        actions: [
          IconButton.filledTonal(
            tooltip: 'Open encrypted secret chat',
            icon: const Icon(Icons.lock_rounded,
              color: AppTheme.accent, size: 20),
            onPressed: () {
              unawaited(ChatMediaContent.pauseAllMedia());
              Navigator.push(context,
                MaterialPageRoute<void>(
                  builder: (_) => SecretChatScreen(
                  connectionId: widget.connectionId,
                  otherName: widget.otherName)));
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(14, 7, 14, 5),
            padding: const EdgeInsets.symmetric(
              vertical: 9, horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline_rounded,
                size: 16, color: AppTheme.secondary),
              SizedBox(width: 9),
              Expanded(child: Text(
                'Standard chat is not end-to-end encrypted. Use the lock for Secret Chat.',
                style: TextStyle(fontSize: 11,
                  color: AppTheme.secondary))),
            ]),
          ),
          _otherTypingIndicator(),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _messages
                  .orderBy('createdAt', descending: true)
                  .limit(80).snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Could not load messages. Check Firestore rules.'));
                }
                if (!snapshot.hasData) {
                  return const Center(
                  child: CircularProgressIndicator());
                }
                final docs = snapshot.data!.docs;
                _queueReadReceipts(docs);
                if (docs.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mark_chat_unread_outlined,
                          size: 46, color: AppTheme.accent),
                        SizedBox(height: 16),
                        Text('Your conversation starts here',
                          style: TextStyle(fontWeight: FontWeight.w800,
                            fontSize: 17)),
                        SizedBox(height: 6),
                        Text('Send a message to say hello.',
                          style: TextStyle(color: AppTheme.secondary)),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: docs.length,
                  itemBuilder: (_, i) => _bubble(docs[i]),
                );
              },
            ),
          ),
          if (_sending) const LinearProgressIndicator(minHeight: 2),
          if (_recording)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 13),
              padding: const EdgeInsets.symmetric(
                vertical: 9, horizontal: 13),
              decoration: BoxDecoration(
                color: const Color(0xFF4C2630),
                borderRadius: BorderRadius.circular(14)),
              child: const Row(children: [
                Icon(Icons.fiber_manual_record_rounded,
                  color: Color(0xFFFF8298), size: 16),
                SizedBox(width: 8),
                Expanded(child: Text(
                  'Recording… Tap stop to send (60s max)',
                  style: TextStyle(fontSize: 12))),
              ]),
            ),
          SafeArea(
            top: false,
            child: Container(
              color: AppTheme.surface,
              padding: const EdgeInsets.fromLTRB(7, 9, 11, 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Attach photo or video',
                    enabled: !_sending && !_recording,
                    onSelected: _pickMedia,
                    icon: const Icon(Icons.add_circle_outline_rounded,
                      color: AppTheme.accent, size: 28),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'image',
                        child: ListTile(leading: Icon(Icons.image_outlined),
                          title: Text('Photo'))),
                      PopupMenuItem(value: 'video',
                        child: ListTile(leading: Icon(Icons.movie_outlined),
                          title: Text('Video · 12 MB max'))),
                    ],
                  ),
                  IconButton(
                    tooltip: _recording
                        ? 'Stop and send recording' : 'Record voice',
                    icon: Icon(_recording
                        ? Icons.stop_circle_rounded : Icons.mic_none_rounded,
                      color: _recording ? const Color(0xFFFF8298)
                          : AppTheme.accent, size: 25),
                    onPressed: _sending ? null : _toggleRecording,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _message,
                      onChanged: _onTextChanged,
                      enabled: !_recording && !_sending,
                      maxLength: 2000,
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        counterText: '',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 15, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: IconButton.filled(
                      tooltip: 'Send message',
                      onPressed: (_sending || _recording) ? null : _send,
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
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
