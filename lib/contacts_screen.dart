import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_screen.dart';
import 'connection_service.dart';
import 'scan_qr_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _searchController = TextEditingController();
  Future<QuerySnapshot<Map<String, dynamic>>>? _searchResult;
  String? _busyUser;
  String? _busyConnection;

  String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)));
    }
  }

  String _errorText(Object error) {
    if (error is FirebaseException) return 'Firebase: ${error.code}';
    if (error is StateError) return error.message.toString();
    return 'Something went wrong. Please try again.';
  }

  void _search() {
    final username = _searchController.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(username)) {
      _notice('Enter an exact username (3–20 letters, numbers or _).');
      return;
    }
    setState(() {
      _searchResult = FirebaseFirestore.instance.collection('profiles')
          .where('username', isEqualTo: username).limit(10).get();
    });
  }

  Future<void> _sendRequest(String uid) async {
    if (_busyUser != null) return;
    setState(() => _busyUser = uid);
    try {
      await ConnectionService.sendRequest(uid);
      _notice('Contact request sent!');
    } catch (error) {
      _notice(_errorText(error));
    } finally {
      if (mounted) setState(() => _busyUser = null);
    }
  }

  Future<void> _respond(String id, bool accept) async {
    if (_busyConnection != null) return;
    setState(() => _busyConnection = id);
    try {
      await ConnectionService.respond(id, accept);
      _notice(accept ? 'Contact accepted!' : 'Request declined.');
    } catch (error) {
      _notice(_errorText(error));
    } finally {
      if (mounted) setState(() => _busyConnection = null);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _avatar(String name, {double radius = 24}) {
    final first = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppTheme.mine,
      child: Text(first, style: const TextStyle(color: AppTheme.accent,
        fontSize: 18, fontWeight: FontWeight.w800)),
    );
  }

  Widget _sectionHeader(String title, String subtitle) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 17,
          fontWeight: FontWeight.w800, color: AppTheme.text)),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(
          color: AppTheme.secondary, fontSize: 12)),
      ],
    ),
  );

  Widget _searchSection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 5, 16, 2),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: const Color(0xFF25374C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Find a contact', style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          const Text('Search by exact username or scan their QR code.',
              style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Username', prefixText: '@',
                    prefixIcon: Icon(Icons.alternate_email_rounded),
                    isDense: true),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Search users',
                onPressed: _search,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
              IconButton.outlined(
                tooltip: 'Scan contact QR code',
                onPressed: () => Navigator.push(context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ScanQrScreen())),
                icon: const Icon(Icons.qr_code_scanner_rounded),
              ),
            ],
          ),
          if (_searchResult != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 18),
            FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
              future: _searchResult,
              builder: (context, snapshot) {
                if (snapshot.hasError) return const Text('Search failed. Try again.');
                if (!snapshot.hasData) {
                  return const Center(
                  child: Padding(padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator()));
                }
                final users = snapshot.data!.docs
                    .where((doc) => doc.id != _myUid).toList();
                if (users.isEmpty) {
                  return const Padding(
                  padding: EdgeInsets.all(10), child: Text('No user found.'));
                }
                return Column(children: users.map((doc) {
                  final profile = doc.data();
                  final name = '${profile['displayName'] ?? 'User'}';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _avatar(name, radius: 21),
                    title: Text(name),
                    subtitle: Text('@${profile['username'] ?? ''}'),
                    trailing: FilledButton.tonal(
                      onPressed: _busyUser == null
                          ? () => _sendRequest(doc.id) : null,
                      child: const Text('Request'),
                    ),
                  );
                }).toList());
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _connectionTile(
      QueryDocumentSnapshot<Map<String, dynamic>> document) {
    final data = document.data();
    final members = List<String>.from(data['members'] as List);
    final otherUid = members.firstWhere((uid) => uid != _myUid);
    final status = data['status'] as String? ?? 'unknown';
    final incoming = data['receiverId'] == _myUid;
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('profiles')
          .doc(otherUid).get(),
      builder: (context, snapshot) {
        final profile = snapshot.data?.data();
        final name = profile?['displayName'] as String? ?? 'User';
        final username = profile?['username'] as String? ?? 'unknown';
        final accepted = status == 'accepted';
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 9),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: const Color(0xFF25374C), width: 0.7),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 13, vertical: 7),
            leading: _avatar(name),
            title: Text(name, style: const TextStyle(
                fontWeight: FontWeight.w800, fontSize: 15)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(accepted ? '@$username · Tap to open chat'
                  : status == 'pending'
                    ? (incoming ? 'Incoming contact request' : 'Request sent')
                    : 'Declined',
                style: const TextStyle(fontSize: 12,
                  color: AppTheme.secondary)),
            ),
            onTap: accepted ? () => Navigator.push(context,
              MaterialPageRoute<void>(
                builder: (_) => ChatScreen(
                  connectionId: document.id,
                  otherName: name),
              ),
            ) : null,
            trailing: status == 'pending' && incoming
              ? Wrap(spacing: 0, children: [
                IconButton(
                  tooltip: 'Accept',
                  onPressed: _busyConnection == null
                    ? () => _respond(document.id, true) : null,
                  icon: const Icon(Icons.check_circle_rounded,
                    color: AppTheme.accent)),
                IconButton(
                  tooltip: 'Decline',
                  onPressed: _busyConnection == null
                    ? () => _respond(document.id, false) : null,
                  icon: const Icon(Icons.cancel_outlined,
                    color: AppTheme.secondary)),
              ])
              : Icon(accepted ? Icons.chevron_right_rounded
                    : Icons.schedule_rounded,
                  color: AppTheme.secondary),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance.collection('connections')
        .where('members', arrayContains: _myUid).snapshots();
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _searchSection(),
        _sectionHeader('Your conversations',
          'Connected people and requests appear here.'),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: stream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Cannot load contacts. Check Firestore rules.'));
            }
            if (!snapshot.hasData) {
              return const Center(
              child: Padding(padding: EdgeInsets.all(24),
                child: CircularProgressIndicator()));
            }
            final docs = snapshot.data!.docs;
            if (docs.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(22)),
                  child: const Column(children: [
                    Icon(Icons.chat_bubble_outline_rounded,
                        color: AppTheme.accent, size: 42),
                    SizedBox(height: 12),
                    Text('No conversations yet',
                        style: TextStyle(fontSize: 17,
                            fontWeight: FontWeight.w800)),
                    SizedBox(height: 8),
                    Text('Find someone above to start chatting.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.secondary)),
                  ]),
                ),
              );
            }
            return Column(
              children: docs.map(_connectionTile).toList(),
            );
          },
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
