import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

class InventoryRepository {
  InventoryRepository({FirebaseFirestore? firestore, FirebaseStorage? storage})
      : _db = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;

  Future<DocumentReference<Map<String, dynamic>>> startOrContinueCount({
    required String branchId,
    required String userId,
  }) async {
    final query = await _db
        .collection('stock_count_sessions')
        .where('branchId', isEqualTo: branchId)
        .where('createdBy', isEqualTo: userId)
        .where('status', isEqualTo: 'draft')
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) return query.docs.first.reference;

    final ref = _db.collection('stock_count_sessions').doc();
    final now = DateTime.now();
    final code =
        'CNT-${now.year.toString().substring(2)}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';

    await ref.set({
      'code': code,
      'branchId': branchId,
      'createdBy': userId,
      'status': 'draft',
      'createdAt': FieldValue.serverTimestamp(),
      'localCreatedAt': Timestamp.fromDate(now),
      'finalizedAt': null,
    });
    return ref;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchRecentSessions(String branchId) {
    return _db
        .collection('stock_count_sessions')
        .where('branchId', isEqualTo: branchId)
        .orderBy('localCreatedAt', descending: true)
        .limit(20)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchItems(String sessionId) {
    return _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .orderBy('localCreatedAt', descending: true)
        .snapshots();
  }

  Future<void> saveCountItem({
    required String sessionId,
    required String clientEntryId,
    required String tempCode,
    required int quantity,
    required String userId,
    required DateTime localCreatedAt,
    String? suggestedName,
    String? rawOcr,
  }) async {
    await _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(clientEntryId)
        .set({
      'clientEntryId': clientEntryId,
      'tempCode': tempCode,
      'quantity': quantity,
      'suggestedName': suggestedName,
      'rawOcr': rawOcr,
      'createdBy': userId,
      'localCreatedAt': Timestamp.fromDate(localCreatedAt),
      'createdAt': FieldValue.serverTimestamp(),
      'photoUrl': null,
      'photoStoragePath': null,
      'photoState': 'pending',
      'nameState': suggestedName == null ? 'needs_review' : 'auto',
    }, SetOptions(merge: true));
  }

  Future<void> updateItemName({
    required String sessionId,
    required String itemId,
    required String name,
  }) async {
    await _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(itemId)
        .update({'suggestedName': name.trim(), 'nameState': 'corrected'});
  }

  Future<void> uploadItemPhoto({
    required String sessionId,
    required String itemId,
    required File file,
  }) async {
    final path = 'stock-counts/$sessionId/$itemId.jpg';
    final ref = _storage.ref(path);
    await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    final url = await ref.getDownloadURL();
    await _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(itemId)
        .set({
      'photoStoragePath': path,
      'photoUrl': url,
      'photoState': 'uploaded',
    }, SetOptions(merge: true));
  }

  Future<void> finalizeSession(String sessionId) async {
    await _db.collection('stock_count_sessions').doc(sessionId).update({
      'status': 'finalized',
      'finalizedAt': FieldValue.serverTimestamp(),
    });
  }
}
