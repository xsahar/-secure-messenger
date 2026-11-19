import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// A single connection document represents a pending request OR an accepted chat.
class ConnectionService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static String get currentUid => FirebaseAuth.instance.currentUser!.uid;

  // Both users calculate exactly the same document ID.
  static String idFor(String first, String second) {
    final ids = <String>[first, second]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  static DocumentReference<Map<String, dynamic>> refFor(
    String first,
    String second,
  ) => _db.collection('connections').doc(idFor(first, second));

  static Future<void> sendRequest(String otherUid) async {
    final me = currentUid;
    if (otherUid == me) throw StateError('You cannot add yourself.');

    final ids = <String>[me, otherUid]..sort();
    final ref = refFor(me, otherUid);

    // Create a single canonical document for this pair. If it already exists,
    // the Firestore rules deny overwriting it (including accepted chats).
    // Do not transaction.get() a missing connection: our get rules only let
    // existing members read documents.
    await ref.set(<String, dynamic>{
      'members': ids,
      'senderId': me,
      'receiverId': otherUid,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> respond(String connectionId, bool accept) async {
    await _db.collection('connections').doc(connectionId).update({
      'status': accept ? 'accepted' : 'declined',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
