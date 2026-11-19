import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'scan_qr_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _bio = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _profileExists = false;
  bool _showQrCode = false;

  String? _error;
  File? _selectedImage;

  // Reference to the signed-in user's Firestore profile.
  DocumentReference<Map<String, dynamic>> get _profileRef {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return FirebaseFirestore.instance.collection('profiles').doc(uid);
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  // Load an existing profile from Firestore.
  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final snapshot = await _profileRef.get();
      final data = snapshot.data();

      if (!mounted) return;

      _username.text = data?['username'] ?? '';
      _displayName.text = data?['displayName'] ?? '';
      _bio.text = data?['bio'] ?? '';

      setState(() {
        _profileExists = snapshot.exists;
        _loading = false;
        _showQrCode = false;
      });
    } on FirebaseException catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not load profile: ${e.code}';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not load your profile.';
        _loading = false;
      });
    }
  }

  // Create or update the user's profile.
  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();

    setState(() => _saving = true);

    final data = <String, dynamic>{
      'username': _username.text.trim().toLowerCase(),
      'displayName': _displayName.text.trim(),
      'bio': _bio.text.trim(),
    };

    try {
      if (_profileExists) {
        await _profileRef.update(data);
      } else {
        await _profileRef.set({
          ...data,
          'photoUrl': '',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (!mounted) return;

      setState(() {
        _profileExists = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved successfully!')),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save profile: ${e.code}')),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to save your profile.')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  // Select a profile picture from the phone's gallery.
  Future<void> _pickImage() async {
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 80,
        requestFullMetadata: false,
      );

      if (image == null || !mounted) return;

      setState(() {
        _selectedImage = File(image.path);
      });
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not select an image.')),
      );
    }
  }

  // Show or hide the QR code directly on the screen.
  void _toggleQrCode() {
    if (!_profileExists || _saving) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _showQrCode = !_showQrCode;
    });
  }

  // Build a QR code that identifies the current user.
  Widget _buildQrCode() {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    final qrData = jsonEncode({
      'app': 'secure-messenger',
      'type': 'profile',
      'version': 1,
      'uid': uid,
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 24),

        Text(
          'My Profile QR Code',
          style: Theme.of(context).textTheme.titleLarge,
        ),

        const SizedBox(height: 16),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SizedBox(
            width: 230,
            height: 230,
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 230,
              backgroundColor: Colors.white,
              errorStateBuilder: (context, error) {
                return Center(
                  child: Text(
                    'QR error: $error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black),
                  ),
                );
              },
            ),
          ),
        ),

        const SizedBox(height: 12),

        const Text(
          'Scan this code to find my profile',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _bio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Loading screen.
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Error screen with retry button.
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadProfile, child: const Text('Retry')),
          ],
        ),
      );
    }

    // Main profile screen.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Profile picture.
                GestureDetector(
                  onTap: _pickImage,
                  child: CircleAvatar(
                    radius: 45,
                    backgroundImage: _selectedImage != null
                        ? FileImage(_selectedImage!)
                        : null,
                    child: _selectedImage == null
                        ? const Icon(Icons.add_a_photo, size: 36)
                        : null,
                  ),
                ),

                const SizedBox(height: 8),

                const Text('Tap to choose a profile picture'),

                const SizedBox(height: 12),

                // Screen title.
                Text(
                  _profileExists ? 'Edit Profile' : 'Create Profile',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),

                const SizedBox(height: 24),

                // Username.
                TextFormField(
                  controller: _username,
                  maxLength: 20,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixText: '@',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final username = (value ?? '').trim().toLowerCase();

                    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(username)) {
                      return 'Use 3-20 letters, numbers or _';
                    }

                    return null;
                  },
                ),

                const SizedBox(height: 16),

                // Display name.
                TextFormField(
                  controller: _displayName,
                  maxLength: 50,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final name = (value ?? '').trim();

                    if (name.isEmpty) {
                      return 'Enter a display name';
                    }

                    return null;
                  },
                ),

                const SizedBox(height: 16),

                // Bio.
                TextFormField(
                  controller: _bio,
                  maxLength: 160,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Bio',
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 24),

                // Save profile.
                FilledButton.icon(
                  onPressed: _saving ? null : _saveProfile,
                  icon: const Icon(Icons.save),
                  label: Text(_saving ? 'Saving...' : 'Save Profile'),
                ),

                const SizedBox(height: 12),

                // Show or hide QR code.
                OutlinedButton.icon(
                  onPressed: _profileExists && !_saving ? _toggleQrCode : null,
                  icon: Icon(_showQrCode ? Icons.close : Icons.qr_code_2),
                  label: Text(_showQrCode ? 'Hide QR Code' : 'My QR Code'),
                ),

                const SizedBox(height: 12),

                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const ScanQrScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR Code'),
                ),

                // QR code appears below the button.
                if (_showQrCode && _profileExists) _buildQrCode(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
