import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app_theme.dart';
import 'biometric_gate.dart';
import 'profile_avatar.dart';
import 'profile_photo_service.dart';

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
  String _photoPath = '';

  DocumentReference<Map<String, dynamic>> get _profileRef =>
      FirebaseFirestore.instance.collection('profiles')
          .doc(FirebaseAuth.instance.currentUser!.uid);

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() { _loading = true; _error = null; });
    try {
      final snapshot = await _profileRef.get();
      final data = snapshot.data();
      if (!mounted) return;
      _username.text = data?['username'] ?? '';
      _displayName.text = data?['displayName'] ?? '';
      _bio.text = data?['bio'] ?? '';
      _photoPath = data?['photoUrl'] as String? ?? '';
      setState(() {
        _profileExists = snapshot.exists;
        _loading = false;
        _showQrCode = false;
      });
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() {
        _error = 'Could not load profile: ${error.code}';
        _loading = false;
      });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
        _error = 'Could not load your profile.';
        _loading = false;
      });
      }
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    String? newlyUploadedPath;
    try {
      final data = <String, dynamic>{
        'username': _username.text.trim().toLowerCase(),
        'displayName': _displayName.text.trim(),
        'bio': _bio.text.trim(),
      };

      // The upload is private. Firestore stores only the authenticated
      // Storage object path, NEVER a public download URL.
      if (_selectedImage != null) {
        newlyUploadedPath = await ProfilePhotoService.upload(_selectedImage!);
        data['photoUrl'] = newlyUploadedPath;
      }

      if (_profileExists) {
        await _profileRef.update(data);
      } else {
        await _profileRef.set({
          ...data,
          'photoUrl': newlyUploadedPath ?? '',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      final oldPath = _photoPath;
      if (!mounted) return;
      setState(() {
        _profileExists = true;
        if (newlyUploadedPath != null) {
          _photoPath = newlyUploadedPath;
          _selectedImage = null;
        }
      });

      if (newlyUploadedPath != null && oldPath.isNotEmpty &&
          oldPath != newlyUploadedPath) {
        await ProfilePhotoService.removeOwn(oldPath);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile and photo saved.')),
      );
    } catch (error) {
      // Don't leak an orphaned uploaded photo if Firestore rejects the save.
      if (newlyUploadedPath != null) {
        await ProfilePhotoService.removeOwn(newlyUploadedPath);
      }
      if (!mounted) return;
      final message = error is FirebaseException
          ? 'Could not save profile: ${error.code}'
          : error is StateError
              ? error.message.toString()
              : 'Could not upload photo. Check the Supabase profile-photos bucket and rules.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }


  Future<void> _pickImage() async {
    try {
      final image = await BiometricGate.withSystemPicker(context,
        () => ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 800,
          maxHeight: 800,
          imageQuality: 70,
          requestFullMetadata: false,
        ),
      );
      if (image != null && mounted) {
        setState(() => _selectedImage = File(image.path));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'Photo selected. Tap Save profile to upload it securely.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not select an image.')),
        );
      }
    }
  }


  void _toggleQrCode() {
    if (!_profileExists || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() => _showQrCode = !_showQrCode);
  }

  Widget _buildQrCode() {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final qrData = jsonEncode({
      'app': 'secure-messenger', 'type': 'profile',
      'version': 1, 'uid': uid,
      // Non-secret profile information makes the QR self-describing.
      // The scanner still loads the trusted profile from Firestore by UID.
      'username': _username.text.trim().toLowerCase(),
      'displayName': _displayName.text.trim(),
    });
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(21),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF25374C)),
      ),
      child: Column(children: [
        const Text('Your contact QR code', style: TextStyle(
          fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 15),
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(color: Colors.white,
            borderRadius: BorderRadius.circular(15)),
          child: QrImageView(
            data: qrData,
            version: QrVersions.auto,
            size: 205,
            backgroundColor: Colors.white,
            errorStateBuilder: (context, error) => Text(
              'QR unavailable: $error',
              style: const TextStyle(color: Colors.black)),
          ),
        ),
        const SizedBox(height: 14),
        const Text('Scan to see my username, display name and profile.',
          style: TextStyle(color: AppTheme.secondary, fontSize: 12),
          textAlign: TextAlign.center),
      ]),
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_error!),
        const SizedBox(height: 12),
        FilledButton(onPressed: _loadProfile, child: const Text('Retry')),
      ],
    ));
    }
    final display = _displayName.text.trim();
    return Center(child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(17, 8, 17, 30),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 27,
                    horizontal: 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E4D54), Color(0xFF182E46)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: Column(children: [
                  Stack(children: [
                    if (_selectedImage != null)
                      CircleAvatar(
                        radius: 45,
                        backgroundColor: AppTheme.background,
                        backgroundImage: FileImage(_selectedImage!),
                      )
                    else
                      ProfileAvatar(
                        userId: FirebaseAuth.instance.currentUser!.uid,
                        storagePath: _photoPath,
                        displayName: display,
                        radius: 45,
                      ),
                    Positioned(
                      bottom: 0, right: 0,
                      child: InkWell(
                        onTap: _pickImage,
                        child: const CircleAvatar(
                          radius: 16,
                          backgroundColor: AppTheme.accent,
                          child: Icon(Icons.edit_rounded,
                            size: 16, color: AppTheme.background)),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Text(_profileExists ? 'Your identity' : 'Create your identity',
                    style: const TextStyle(fontSize: 21,
                      fontWeight: FontWeight.w800)),
                  const SizedBox(height: 5),
                  Text(_profileExists ? '@${_username.text}' :
                      'Choose how people can find you',
                    style: const TextStyle(color: AppTheme.secondary)),
                  const SizedBox(height: 8),
                  const Text('Profile photo syncs securely when you save',
                    style: TextStyle(color: AppTheme.secondary, fontSize: 11)),
                ]),
              ),
              const SizedBox(height: 23),
              const Text('ACCOUNT DETAILS', style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w800,
                color: AppTheme.accent, letterSpacing: 1.7)),
              const SizedBox(height: 13),
              TextFormField(
                controller: _username, maxLength: 20,
                decoration: const InputDecoration(
                  labelText: 'Username', prefixText: '@',
                  prefixIcon: Icon(Icons.alternate_email_rounded)),
                validator: (value) => RegExp(r'^[a-z0-9_]{3,20}$')
                    .hasMatch((value ?? '').trim().toLowerCase())
                    ? null : 'Use 3–20 letters, numbers or _',
              ),
              const SizedBox(height: 13),
              TextFormField(
                controller: _displayName, maxLength: 50,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  prefixIcon: Icon(Icons.badge_outlined)),
                validator: (value) => (value ?? '').trim().isEmpty
                  ? 'Enter a display name' : null,
              ),
              const SizedBox(height: 13),
              TextFormField(
                controller: _bio, maxLength: 160, maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  alignLabelWithHint: true,
                  prefixIcon: Icon(Icons.edit_note_rounded)),
              ),
              const SizedBox(height: 17),
              FilledButton.icon(
                onPressed: _saving ? null : _saveProfile,
                icon: Icon(_saving ? Icons.hourglass_top_rounded
                    : Icons.check_circle_outline_rounded),
                label: Text(_saving ? 'Saving…' : 'Save profile'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _profileExists && !_saving
                    ? _toggleQrCode : null,
                icon: Icon(_showQrCode ? Icons.close_rounded
                    : Icons.qr_code_2_rounded),
                label: Text(_showQrCode ? 'Hide QR code' : 'Show my QR code'),
              ),
              if (_showQrCode && _profileExists) ...[
                const SizedBox(height: 16),
                _buildQrCode(),
              ],
            ],
          ),
        ),
      ),
    ));
  }
}
