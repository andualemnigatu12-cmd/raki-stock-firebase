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
          ? normalizeName(product.normalizedName)
          : normalizeName(product.name);
      if (candidate == queryName) {
        return ProductMatch(
          product: product,
          confidence: 0.995,
          source: 'name',
        );
      }
    }

    ProductRecord? best;
    var bestScore = 0.0;
    var secondBestScore = 0.0;
    for (final product in products) {
      final candidate = product.normalizedName.isNotEmpty
          ? normalizeName(product.normalizedName)
          : normalizeName(product.name);
      if (candidate.isEmpty) continue;
      final score = _nameSimilarity(queryName, candidate);
      if (score > bestScore) {
        secondBestScore = bestScore;
        bestScore = score;
        best = product;
      } else if (score > secondBestScore) {
        secondBestScore = score;
      }
    }

    if (best == null) return null;

    final clearlyAhead = bestScore - secondBestScore >= 0.12;
    final safeMatch = bestScore >= 0.76 || (bestScore >= 0.69 && clearlyAhead);
    if (!safeMatch) return null;

    // Fast Count currently applies catalog spelling when confidence is >= .82.
    // Reaching this point already passed the ambiguity guard above, so expose a
    // confidence floor of .82 to let the reviewed official spelling win.
    final appliedConfidence = bestScore < 0.82 ? 0.82 : bestScore;
    return ProductMatch(
      product: best,
      confidence: appliedConfidence,
      source: 'name',
    );
  }

  double _nameSimilarity(String a, String b) {
    if (a == b) return 1;

    var containmentScore = 0.0;
    if (a.contains(b) || b.contains(a)) {
      final shorter = a.length < b.length ? a.length : b.length;
      final longer = a.length > b.length ? a.length : b.length;
      if (longer > 0) {
        containmentScore = 0.80 + (shorter / longer) * 0.18;
      }
    }

    final charScore = _stringSimilarity(a, b);
    final tokenScore = _softTokenSimilarity(a, b);
    final firstWordScore = _firstWordSimilarity(a, b);

    var score = charScore * 0.40 + tokenScore * 0.50 + firstWordScore * 0.10;
    if (containmentScore > score) score = containmentScore;
    return score > 1 ? 1 : score;
  }

  double _softTokenSimilarity(String a, String b) {
    final aTokens = a.split(' ').where((token) => token.length > 1).toList();
    final bTokens = b.split(' ').where((token) => token.length > 1).toList();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;

    var weightedMatches = 0.0;
    var totalWeight = 0.0;
    final used = <int>{};

    for (final token in aTokens) {
      final weight = token.length >= 6 ? 1.35 : token.length >= 4 ? 1.0 : 0.72;
      totalWeight += weight;

      var best = 0.0;
      var bestIndex = -1;
      for (var i = 0; i < bTokens.length; i++) {
        if (used.contains(i)) continue;
        final similarity = _stringSimilarity(token, bTokens[i]);
        if (similarity > best) {
          best = similarity;
          bestIndex = i;
        }
      }

      if (best >= 0.54) {
        weightedMatches += best * weight;
        if (bestIndex >= 0) used.add(bestIndex);
      }
    }

    if (totalWeight == 0) return 0;
    final forward = weightedMatches / totalWeight;

    final lengthBalance =
        (aTokens.length < bTokens.length ? aTokens.length : bTokens.length) /
            (aTokens.length > bTokens.length ? aTokens.length : bTokens.length);
    return forward * (0.82 + lengthBalance * 0.18);
  }

  double _firstWordSimilarity(String a, String b) {
    final aFirst =
        a.split(' ').firstWhere((word) => word.isNotEmpty, orElse: () => '');
    final bFirst =
        b.split(' ').firstWhere((word) => word.isNotEmpty, orElse: () => '');
    if (aFirst.isEmpty || bFirst.isEmpty) return 0;
    return _stringSimilarity(aFirst, bFirst);
  }

  double _stringSimilarity(String a, String b) {
    if (a == b) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    final distance = _weightedEditDistance(a, b);
    final longest = a.length > b.length ? a.length : b.length;
    if (longest == 0) return 1;
    final score = 1 - (distance / longest);
    return score < 0 ? 0 : score;
  }

  double _weightedEditDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length.toDouble();
    if (b.isEmpty) return a.length.toDouble();

    var previous =
        List<double>.generate(b.length + 1, (index) => index.toDouble());
    for (var i = 1; i <= a.length; i++) {
      final current = List<double>.filled(b.length + 1, 0);
      current[0] = i.toDouble();
      for (var j = 1; j <= b.length; j++) {
        final left = a.substring(i - 1, i);
        final right = b.substring(j - 1, j);
        final substitutionCost = _ocrSubstitutionCost(left, right);
        final insertion = current[j - 1] + 1;
        final deletion = previous[j] + 1;
        final substitution = previous[j - 1] + substitutionCost;
        var value = insertion < deletion ? insertion : deletion;
        if (substitution < value) value = substitution;
        current[j] = value;
      }
      previous = current;
    }
    return previous[b.length];
  }

  double _ocrSubstitutionCost(String a, String b) {
    if (a == b) return 0;
    const groups = <String>[
      'o0',
      'i1l',
      's5',
      'b8',
      'z2',
      'g9q',
      'uv',
    ];
    for (final group in groups) {
      if (group.contains(a) && group.contains(b)) return 0.28;
    }
    return 1;
  }

  static String normalizeName(String input) {
    var value = input.toLowerCase();
    const replacements = <String, String>{
      'á': 'a',
      'à': 'a',
      'â': 'a',
      'ã': 'a',
      'ä': 'a',
      'å': 'a',
      'é': 'e',
      'è': 'e',
      'ê': 'e',
      'ë': 'e',
      'í': 'i',
      'ì': 'i',
      'î': 'i',
      'ï': 'i',
      'ó': 'o',
      'ò': 'o',
      'ô': 'o',
      'õ': 'o',
      'ö': 'o',
      'ú': 'u',
      'ù': 'u',
      'û': 'u',
      'ü': 'u',
      'ç': 'c',
      'ñ': 'n',
      'ý': 'y',
      'ÿ': 'y',
      'æ': 'ae',
      'œ': 'oe',
    };
    replacements.forEach((from, to) {
      value = value.replaceAll(from, to);
    });
    return value
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String normalizeBarcode(String input) =>
      input.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
}
