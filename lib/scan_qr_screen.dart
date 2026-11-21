import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'connection_service.dart';
import 'profile_avatar.dart';

class ScanQrScreen extends StatefulWidget {
  const ScanQrScreen({super.key});

  @override
  State<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends State<ScanQrScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _processing = false;
  bool _requesting = false;

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _requestContact(String uid, BuildContext dialogContext) async {
    if (_requesting) return;
    _requesting = true;
    try {
      await ConnectionService.sendRequest(uid);
      if (dialogContext.mounted) Navigator.pop(dialogContext);
      _notice('Contact request sent!');
    } on StateError catch (error) {
      _notice(error.message.toString());
    } on FirebaseException catch (error) {
      _notice('Request failed: ${error.code}');
    } finally {
      _requesting = false;
    }
  }

  Future<void> _handleScan(String rawValue) async {
    if (_processing) return;
    _processing = true;
    var stopped = false;

    try {
      if (rawValue.length > 512) {
        _notice('Invalid QR code.');
        return;
      }

      final decoded = jsonDecode(rawValue);
      if (decoded is! Map<String, dynamic> ||
          decoded['app'] != 'secure-messenger' ||
          decoded['type'] != 'profile' ||
          decoded['version'] != 1) {
        _notice('Not a Secure Messenger profile code.');
        return;
      }

      final uid = decoded['uid'];
      if (uid is! String ||
          uid.isEmpty ||
          uid.length > 128 ||
          uid.contains('/')) {
        _notice('Invalid profile identifier.');
        return;
      }

      await _controller.stop();
      stopped = true;
      final snapshot = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(uid)
          .get();

      if (!mounted) return;
      if (!snapshot.exists) {
        _notice('Profile not found.');
        return;
      }

      final data = snapshot.data()!;
      final name = data['displayName'] as String? ?? 'User';
      final username = data['username'] as String? ?? '';
      final bio = data['bio'] as String? ?? '';
      final isMine = FirebaseAuth.instance.currentUser?.uid == uid;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(isMine ? 'Your Profile' : 'Profile Found'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ProfileAvatar(
                  userId: uid,
                  storagePath: data['photoUrl'] as String? ?? '',
                  displayName: name,
                  radius: 30,
                ),
                const SizedBox(height: 12),
                Text(name, style: Theme.of(dialogContext).textTheme.titleLarge),
                Text('@$username'),
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(bio),
                ],
                if (isMine) ...[
                  const SizedBox(height: 8),
                  const Text('This is your own account.'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            if (!isMine)
              FilledButton.icon(
                onPressed: () => _requestContact(uid, dialogContext),
                icon: const Icon(Icons.person_add),
                label: const Text('Send Request'),
              ),
          ],
        ),
      );
    } on FormatException {
      _notice('Invalid QR format.');
    } on FirebaseException catch (error) {
      _notice('Could not load profile: ${error.code}');
    } catch (_) {
      _notice('Could not scan this profile.');
    } finally {
      if (mounted && stopped) {
        try {
          await _controller.start();
        } catch (_) {
          _notice('Could not restart the camera.');
        }
      }
      _processing = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                for (final barcode in capture.barcodes) {
                  if (barcode.rawValue != null) {
                    _handleScan(barcode.rawValue!);
                    break;
                  }
                }
              },
              errorBuilder: (context, error) => Center(
                child: Text('Camera unavailable: ${error.errorCode.name}'),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Scan a Secure Messenger profile QR code.'),
          ),
        ],
      ),
    );
  }
}
