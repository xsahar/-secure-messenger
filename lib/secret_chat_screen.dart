import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'secret_crypto.dart';
import 'app_theme.dart';
import 'profile_avatar.dart';

import 'package:secure_messenger/secret_key_service.dart';

/// Experimental text-only E2EE conversation, separated from standard chat.
class SecretChatScreen extends StatefulWidget {
  const SecretChatScreen({
    super.key,
    required this.connectionId,
    required this.otherName,
  });

  final String connectionId;
  final String otherName;

  @override
  State<SecretChatScreen> createState() => _SecretChatScreenState();
}

class _SecretChatScreenState extends State<SecretChatScreen> {
  final _controller = TextEditingController();
  final _decryptionCache = <String, Future<String>>{};
  SecretChatSession? _session;
  String? _peerUid;
  String? _error;
  bool _loading = true;
  bool _sending = false;

  String get _myUid => FirebaseAuth.instance.currentUser!.uid;
  CollectionReference<Map<String, dynamic>> get _messages => FirebaseFirestore
      .instance
      .collection('connections')
      .doc(widget.connectionId)
      .collection('secretMessages');

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final connection = await FirebaseFirestore.instance
          .collection('connections')
          .doc(widget.connectionId)
          .get();
      final data = connection.data();
      final members = List<String>.from(data?['members'] as List? ?? []);
      if (data?['status'] != 'accepted' ||
          members.length != 2 ||
          !members.contains(_myUid)) {
        throw StateError('Only accepted contacts can start secret chats.');
      }
      final peerUid = members.firstWhere((uid) => uid != _myUid);
      final session = await SecretKeyService.prepare(
        myUid: _myUid,
        peerUid: peerUid,
        connectionId: widget.connectionId,
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _peerUid = peerUid;
        _decryptionCache.clear();
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is StateError
            ? error.message.toString()
            : 'Cannot establish an encrypted conversation. '
                  'Check connectivity and keys, then Retry.',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _send() async {
    final message = _controller.text.trim();
    final session = _session;

    if (_sending ||
        session == null ||
        message.isEmpty ||
        message.length > 2000) {
      return;
    }

    setState(() => _sending = true);
    try {
      final envelope = await SecretChatCrypto.encrypt(
        text: message,
        key: session.key,
        connectionId: widget.connectionId,
        senderId: _myUid,
      );
      await _messages.add({
        ...envelope,
        'senderId': _myUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) _controller.clear();
    } on FirebaseException catch (error) {
      _notice('Encrypted message could not be sent: ${error.code}');
    } catch (_) {
      _notice('Encryption failed. Your message was not sent.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<String> _decrypt(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final session = _session!;
    final data = doc.data();
    try {
      return await SecretChatCrypto.decrypt(
        data: data,
        key: session.key,
        connectionId: widget.connectionId,
        senderId: data['senderId'] as String,
      );
    } catch (_) {
      return '[Unable to decrypt: invalid key or altered message]';
    }
  }

  Widget _bubble(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final mine = doc.data()['senderId'] == _myUid;
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 310),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: FutureBuilder<String>(
          future: _decryptionCache.putIfAbsent(doc.id, () => _decrypt(doc)),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Text('Decrypting…');
            }
            return Text(snapshot.data!);
          },
        ),
      ),
    );
  }

  Future<void> _showKeys() async {
    final session = _session;
    if (session == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Compare encryption keys'),
        content: SingleChildScrollView(
          child: SelectableText(
            'YOUR key fingerprint:\n${session.myFingerprint}\n\n'
            '${widget.otherName} key fingerprint:\n'
            '${session.peerFingerprint}\n\n'
            'Compare YOUR fingerprint with what your contact sees '
            'as YOUR fingerprint, using a separate trusted channel. '
            'Also compare your contact’s fingerprint with their own. '
            'Until you verify, a malicious key server could impersonate a contact.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            if (_peerUid == null)
              CircleAvatar(
                radius: 20,
                backgroundColor: AppTheme.mine,
                child: Text(widget.otherName.isEmpty
                    ? '?' : widget.otherName[0].toUpperCase(),
                    style: const TextStyle(color: AppTheme.accent,
                        fontWeight: FontWeight.w800)),
              )
            else
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('profiles').doc(_peerUid!).snapshots(),
                builder: (context, snapshot) {
                  final path = snapshot.data?.data()?['photoUrl'] as String? ?? '';
                  return ProfileAvatar(
                    userId: _peerUid!,
                    storagePath: path,
                    displayName: widget.otherName,
                    radius: 20,
                  );
                },
              ),
            const SizedBox(width: 11),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.otherName, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17,
                        fontWeight: FontWeight.w800)),
                const Text('Secret Â· Encrypted text',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11,
                        color: AppTheme.secondary)),
              ],
            )),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'About Secret Chat encryption',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('About Secret Chat'),
                content: const Text(
                  'Secret Chat encrypts text on your device before upload. '
                  'Compare encryption key fingerprints using the shield icon. '
                  'This experimental version does not provide forward '
                  'secrecy or multi-device key recovery.'),
                actions: [TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Close'),
                )],
              ),
            ),
          ),
          if (_session != null)
            IconButton(
              tooltip: 'Compare encryption keys',
              icon: const Icon(Icons.verified_user_outlined),
              onPressed: _showKeys,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: _prepare,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [

                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _messages
                        .orderBy('createdAt', descending: true)
                        .limit(80)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const Center(
                          child: Text(
                            'Cannot load secret messages. '
                            'Check Firestore rules.',
                          ),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final docs = snapshot.data!.docs;
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text('Start an encrypted conversation.'),
                        );
                      }
                      return ListView.builder(
                        reverse: true,
                        itemCount: docs.length,
                        itemBuilder: (context, i) => _bubble(docs[i]),
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            maxLength: 2000,
                            minLines: 1,
                            maxLines: null,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            decoration: const InputDecoration(
                              hintText: 'Encrypted message',
                              border: OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                        ),
                        IconButton.filled(
                          tooltip: 'Send encrypted message',
                          onPressed: _sending ? null : _send,
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
