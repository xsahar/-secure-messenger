import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Ordinary Firestore text chat. NOT an end-to-end-encrypted secret chat.
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

class _ChatScreenState extends State<ChatScreen> {
  final _message = TextEditingController();
  bool _sending = false;

  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  CollectionReference<Map<String, dynamic>> get _messages =>
      FirebaseFirestore.instance
          .collection('connections')
          .doc(widget.connectionId)
          .collection('messages');

  void _notice(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value)),
    );
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (_sending || text.isEmpty || text.length > 2000) return;
    setState(() => _sending = true);
    try {
      await _messages.add({
        'senderId': _uid,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) _message.clear();
    } on FirebaseException catch (e) {
      _notice('Message failed: ${e.code}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _editMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) async {
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
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
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
    } on FirebaseException catch (e) {
      _notice('Edit failed: ${e.code}');
    }
  }

  Future<void> _deleteMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete for everyone?'),
        content: const Text('The message will disappear from this chat for both accounts.'),
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
    try {
      await document.reference.delete();
    } on FirebaseException catch (e) {
      _notice('Delete failed: ${e.code}');
    }
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Widget _bubble(QueryDocumentSnapshot<Map<String, dynamic>> document) {
    final data = document.data();
    final mine = data['senderId'] == _uid;
    final text = data['text'] as String? ?? '';
    final edited = data['editedAt'] != null;
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '$text${edited ? ' (edited)' : ''}',
                style: TextStyle(color: mine ? scheme.onPrimaryContainer : scheme.onSurface),
              ),
            ),
            if (mine)
              PopupMenuButton<String>(
                tooltip: 'Message actions',
                icon: const Icon(Icons.more_vert, size: 18),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete for everyone')),
                ],
                onSelected: (value) {
                  if (value == 'edit') _editMessage(document);
                  if (value == 'delete') _deleteMessage(document);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.otherName)),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              'Standard chat — NOT end-to-end encrypted yet',
              style: TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _messages
                  .orderBy('createdAt', descending: true)
                  .limit(80)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('Could not load messages. Check Firestore rules.'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snapshot.data!.docs;
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
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _message,
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
