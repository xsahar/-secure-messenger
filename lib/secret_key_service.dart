import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_crypto.dart';

class SecretChatSession {
  const SecretChatSession({
    required this.key,
    required this.myFingerprint,
    required this.peerFingerprint,
  });

  final SecretKey key;
  final String myFingerprint;
  final String peerFingerprint;
}

/// One X25519 key per Firebase user per installation.
/// Private keys NEVER get written to Firebase; they are stored locally in
/// platform secure storage. Losing this device's key loses message access.
class SecretKeyService {
  static const _storage = FlutterSecureStorage();
  static final _database = FirebaseFirestore.instance;
  static final _x25519 = X25519();

  static Future<SecretChatSession> prepare({
    required String myUid,
    required String peerUid,
    required String connectionId,
  }) async {
    final ownRef = _database.collection('secretKeys').doc(myUid);
    final localId = 'e2ee_v1_identity_$myUid';
    final local = await _storage.read(key: localId);

    late final SimpleKeyPair ownPair;
    late final SimplePublicKey ownPublic;

    if (local == null) {
      // Never replace an existing server identity silently. This would make
      // old messages undecryptable and could enable impersonation.
      final existing = await ownRef.get();
      if (existing.exists) {
        throw StateError(
          'This account already has a secret-chat key on another installation. '
          'Key recovery/multi-device support is not implemented. '
          'Do not overwrite the key or uninstall your original app.',
        );
      }
      ownPair = await _x25519.newKeyPair();
      ownPublic = await ownPair.extractPublicKey();
      final privateBytes = await ownPair.extractPrivateKeyBytes();
      // Save locally BEFORE trying to publish. On a failed upload the same
      // key will be reused when the user taps Retry.
      await _storage.write(
        key: localId,
        value: jsonEncode({
          'private': base64Encode(privateBytes),
          'public': base64Encode(ownPublic.bytes),
        }),
      );
    } else {
      final decoded = jsonDecode(local) as Map<String, dynamic>;
      final privateBytes = base64Decode(decoded['private'] as String);
      final publicBytes = base64Decode(decoded['public'] as String);
      if (privateBytes.length != 32 || publicBytes.length != 32) {
        throw const FormatException('Invalid local encryption key');
      }
      ownPublic = SimplePublicKey(publicBytes, type: KeyPairType.x25519);
      ownPair = SimpleKeyPairData(
        privateBytes,
        publicKey: ownPublic,
        type: KeyPairType.x25519,
      );
    }

    final remoteOwn = await ownRef.get();
    final ownEncoded = base64Encode(ownPublic.bytes);
    if (!remoteOwn.exists) {
      // Firestore rules permit OWNER-ONLY creation and forbid later updates.
      await ownRef.set({
        'version': 1,
        'publicKey': ownEncoded,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else if (remoteOwn.data()?['publicKey'] != ownEncoded) {
      throw StateError(
        'The published encryption key differs from your device key. '
        'Secret chat is blocked to prevent silent key replacement.',
      );
    }

    final peerSnapshot = await _database.collection('secretKeys')
        .doc(peerUid).get();
    if (!peerSnapshot.exists) {
      throw StateError(
        'Your encryption key is ready. The other person needs to open '
        'Secret Chat once, then you can tap Retry.',
      );
    }
    if (peerSnapshot.data()?['version'] != 1) {
      throw StateError('The contact has an unsupported encryption key.');
    }
    final peerEncoded = peerSnapshot.data()?['publicKey'];
    if (peerEncoded is! String) {
      throw const FormatException('Invalid contact public key');
    }
    final peerBytes = base64Decode(peerEncoded);
    if (peerBytes.length != 32) {
      throw const FormatException('Invalid contact public key length');
    }

    // Trust on first use (TOFU): detect changes after the first successful
    // lookup. For protection against first-contact substitution, users MUST
    // compare fingerprints over an independent trusted channel.
    final pinId = 'e2ee_v1_peer_${myUid}_$peerUid';
    final pinned = await _storage.read(key: pinId);
    if (pinned != null && pinned != peerEncoded) {
      throw StateError(
        'WARNING: This contact’s encryption key has changed. '
        'Secret chat is blocked. Verify the key outside this app.',
      );
    }
    if (pinned == null) {
      await _storage.write(key: pinId, value: peerEncoded);
    }

    final peerPublic = SimplePublicKey(peerBytes, type: KeyPairType.x25519);
    final key = await SecretChatCrypto.deriveKey(
      ownKeyPair: ownPair,
      peerPublicKey: peerPublic,
      connectionId: connectionId,
    );

    return SecretChatSession(
      key: key,
      myFingerprint: await SecretChatCrypto.fingerprint(ownPublic.bytes),
      peerFingerprint: await SecretChatCrypto.fingerprint(peerBytes),
    );
  }
}
