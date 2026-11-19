import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
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
      _searchResult = FirebaseFirestore.instance
          .collection('profiles')
          .where('username', isEqualTo: username)
          .limit(10)
          .get();
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

  Widget _searchSection() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Find people', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Exact username',
                prefixText: '@',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const ScanQrScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR'),
                ),
              ],
            ),
            if (_searchResult != null) ...[
              const Divider(height: 26),
              FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
                future: _searchResult,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Text('Search failed. Check your connection.');
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final users = snapshot.data!.docs
                      .where((doc) => doc.id != _myUid)
                      .toList();
                  if (users.isEmpty) return const Text('No other user found.');
                  return Column(
                    children: users.map((doc) {
                      final profile = doc.data();
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${profile['displayName'] ?? 'User'}'),
                        subtitle: Text('@${profile['username'] ?? ''}'),
                        trailing: FilledButton(
                          onPressed: _busyUser == null
                              ? () => _sendRequest(doc.id)
                              : null,
                          child: const Text('Request'),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _connectionTile(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final members = List<String>.from(data['members'] as List);
    final otherUid = members.firstWhere((uid) => uid != _myUid);
    final status = data['status'] as String? ?? 'unknown';
    final incoming = data['receiverId'] == _myUid;

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection('profiles')
          .doc(otherUid)
          .get(),
      builder: (context, snapshot) {
        final profile = snapshot.data?.data();
        final displayName = profile?['displayName'] as String? ?? 'User';
        final username = profile?['username'] as String? ?? 'unknown';
        final label = status == 'accepted'
            ? 'Contact  ·  @$username'
            : status == 'pending'
                ? (incoming ? 'Incoming request  ·  @$username' : 'Request sent  ·  @$username')
                : 'Declined  ·  @$username';

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(displayName),
            subtitle: Text(label),
            isThreeLine: false,
            onTap: status == 'accepted'
                ? () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ChatScreen(
                          connectionId: document.id,
                          otherName: displayName,
                        ),
                      ),
                    )
                : null,
            trailing: status == 'pending' && incoming
                ? Wrap(
                    spacing: 2,
                    children: [
                      IconButton(
                        tooltip: 'Accept',
                        onPressed: _busyConnection == null
                            ? () => _respond(document.id, true)
                            : null,
                        icon: const Icon(Icons.check_circle_outline),
                      ),
                      IconButton(
                        tooltip: 'Decline',
                        onPressed: _busyConnection == null
                            ? () => _respond(document.id, false)
                            : null,
                        icon: const Icon(Icons.cancel_outlined),
                      ),
                    ],
                  )
                : status == 'accepted'
                    ? const Icon(Icons.chat_bubble_outline)
                    : null,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('connections')
        .where('members', arrayContains: _myUid)
        .snapshots();

    return ListView(
      children: [
        _searchSection(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text('Requests & contacts', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: stream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Could not load contacts (check Firestore rules).'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final docs = snapshot.data!.docs;
            if (docs.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No contacts yet. Search a username or scan a QR code.'),
              );
            }
            return Column(children: docs.map(_connectionTile).toList());
          },
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}
