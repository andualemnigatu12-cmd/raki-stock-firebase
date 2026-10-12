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
        .limit(50)
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

  /// Reviews one counted item and reconciles the product stock to the total
  /// quantity counted for that product in this session.
  ///
  /// The OCR text that led to an owner correction is saved as an alias on the
  /// product. Next time ML Kit makes the same stylized-font mistake, catalog
  /// matching can resolve it immediately without another correction.
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
    if (quantity <= 0) throw ArgumentError('Quantity must be greater than zero.');
    if (sellingPrice < 0) throw ArgumentError('Selling price cannot be negative.');

    final sessionRef = _db.collection('stock_count_sessions').doc(sessionId);
    final itemRef = sessionRef.collection('items').doc(itemId);
    final itemSnapshot = await itemRef.get();
    final itemData = itemSnapshot.data();
    if (itemData == null) throw StateError('Count item no longer exists.');

    final normalizedName = ProductCatalogRepository.normalizeName(cleanName);
    final normalizedBarcode =
        ProductCatalogRepository.normalizeBarcode(barcode ?? '');
    final existingLinkedId = (itemData['linkedProductId'] as String?)?.trim();
    final localPhotoPath = (itemData['localPhotoPath'] as String?)?.trim();
    final learnedAliases = _learnedOcrAliases(itemData, cleanName);
    final productId = existingLinkedId?.isNotEmpty == true
        ? existingLinkedId!
        : _productId(
            branchId: branchId,
            normalizedName: normalizedName,
            normalizedBarcode: normalizedBarcode,
          );

    // Sum any already-approved duplicate entries for the same product in this
    // count, then add the quantity currently being reviewed. This preserves
    // physical-count semantics without reading the product document itself.
    final allItems = await sessionRef.collection('items').get();
    var sessionTotal = quantity;
    for (final doc in allItems.docs) {
      if (doc.id == itemId) continue;
      final data = doc.data();
      if (data['reviewState'] != 'added') continue;
      if ((data['linkedProductId'] as String?) != productId) continue;
      sessionTotal += (data['quantity'] as num?)?.toInt() ?? 0;
    }

    final now = FieldValue.serverTimestamp();
    final productRef = _db.collection('products').doc(productId);
    final batch = _db.batch();
    final productWrite = <String, dynamic>{
      'branchId': branchId,
      'name': cleanName,
      'normalizedName': normalizedName,
      'barcode': normalizedBarcode.isEmpty ? null : normalizedBarcode,
      'sellingPrice': sellingPrice,
      'stockQty': sessionTotal,
      'active': true,
      'updatedAt': now,
      'updatedBy': userId,
      'lastCountSessionId': sessionId,
    };
    if (localPhotoPath?.isNotEmpty == true) {
      productWrite['localPhotoPath'] = localPhotoPath;
      productWrite['photoState'] = 'local_only';
    }
    if (learnedAliases.isNotEmpty) {
      productWrite['ocrAliases'] = FieldValue.arrayUnion(learnedAliases);
      productWrite['ocrLearnedAt'] = now;
    }

    batch.set(productRef, productWrite, SetOptions(merge: true));

    batch.set(
      itemRef,
      {
        'quantity': quantity,
        'suggestedName': cleanName,
        'barcodeCandidate': normalizedBarcode.isEmpty ? null : normalizedBarcode,
        'nameState': 'corrected',
        'reviewState': 'added',
        'linkedProductId': productId,
        'reviewedName': cleanName,
        'reviewedBarcode': normalizedBarcode.isEmpty ? null : normalizedBarcode,
        'reviewedSellingPrice': sellingPrice,
        'reviewedAt': now,
        'reviewedBy': userId,
        if (learnedAliases.isNotEmpty) 'learnedOcrAliases': learnedAliases,
      },
      SetOptions(merge: true),
    );

    await batch.commit();
    return productId;
  }

  /// Accepts every pending item that has an OCR/product name. Existing product
  /// prices are preserved because bulk approval does not write a sellingPrice.
  /// New products without a price remain at the app's default 0 until the owner
  /// opens the item and edits its price.
  Future<int> approveAllPending({
    required String branchId,
    required String sessionId,
    required String userId,
  }) async {
    final sessionRef = _db.collection('stock_count_sessions').doc(sessionId);
    final snapshot = await sessionRef.collection('items').get();
    if (snapshot.docs.isEmpty) return 0;

    final totals = <String, int>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data['reviewState'] != 'added') continue;
      final linked = (data['linkedProductId'] as String?)?.trim();
      if (linked == null || linked.isEmpty) continue;
      totals[linked] = (totals[linked] ?? 0) +
          ((data['quantity'] as num?)?.toInt() ?? 0);
    }

    final batch = _db.batch();
    final now = FieldValue.serverTimestamp();
    var approved = 0;

    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data['reviewState'] == 'added') continue;

      final name = (data['suggestedName'] as String?)?.trim() ?? '';
      final quantity = (data['quantity'] as num?)?.toInt() ?? 0;
      if (name.isEmpty || quantity <= 0) continue;

      final normalizedName = ProductCatalogRepository.normalizeName(name);
      final normalizedBarcode = ProductCatalogRepository.normalizeBarcode(
        (data['barcodeCandidate'] as String?) ?? '',
      );
      final productId = _productId(
        branchId: branchId,
        normalizedName: normalizedName,
        normalizedBarcode: normalizedBarcode,
      );
      final nextTotal = (totals[productId] ?? 0) + quantity;
      totals[productId] = nextTotal;
      final learnedAliases = _learnedOcrAliases(data, name);

      final productWrite = <String, dynamic>{
        'branchId': branchId,
        'name': name,
        'normalizedName': normalizedName,
        'barcode': normalizedBarcode.isEmpty ? null : normalizedBarcode,
        'stockQty': nextTotal,
        'active': true,
        'updatedAt': now,
        'updatedBy': userId,
        'lastCountSessionId': sessionId,
      };

      final previousPrice = (data['reviewedSellingPrice'] as num?)?.toDouble();
      if (previousPrice != null) productWrite['sellingPrice'] = previousPrice;
      final localPhotoPath = (data['localPhotoPath'] as String?)?.trim();
      if (localPhotoPath?.isNotEmpty == true) {
        productWrite['localPhotoPath'] = localPhotoPath;
        productWrite['photoState'] = 'local_only';
      }
      if (learnedAliases.isNotEmpty) {
        productWrite['ocrAliases'] = FieldValue.arrayUnion(learnedAliases);
        productWrite['ocrLearnedAt'] = now;
      }

      batch.set(
        _db.collection('products').doc(productId),
        productWrite,
        SetOptions(merge: true),
      );
      batch.set(
        doc.reference,
        {
          'reviewState': 'added',
          'linkedProductId': productId,
          'reviewedName': name,
          'reviewedBarcode': normalizedBarcode.isEmpty ? null : normalizedBarcode,
          'reviewedAt': now,
          'reviewedBy': userId,
          if (learnedAliases.isNotEmpty) 'learnedOcrAliases': learnedAliases,
        },
        SetOptions(merge: true),
      );
      approved++;
    }

    if (approved > 0) await batch.commit();
    return approved;
  }

  Future<void> deleteCountItem({
    required String sessionId,
    required String itemId,
    bool deleteLinkedProduct = false,
  }) async {
    final itemRef = _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(itemId);
    final snapshot = await itemRef.get();
    final data = snapshot.data();
    if (data == null) return;

    final batch = _db.batch();
    if (deleteLinkedProduct) {
      final linked = (data['linkedProductId'] as String?)?.trim();
      if (linked?.isNotEmpty == true) {
        batch.delete(_db.collection('products').doc(linked));
      }
    }
    batch.delete(itemRef);
    await batch.commit();
  }

  Future<void> deleteSession(String sessionId) async {
    final sessionRef = _db.collection('stock_count_sessions').doc(sessionId);
    final items = await sessionRef.collection('items').get();
    final batch = _db.batch();
    for (final doc in items.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(sessionRef);
    await batch.commit();
  }

  Future<void> finalizeSession(String sessionId) async {
    await _db.collection('stock_count_sessions').doc(sessionId).update({
      'status': 'finalized',
      'finalizedAt': FieldValue.serverTimestamp(),
    });
  }

  List<String> _learnedOcrAliases(
    Map<String, dynamic> itemData,
    String officialName,
  ) {
    final official = ProductCatalogRepository.normalizeName(officialName);
    final aliases = <String>{};

    void addCandidate(dynamic value) {
      if (value is! String) return;
      final trimmed = value.trim();
      if (trimmed.length < 2 || trimmed.length > 120) return;
      final normalized = ProductCatalogRepository.normalizeName(trimmed);
      if (normalized.length < 2 || normalized == official) return;
      // Keep only compact product-like OCR text. This avoids learning an
      // ingredients paragraph or other noisy label text as a product alias.
      if (normalized.split(' ').length > 10) return;
      aliases.add(normalized);
    }

    addCandidate(itemData['suggestedName']);
    addCandidate(itemData['primaryText']);
    return aliases.take(4).toList(growable: false);
  }

  String _productId({
    required String branchId,
    required String normalizedName,
    required String normalizedBarcode,
  }) {
    if (normalizedBarcode.isNotEmpty) {
      return '${_slug(branchId)}-b-$normalizedBarcode';
    }
    return '${_slug(branchId)}-n-${_stableHash(normalizedName)}';
  }

  String _stableHash(String value) {
    // 32-bit FNV-1a. Stable across app launches and compact enough for a
    // Firestore document ID. Same corrected product name => same product.
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _slug(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
