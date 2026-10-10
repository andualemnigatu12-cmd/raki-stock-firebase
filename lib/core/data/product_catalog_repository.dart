import 'package:cloud_firestore/cloud_firestore.dart';

class ProductRecord {
  const ProductRecord({
    required this.id,
    required this.name,
    required this.normalizedName,
    required this.barcode,
    required this.sellingPrice,
    required this.stockQty,
    required this.active,
  });

  final String id;
  final String name;
  final String normalizedName;
  final String? barcode;
  final double sellingPrice;
  final int stockQty;
  final bool active;

  factory ProductRecord.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return ProductRecord(
      id: doc.id,
      name: (data['name'] as String? ?? '').trim(),
      normalizedName: (data['normalizedName'] as String? ?? '').trim(),
      barcode: (data['barcode'] as String?)?.trim(),
      sellingPrice: (data['sellingPrice'] as num?)?.toDouble() ?? 0,
      stockQty: (data['stockQty'] as num?)?.toInt() ?? 0,
      active: data['active'] as bool? ?? true,
    );
  }
}

class ProductMatch {
  const ProductMatch({
    required this.product,
    required this.confidence,
    required this.source,
  });

  final ProductRecord product;
  final double confidence;
  final String source;
}

class ProductCatalogRepository {
  ProductCatalogRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Query<Map<String, dynamic>> _query(String branchId) =>
      _db.collection('products').where('branchId', isEqualTo: branchId);

  Future<List<ProductRecord>> loadCached(String branchId) async {
    try {
      final cached = await _query(branchId).get(
        const GetOptions(source: Source.cache),
      );
      if (cached.docs.isNotEmpty) {
        return cached.docs
            .map(ProductRecord.fromDoc)
            .where((product) => product.active)
            .toList();
      }
    } catch (_) {
      // No local catalog yet. The live stream will hydrate it when online.
    }

    try {
      final snapshot = await _query(branchId).get();
      return snapshot.docs
          .map(ProductRecord.fromDoc)
          .where((product) => product.active)
          .toList();
    } catch (_) {
      return const <ProductRecord>[];
    }
  }

  Stream<List<ProductRecord>> watchProducts(String branchId) =>
      _query(branchId).snapshots().map(
            (snapshot) => snapshot.docs
                .map(ProductRecord.fromDoc)
                .where((product) => product.active)
                .toList(),
          );

  ProductMatch? findBestMatch(
    List<ProductRecord> products, {
    String? barcode,
    String? ocrName,
  }) {
    final cleanBarcode = normalizeBarcode(barcode ?? '');
    if (cleanBarcode.isNotEmpty) {
      for (final product in products) {
        if (normalizeBarcode(product.barcode ?? '') == cleanBarcode) {
          return ProductMatch(
            product: product,
            confidence: 1,
            source: 'barcode',
          );
        }
      }
    }

    final queryName = normalizeName(ocrName ?? '');
    if (queryName.isEmpty) return null;

    for (final product in products) {
      final candidate = product.normalizedName.isNotEmpty
          ? product.normalizedName
          : normalizeName(product.name);
      if (candidate == queryName) {
        return ProductMatch(
          product: product,
          confidence: 0.99,
          source: 'name',
        );
      }
    }

    ProductRecord? best;
    var bestScore = 0.0;
    for (final product in products) {
      final candidate = product.normalizedName.isNotEmpty
          ? product.normalizedName
          : normalizeName(product.name);
      if (candidate.isEmpty) continue;
      final score = _nameSimilarity(queryName, candidate);
      if (score > bestScore) {
        bestScore = score;
        best = product;
      }
    }

    if (best == null || bestScore < 0.64) return null;
    return ProductMatch(
      product: best,
      confidence: bestScore,
      source: 'name',
    );
  }

  double _nameSimilarity(String a, String b) {
    if (a.contains(b) || b.contains(a)) {
      final shorter = a.length < b.length ? a.length : b.length;
      final longer = a.length > b.length ? a.length : b.length;
      if (longer > 0) return 0.82 + (shorter / longer) * 0.15;
    }

    final aTokens = a.split(' ').where((token) => token.length > 1).toSet();
    final bTokens = b.split(' ').where((token) => token.length > 1).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;
    final intersection = aTokens.intersection(bTokens).length;
    final union = aTokens.union(bTokens).length;
    if (union == 0) return 0;
    final jaccard = intersection / union;

    var prefixBonus = 0.0;
    final aFirst = aTokens.first;
    final bFirst = bTokens.first;
    if (aFirst == bFirst || aFirst.startsWith(bFirst) || bFirst.startsWith(aFirst)) {
      prefixBonus = 0.12;
    }
    final score = jaccard * 0.88 + prefixBonus;
    return score > 1 ? 1 : score;
  }

  static String normalizeName(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String normalizeBarcode(String input) =>
      input.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
}
