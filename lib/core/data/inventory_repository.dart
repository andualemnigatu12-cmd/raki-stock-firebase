import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'product_catalog_repository.dart';

class InventoryRepository {
  InventoryRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Future<DocumentReference<Map<String, dynamic>>> startOrContinueCount({
    required String branchId,
    required String userId,
  }) async {
    final query = _db
        .collection('stock_count_sessions')
        .where('branchId', isEqualTo: branchId)
        .where('createdBy', isEqualTo: userId)
        .where('status', isEqualTo: 'draft')
        .limit(1);

    try {
      final cached = await query.get(const GetOptions(source: Source.cache));
      if (cached.docs.isNotEmpty) return cached.docs.first.reference;
    } catch (_) {}

    try {
      final fresh = await query.get().timeout(const Duration(milliseconds: 900));
      if (fresh.docs.isNotEmpty) return fresh.docs.first.reference;
    } catch (_) {
      // Weak/no network must never keep the employee waiting.
    }

    final ref = _db.collection('stock_count_sessions').doc();
    final now = DateTime.now();
    final code =
        'CNT-${now.year.toString().substring(2)}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';

    unawaited(
      ref.set({
        'code': code,
        'branchId': branchId,
        'createdBy': userId,
        'status': 'draft',
        'createdAt': FieldValue.serverTimestamp(),
        'localCreatedAt': Timestamp.fromDate(now),
        'finalizedAt': null,
      }).catchError((_) {}),
    );
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
        .limit(8)
        .snapshots();
  }

  Future<void> saveCountItem({
    required String sessionId,
    required String branchId,
    required String clientEntryId,
    required String tempCode,
    required int quantity,
    required String userId,
    required DateTime localCreatedAt,
    required String localPhotoPath,
    String? suggestedName,
    String? primaryText,
    String? rawOcr,
    String? barcode,
  }) async {
    await _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(clientEntryId)
        .set({
      'clientEntryId': clientEntryId,
      'tempCode': tempCode,
      'branchId': branchId,
      'quantity': quantity,
      'suggestedName': suggestedName,
      'primaryText': primaryText,
      'rawOcr': rawOcr,
      'barcodeCandidate': barcode,
      'createdBy': userId,
      'localCreatedAt': Timestamp.fromDate(localCreatedAt),
      'createdAt': FieldValue.serverTimestamp(),
      'localPhotoPath': localPhotoPath,
      'photoState': 'local_only',
      'hasLocalPhoto': true,
      'nameState': suggestedName == null ? 'needs_review' : 'auto',
      'reviewState': 'pending',
    }, SetOptions(merge: true));
  }

  Future<void> patchRecognizedData({
    required String sessionId,
    required String itemId,
    String? suggestedName,
    String? primaryText,
    String? rawOcr,
    String? barcode,
  }) async {
    await _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(itemId)
        .set({
      'suggestedName': suggestedName,
      'primaryText': primaryText,
      'rawOcr': rawOcr,
      'barcodeCandidate': barcode,
      'nameState': suggestedName == null ? 'needs_review' : 'auto',
      'ocrSource': suggestedName == null ? null : 'on_device_mlkit',
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

  Future<String> reviewItemIntoStock({
    required String branchId,
    required String sessionId,
    required String itemId,
    required String name,
    required int quantity,
    required double sellingPrice,
    required String userId,
    String? barcode,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw ArgumentError('Product name is required.');
    if (sellingPrice < 0) throw ArgumentError('Selling price cannot be negative.');

    final normalizedName = ProductCatalogRepository.normalizeName(cleanName);
    final normalizedBarcode =
        ProductCatalogRepository.normalizeBarcode(barcode ?? '');
    final productId = normalizedBarcode.isNotEmpty
        ? '${_slug(branchId)}-b-$normalizedBarcode'
        : '${_slug(branchId)}-i-${itemId.replaceAll('-', '')}';

    final itemRef = _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(itemId);
    final productRef = _db.collection('products').doc(productId);

    return _db.runTransaction<String>((transaction) async {
      final itemSnapshot = await transaction.get(itemRef);
      final itemData = itemSnapshot.data();
      if (itemData == null) throw StateError('Count item no longer exists.');

      if (itemData['reviewState'] == 'added') {
        return itemData['linkedProductId'] as String? ?? productId;
      }

      final productSnapshot = await transaction.get(productRef);
      final productData = productSnapshot.data();
      final currentStock = (productData?['stockQty'] as num?)?.toInt() ?? 0;
      final now = FieldValue.serverTimestamp();

      final productWrite = <String, dynamic>{
        'branchId': branchId,
        'name': cleanName,
        'normalizedName': normalizedName,
        'barcode': normalizedBarcode.isEmpty ? null : normalizedBarcode,
        'sellingPrice': sellingPrice,
        'stockQty': currentStock + quantity,
        'active': true,
        'updatedAt': now,
        'updatedBy': userId,
        'lastCountSessionId': sessionId,
      };
      if (!productSnapshot.exists) {
        productWrite['createdAt'] = now;
        productWrite['createdBy'] = userId;
      }

      transaction.set(productRef, productWrite, SetOptions(merge: true));
      transaction.set(
        itemRef,
        {
          'reviewState': 'added',
          'linkedProductId': productId,
          'reviewedName': cleanName,
          'reviewedBarcode': normalizedBarcode.isEmpty ? null : normalizedBarcode,
          'reviewedSellingPrice': sellingPrice,
          'reviewedAt': now,
          'reviewedBy': userId,
        },
        SetOptions(merge: true),
      );
      return productId;
    });
  }

  Future<void> finalizeSession(String sessionId) async {
    await _db.collection('stock_count_sessions').doc(sessionId).update({
      'status': 'finalized',
      'finalizedAt': FieldValue.serverTimestamp(),
    });
  }

  String _slug(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
