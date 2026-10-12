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
      _retryWrite(
        () => ref.set({
          'code': code,
          'branchId': branchId,
          'createdBy': userId,
          'status': 'draft',
          'createdAt': FieldValue.serverTimestamp(),
          'localCreatedAt': Timestamp.fromDate(now),
          'finalizedAt': null,
        }),
        retries: 2,
      ).catchError((_) {}),
    );
    return ref;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchRecentSessions(String branchId) {
    return _db
        .collection('stock_count_sessions')
        .where('branchId', isEqualTo: branchId)
        .limit(50)
        .snapshots(includeMetadataChanges: true);
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchItems(String sessionId) {
    return _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .orderBy('localCreatedAt', descending: true)
        .limit(8)
        .snapshots(includeMetadataChanges: true);
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
    final ref = _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(clientEntryId);

    await _retryWrite(
      () => ref.set({
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
      }, SetOptions(merge: true)),
      retries: 2,
    );
  }

  Future<void> patchRecognizedData({
    required String sessionId,
    required String itemId,
    String? suggestedName,
    String? primaryText,
    String? rawOcr,
    String? barcode,
  }) async {
    final ref = _db
        .collection('stock_count_sessions')
        .doc(sessionId)
        .collection('items')
        .doc(itemId);

    await _retryWrite(
      () => ref.set({
        'suggestedName': suggestedName,
        'primaryText': primaryText,
        'rawOcr': rawOcr,
        'barcodeCandidate': barcode,
        'nameState': suggestedName == null ? 'needs_review' : 'auto',
        'ocrSource': suggestedName == null ? null : 'on_device_mlkit',
      }, SetOptions(merge: true)),
      retries: 1,
    );
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
  /// Existing products are resolved by current barcode/name before creating a
  /// deterministic fallback ID. This means a product remains the same catalog
  /// item even if it was originally created through Quick Add or an older app.
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

    String? existingProductId;
    if (existingLinkedId?.isNotEmpty == true) {
      existingProductId = existingLinkedId;
    } else {
      existingProductId = await _findExistingProductId(
        branchId: branchId,
        normalizedName: normalizedName,
        normalizedBarcode: normalizedBarcode,
      );
    }

    final productId = existingProductId ??
        _productId(
          branchId: branchId,
          normalizedName: normalizedName,
          normalizedBarcode: normalizedBarcode,
        );

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
      'catalogKey': normalizedBarcode.isNotEmpty
          ? 'barcode:$normalizedBarcode'
          : 'name:$normalizedName',
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
  ///
  /// Firestore batches are capped at 500 writes. We commit in chunks so a large
  /// first-day catalog does not suddenly fail around 250 counted products.
  Future<int> approveAllPending({
    required String branchId,
    required String sessionId,
    required String userId,
  }) async {
    final sessionRef = _db.collection('stock_count_sessions').doc(sessionId);
    final snapshot = await sessionRef.collection('items').get();
    if (snapshot.docs.isEmpty) return 0;

    final lookup = await _loadProductLookup(branchId);
    final totals = <String, int>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data['reviewState'] != 'added') continue;
      final linked = (data['linkedProductId'] as String?)?.trim();
      if (linked == null || linked.isEmpty) continue;
      totals[linked] = (totals[linked] ?? 0) +
          ((data['quantity'] as num?)?.toInt() ?? 0);
    }

    WriteBatch batch = _db.batch();
    var writesInBatch = 0;
    final now = FieldValue.serverTimestamp();
    var approved = 0;

    Future<void> flushBatch() async {
      if (writesInBatch == 0) return;
      await batch.commit();
      batch = _db.batch();
      writesInBatch = 0;
    }

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

      final matchedByBarcode = normalizedBarcode.isEmpty
          ? null
          : lookup.byBarcode[normalizedBarcode];
      final matchedByName = lookup.byName[normalizedName];
      final productId = matchedByBarcode ??
          matchedByName ??
          _productId(
            branchId: branchId,
            normalizedName: normalizedName,
            normalizedBarcode: normalizedBarcode,
          );

      // Make products created earlier in this same bulk approval immediately
      // available to later duplicate entries without another Firestore read.
      lookup.byName[normalizedName] = productId;
      if (normalizedBarcode.isNotEmpty) {
        lookup.byBarcode[normalizedBarcode] = productId;
      }

      final nextTotal = (totals[productId] ?? 0) + quantity;
      totals[productId] = nextTotal;
      final learnedAliases = _learnedOcrAliases(data, name);

      final productWrite = <String, dynamic>{
        'branchId': branchId,
        'name': name,
        'normalizedName': normalizedName,
        'barcode': normalizedBarcode.isEmpty ? null : normalizedBarcode,
        'catalogKey': normalizedBarcode.isNotEmpty
            ? 'barcode:$normalizedBarcode'
            : 'name:$normalizedName',
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
      writesInBatch += 2;
      approved++;

      if (writesInBatch >= 400) await flushBatch();
    }

    await flushBatch();
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

    for (var offset = 0; offset < items.docs.length; offset += 400) {
      final batch = _db.batch();
      final end = (offset + 400 < items.docs.length)
          ? offset + 400
          : items.docs.length;
      for (var i = offset; i < end; i++) {
        batch.delete(items.docs[i].reference);
      }
      await batch.commit();
    }

    await sessionRef.delete();
  }

  Future<void> finalizeSession(String sessionId) async {
    await _db.collection('stock_count_sessions').doc(sessionId).update({
      'status': 'finalized',
      'finalizedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<String?> _findExistingProductId({
    required String branchId,
    required String normalizedName,
    required String normalizedBarcode,
  }) async {
    final products = _db.collection('products');

    Future<String?> run(Query<Map<String, dynamic>> query) async {
      try {
        final cached = await query.get(const GetOptions(source: Source.cache));
        if (cached.docs.isNotEmpty) return cached.docs.first.id;
      } catch (_) {}
      try {
        final fresh = await query.get().timeout(const Duration(milliseconds: 1000));
        if (fresh.docs.isNotEmpty) return fresh.docs.first.id;
      } catch (_) {}
      return null;
    }

    if (normalizedBarcode.isNotEmpty) {
      final match = await run(
        products
            .where('branchId', isEqualTo: branchId)
            .where('barcode', isEqualTo: normalizedBarcode)
            .limit(1),
      );
      if (match != null) return match;
    }

    if (normalizedName.isNotEmpty) {
      return run(
        products
            .where('branchId', isEqualTo: branchId)
            .where('normalizedName', isEqualTo: normalizedName)
            .limit(1),
      );
    }
    return null;
  }

  Future<_ProductLookup> _loadProductLookup(String branchId) async {
    final query = _db.collection('products').where('branchId', isEqualTo: branchId);
    QuerySnapshot<Map<String, dynamic>>? snapshot;

    try {
      final cached = await query.get(const GetOptions(source: Source.cache));
      if (cached.docs.isNotEmpty) snapshot = cached;
    } catch (_) {}

    if (snapshot == null) {
      try {
        snapshot = await query.get().timeout(const Duration(milliseconds: 1400));
      } catch (_) {}
    }

    final byBarcode = <String, String>{};
    final byName = <String, String>{};
    for (final doc in snapshot?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
      final data = doc.data();
      final barcode = ProductCatalogRepository.normalizeBarcode(
        (data['barcode'] as String?) ?? '',
      );
      final name = ProductCatalogRepository.normalizeName(
        (data['normalizedName'] as String?)?.trim().isNotEmpty == true
            ? data['normalizedName'] as String
            : (data['name'] as String?) ?? '',
      );
      if (barcode.isNotEmpty) byBarcode[barcode] = doc.id;
      if (name.isNotEmpty) byName[name] = doc.id;
    }
    return _ProductLookup(byBarcode: byBarcode, byName: byName);
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
      if (normalized.split(' ').length > 10) return;
      aliases.add(normalized);
    }

    addCandidate(itemData['suggestedName']);
    addCandidate(itemData['primaryText']);
    return aliases.take(4).toList(growable: false);
  }

  Future<void> _retryWrite(
    Future<void> Function() operation, {
    int retries = 2,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        await operation();
        return;
      } catch (error) {
        lastError = error;
        if (attempt >= retries) break;
        await Future<void>.delayed(Duration(milliseconds: 250 + attempt * 250));
      }
    }
    throw lastError ?? StateError('Write failed.');
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

class _ProductLookup {
  const _ProductLookup({required this.byBarcode, required this.byName});

  final Map<String, String> byBarcode;
  final Map<String, String> byName;
}
