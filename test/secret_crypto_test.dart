import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:secure_messenger/secret_crypto.dart';


void main() {
  test('two accounts derive the same key and decrypt ciphertext', () async {
    final x25519 = X25519();
    final alice = await x25519.newKeyPair();
    final bob = await x25519.newKeyPair();
    final alicePub = await alice.extractPublicKey();
    final bobPub = await bob.extractPublicKey();
    final aliceKey = await SecretChatCrypto.deriveKey(
      ownKeyPair: alice,
      peerPublicKey: bobPub,
      connectionId: 'alice_bob',
    );
    final bobKey = await SecretChatCrypto.deriveKey(
      ownKeyPair: bob,
      peerPublicKey: alicePub,
      connectionId: 'alice_bob',
    );
    const plaintext = 'hello private world 🗝️';
    final encrypted = await SecretChatCrypto.encrypt(
      text: plaintext,
      key: aliceKey,
      connectionId: 'alice_bob',
      senderId: 'alice',
    );
    expect(encrypted.containsKey('text'), isFalse);
    expect(encrypted['ciphertext'], isNot(contains(plaintext)));
    final decrypted = await SecretChatCrypto.decrypt(
      data: encrypted,
      key: bobKey,
      connectionId: 'alice_bob',
      senderId: 'alice',
    );
    expect(decrypted, plaintext);
  });

  test('tampering and mismatched conversation are rejected', () async {
    final x25519 = X25519();
    final alice = await x25519.newKeyPair();
    final bob = await x25519.newKeyPair();
    final bobPub = await bob.extractPublicKey();
    final key = await SecretChatCrypto.deriveKey(
      ownKeyPair: alice,
      peerPublicKey: bobPub,
      connectionId: 'a_b',
    );
    final encrypted = await SecretChatCrypto.encrypt(
      text: 'confidential',
      key: key,
      connectionId: 'a_b',
      senderId: 'a',
    );
    expect(
      () => SecretChatCrypto.decrypt(
        data: encrypted,
        key: key,
        connectionId: 'different-chat',
        senderId: 'a',
      ),
      throwsA(isA<Exception>()),
    );
    encrypted['mac'] = 'AAAAAAAAAAAAAAAAAAAAAA==';
    expect(
      () => SecretChatCrypto.decrypt(
        data: encrypted,
        key: key,
        connectionId: 'a_b',
        senderId: 'a',
      ),
      throwsA(isA<Exception>()),
    );
  });
}
