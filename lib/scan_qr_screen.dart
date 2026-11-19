
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _handleScan(String rawValue) async {
    if (_processing) return;
    _processing = true;

    bool cameraStopped = false;

    try {
      // Check that the QR belongs to Secure Messenger.
      if (rawValue.length > 512) {
        _showMessage('Invalid QR code.');
        return;
      }

      final decoded = jsonDecode(rawValue);

      if (decoded is! Map<String, dynamic> ||
          decoded['app'] != 'secure-messenger' ||
          decoded['type'] != 'profile' ||
          decoded['version'] != 1) {
        _showMessage('This is not a Secure Messenger profile QR.');
        return;
      }

      final uid = decoded['uid'];

      if (uid is! String ||
          uid.isEmpty ||
          uid.length > 128 ||
          uid.contains('/')) {
        _showMessage('Invalid profile identifier.');
        return;
      }

      // Pause scanning while looking up the profile.
      await _controller.stop();
      cameraStopped = true;

      // Never trust a name written inside a QR code.
      // Retrieve the real profile from Firestore using its UID.
      final snapshot = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(uid)
          .get();

      if (!mounted) return;

      if (!snapshot.exists) {
        _showMessage('Profile not found.');
        return;
      }

      final profile = snapshot.data()!;

      final username = profile['username'] as String? ?? '';
      final displayName =
          profile['displayName'] as String? ?? '';
      final bio = profile['bio'] as String? ?? '';

      final isMyProfile =
          FirebaseAuth.instance.currentUser?.uid == uid;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(
              isMyProfile ? 'Your Profile' : 'Profile Found',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CircleAvatar(
                  radius: 32,
                  child: Icon(Icons.person, size: 32),
                ),
                const SizedBox(height: 16),
                Text(
                  displayName,
                  style: Theme.of(dialogContext)
                      .textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text('@$username'),
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(bio),
                ],
                if (isMyProfile) ...[
                  const SizedBox(height: 12),
                  const Text('This is your own account.'),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } on FormatException {
      _showMessage('Invalid QR code format.');
    } on FirebaseException catch (e) {
      _showMessage('Could not load profile: ${e.code}');
    } catch (_) {
      _showMessage('Could not scan this profile.');
    } finally {
      if (mounted && cameraStopped) {
        try {
          await _controller.start();
        } catch (_) {
          _showMessage('Could not restart the camera.');
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
      appBar: AppBar(
        title: const Text('Scan QR Code'),
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                for (final barcode in capture.barcodes) {
                  final value = barcode.rawValue;

                  if (value != null) {
                    _handleScan(value);
                    break;
                  }
                }
              },
              errorBuilder: (context, error) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Camera unavailable: ${error.errorCode.name}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Point your camera at a Secure Messenger QR code.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
