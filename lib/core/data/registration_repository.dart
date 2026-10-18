import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import 'product_catalog_repository.dart';

/// V2 registration operates alongside legacy counts. Nothing here changes
/// stock until an owner performs an online, idempotent approval transaction.
class RegistrationRepository {
  RegistrationRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  static const _uuid = Uuid();

  CollectionReference<Map<String, dynamic>> get _entries =>
      _db.collection('registration_entries');

  Stream<QuerySnapshot<Map<String, dynamic>>> watchEntries(String branchId) =>
      _entries.where('branchId', isEqualTo: branchId).limit(2000).snapshots(
            includeMetadataChanges: true,
          );

  /// Queues on the Firestore local cache without waiting for the network.
  /// The returned ID is stable and may be used to check sync status later.
  String queueEntry({
    required String branchId,
    required String userId,
    required int quantity,
    String nameCandidate = '',
    String barcodeCandidate = '',
    String productText = '',
    String section = '',
    String? localPhotoPath,
    void Function(Object error)? onError,
  }) {
    if (quantity <= 0) throw ArgumentError('Quantity must be positive.');
    if (branchId.isEmpty || userId.isEmpty) {
      throw ArgumentError('Branch and employee are required.');
    }
    final ref = _entries.doc(_uuid.v4());
    unawaited(
      ref
          .set({
            'branchId': branchId,
            'createdBy': userId,
            'quantity': quantity,
            'nameCandidate': nameCandidate.trim(),
            'barcodeCandidate': ProductCatalogRepository.normalizeBarcode(
              barcodeCandidate,
            ),
            'productText': productText.trim(),
            'section': section.trim(),
            'photoState':
                localPhotoPath == null ? 'none' : 'local_only',
            'localPhotoPath': localPhotoPath,
            'status': 'pending',
            'createdAt': FieldValue.serverTimestamp(),
            'schemaVersion': 2,
          })
          .catchError((Object error) {
            if (onError != null) onError(error);
          }),
    );
    return ref.id;
  }

  /// OCR may finish after Save & Next. Only fill fields that were empty when
  /// the employee saved; never replace a manually confirmed label.
  Future<void> patchRecognition({
    required String entryId,
    String? suggestedName,
    String? barcode,
    String? productText,
  }) async {
    final updates = <String, dynamic>{};
    if (suggestedName?.trim().isNotEmpty == true) {
      updates['nameCandidate'] = suggestedName!.trim();
    }
    if (barcode?.trim().isNotEmpty == true) {
      updates['barcodeCandidate'] =
          ProductCatalogRepository.normalizeBarcode(barcode!);
    }
    if (productText?.trim().isNotEmpty == true) {
      updates['productText'] = productText!.trim();
    }
    if (updates.isEmpty) return;
    await _entries.doc(entryId).update(updates);
  }

