import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Experimental one-to-one text encryption primitives.
/// This is NOT a Signal/double-ratchet protocol: there is no forward secrecy.
class SecretChatCrypto {
  static final _agreement = X25519();
  static final _cipher = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<SecretKey> deriveKey({
    required SimpleKeyPair ownKeyPair,
    required SimplePublicKey peerPublicKey,
    required String connectionId,
  }) async {
    final shared = await _agreement.sharedSecretKey(
      keyPair: ownKeyPair,
      remotePublicKey: peerPublicKey,
    );
    // Bind the derived key to THIS conversation, not just the user pair.
    return _hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode('secure-messenger/secret-text/v1/$connectionId'),
    );
  }

  static Future<Map<String, dynamic>> encrypt({
    required String text,
    required SecretKey key,
    required String connectionId,
    required String senderId,
  }) async {
    final box = await _cipher.encrypt(
      utf8.encode(text),
      secretKey: key,
      aad: utf8.encode('secret-text/v1/$connectionId/$senderId'),
    );
    return {
      'version': 1,
      'ciphertext': base64Encode(box.cipherText),
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  static Future<String> decrypt({
    required Map<String, dynamic> data,
    required SecretKey key,
    required String connectionId,
    required String senderId,
  }) async {
    if (data['version'] != 1) {
      throw const FormatException('Unsupported encrypted message version');
    }
    final box = SecretBox(
      base64Decode(data['ciphertext'] as String),
      nonce: base64Decode(data['nonce'] as String),
      mac: Mac(base64Decode(data['mac'] as String)),
    );
    final clear = await _cipher.decrypt(
      box,
      secretKey: key,
      aad: utf8.encode('secret-text/v1/$connectionId/$senderId'),
    );
    return utf8.decode(clear);
  }

  static Future<String> fingerprint(List<int> publicBytes) async {
    final hash = await Sha256().hash(publicBytes);
    final bytes = hash.bytes;
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join().toUpperCase();
  }
}