  static String productId({
    required String branchId,
    required String normalizedName,
    required String barcode,
  }) {
    final branch = branchId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final cleanBarcode = ProductCatalogRepository.normalizeBarcode(barcode);
    if (cleanBarcode.isNotEmpty) return 'v2-$branch-b-$cleanBarcode';

    var hash = 0x811c9dc5;
    for (final code in normalizedName.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'v2-$branch-n-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// Approval atomically marks the entry, creates an immutable movement and
  /// increments the stock. A retry after success cannot count it twice.
  ///
  /// When an item was registered previously without a barcode, the owner can
  /// explicitly choose that existing product ID to prevent another product.
  /// Otherwise we use a deterministic barcode/name ID and refuse conflicts.
  Future<String> approveEntry({
    required String entryId,
    required String branchId,
    required String ownerId,
    required String officialName,
    required String barcode,
    required double sellingPrice,
    String? existingProductId,
  }) async {
    final cleanName = officialName.trim();
    final normalizedName = ProductCatalogRepository.normalizeName(cleanName);
    final normalizedBarcode =
        ProductCatalogRepository.normalizeBarcode(barcode);
    if (normalizedName.isEmpty) {
      throw ArgumentError('Confirm the complete product name and size.');
    }
    if (!sellingPrice.isFinite || sellingPrice <= 0) {
      throw ArgumentError('Selling price must be greater than zero.');
    }
    final selectedId = (existingProductId ?? '').trim();
    final id = selectedId.isNotEmpty
        ? selectedId
        : productId(
            branchId: branchId,
            normalizedName: normalizedName,
            barcode: normalizedBarcode,
          );

    final entryRef = _entries.doc(entryId);
    final productRef = _db.collection('products').doc(id);
    final movementRef = _db.collection('inventory_movements').doc(entryId);

    return _db.runTransaction<String>((transaction) async {
      final entrySnapshot = await transaction.get(entryRef);
      final entry = entrySnapshot.data();
      if (entry == null) throw StateError('Registration is missing.');
      if (entry['branchId'] != branchId) {
        throw StateError('Registration belongs to another branch.');
      }
      if (entry['status'] == 'approved') {
        return (entry['linkedProductId'] as String?) ?? id;
      }
      if (entry['status'] != 'pending') {
        throw StateError('Registration is no longer pending.');
      }

      final qty = (entry['quantity'] as num?)?.toInt();
      if (qty == null || qty <= 0) {
        throw StateError('Confirm the product quantity before approval.');
      }
      final previousMovement = await transaction.get(movementRef);
      if (previousMovement.exists) {
        throw StateError('This registration has already affected stock.');
      }
      final previousProduct = await transaction.get(productRef);
      final product = previousProduct.data();

      if (product != null && product['branchId'] != branchId) {
        throw StateError('Product belongs to another branch.');
      }
      final originalBarcode = ProductCatalogRepository.normalizeBarcode(
        product?['barcode'] as String? ?? '',
      );
      if (originalBarcode.isNotEmpty &&
          normalizedBarcode.isNotEmpty &&
          originalBarcode != normalizedBarcode) {
        throw StateError(
          'Barcode conflict: another size/product may have been selected.',
        );
      }
      final existingName = ProductCatalogRepository.normalizeName(
        (product?['name'] as String?) ?? '',
      );
      if (product != null &&
          originalBarcode.isEmpty &&
          normalizedBarcode.isEmpty &&
          existingName.isNotEmpty &&
          existingName != normalizedName) {
        throw StateError(
          'Name does not match existing product. Review the size/variant.',
        );
      }

      final before = (product?['stockQty'] as num?)?.toInt() ?? 0;
      if (before < 0) throw StateError('Stored stock cannot be negative.');
      final now = FieldValue.serverTimestamp();

      transaction.set(productRef, {
        'branchId': branchId,
        'name': cleanName,
        'normalizedName': normalizedName,
        'barcode': normalizedBarcode.isNotEmpty
            ? normalizedBarcode
            : originalBarcode.isNotEmpty
                ? originalBarcode
                : null,
        'catalogKey': normalizedBarcode.isNotEmpty
            ? 'barcode:$normalizedBarcode'
            : originalBarcode.isNotEmpty
                ? 'barcode:$originalBarcode'
                : 'name:$normalizedName',
        'sellingPrice': sellingPrice,
        'stockQty': before + qty,
        'active': true,
        'updatedAt': now,
        'updatedBy': ownerId,
        'schemaVersion': 2,
        'lastMovementId': entryId,
        if (product == null) 'createdAt': now,
        if (product == null) 'createdBy': ownerId,
        if (product == null) 'registrationSource': 'reviewed_entry',
        if ((entry['localPhotoPath'] as String?)?.isNotEmpty == true &&
            product?['localPhotoPath'] == null)
          'localPhotoPath': entry['localPhotoPath'],
        if ((entry['localPhotoPath'] as String?)?.isNotEmpty == true &&
            product?['localPhotoPath'] == null)
          'photoState': 'local_only',
      }, SetOptions(merge: true));

      transaction.set(movementRef, {
        'branchId': branchId,
        'productId': id,
        'registrationEntryId': entryId,
        'type': 'opening_count',
        'quantityDelta': qty,
        'beforeQty': before,
        'afterQty': before + qty,
        'createdAt': now,
        'createdBy': ownerId,
        'capturedBy': entry['createdBy'],
      });

      transaction.update(entryRef, {
        'status': 'approved',
        'reviewedName': cleanName,
        'reviewedBarcode':
            normalizedBarcode.isEmpty ? null : normalizedBarcode,
        'reviewedSellingPrice': sellingPrice,
        'linkedProductId': id,
        'approvedAt': now,
        'approvedBy': ownerId,
      });
      return id;
    }, maxAttempts: 5);
  }

  Future<void> rejectEntry({
    required String entryId,
    required String reason,
    required String ownerId,
  }) async {
    final ref = _entries.doc(entryId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.data()?['status'] != 'pending') {
        throw StateError('Only pending entries can be rejected.');
      }
      tx.update(ref, {
        'status': 'rejected',
        'rejectionReason': reason.trim(),
        'reviewedAt': FieldValue.serverTimestamp(),
        'reviewedBy': ownerId,
      });
    });
  }
}
