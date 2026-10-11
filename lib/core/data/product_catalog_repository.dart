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
    this.localPhotoPath,
  });

  final String id;
  final String name;
  final String normalizedName;
  final String? barcode;
  final double sellingPrice;
  final int stockQty;
  final bool active;
  final String? localPhotoPath;

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
      localPhotoPath: (data['localPhotoPath'] as String?)?.trim(),
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

  // These indexes are rebuilt only when the catalog list instance changes.
  // Barcode and exact-name matching therefore become O(1), and fuzzy matching
  // usually checks only a small token bucket instead of the whole catalog.
  List<ProductRecord>? _indexedProducts;
  Map<String, ProductRecord> _barcodeIndex = const {};
  Map<String, ProductRecord> _nameIndex = const {};
  Map<String, List<ProductRecord>> _tokenIndex = const {};
  Map<String, List<ProductRecord>> _foldedTokenIndex = const {};

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
    _ensureIndex(products);

    final cleanBarcode = normalizeBarcode(barcode ?? '');
    if (cleanBarcode.isNotEmpty) {
      final product = _barcodeIndex[cleanBarcode];
      if (product != null) {
        return ProductMatch(
          product: product,
          confidence: 1,
          source: 'barcode',
        );
      }
    }

    final queryName = normalizeName(ocrName ?? '');
    if (queryName.isEmpty) return null;

    final exact = _nameIndex[queryName];
    if (exact != null) {
      return ProductMatch(
        product: exact,
        confidence: 0.995,
        source: 'name',
      );
    }

    final candidates = _candidateProducts(queryName, products);
    ProductRecord? best;
    var bestScore = 0.0;
    var secondBestScore = 0.0;

    for (final product in candidates) {
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

    final appliedConfidence = bestScore < 0.82 ? 0.82 : bestScore;
    return ProductMatch(
      product: best,
      confidence: appliedConfidence,
      source: 'name',
    );
  }

  /// Fast local search for the upcoming Products screen. Exact/prefix results
  /// are ranked first; then contains matches. No Firestore query is needed for
  /// each keystroke because the already-synced local catalog is used.
  List<ProductRecord> searchProducts(
    List<ProductRecord> products,
    String query, {
    int limit = 40,
  }) {
    _ensureIndex(products);
    final normalized = normalizeName(query);
    final barcodeQuery = normalizeBarcode(query);

    if (normalized.isEmpty && barcodeQuery.isEmpty) {
      final result = [...products]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return result.take(limit).toList();
    }

    final scored = <({ProductRecord product, int score})>[];
    for (final product in products) {
      final name = product.normalizedName.isNotEmpty
          ? normalizeName(product.normalizedName)
          : normalizeName(product.name);
      final barcode = normalizeBarcode(product.barcode ?? '');
      var score = 0;

      if (barcodeQuery.isNotEmpty && barcode == barcodeQuery) {
        score = 1000;
      } else if (name == normalized) {
        score = 950;
      } else if (normalized.isNotEmpty && name.startsWith(normalized)) {
        score = 800;
      } else if (normalized.isNotEmpty && name.contains(normalized)) {
        score = 650;
      } else if (barcodeQuery.length >= 3 && barcode.contains(barcodeQuery)) {
        score = 600;
      } else if (normalized.isNotEmpty) {
        final queryTokens = normalized.split(' ');
        final nameTokens = name.split(' ').toSet();
        final hits = queryTokens.where(nameTokens.contains).length;
        if (hits > 0) score = 300 + hits * 40;
      }

      if (score > 0) scored.add((product: product, score: score));
    }

    scored.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;
      return a.product.name
          .toLowerCase()
          .compareTo(b.product.name.toLowerCase());
    });

    return scored.take(limit).map((entry) => entry.product).toList();
  }

  void _ensureIndex(List<ProductRecord> products) {
    if (identical(_indexedProducts, products)) return;

    final barcodeIndex = <String, ProductRecord>{};
    final nameIndex = <String, ProductRecord>{};
    final tokenIndex = <String, List<ProductRecord>>{};
    final foldedTokenIndex = <String, List<ProductRecord>>{};

    for (final product in products) {
      final barcode = normalizeBarcode(product.barcode ?? '');
      if (barcode.isNotEmpty) barcodeIndex[barcode] = product;

      final name = product.normalizedName.isNotEmpty
          ? normalizeName(product.normalizedName)
          : normalizeName(product.name);
      if (name.isEmpty) continue;
      nameIndex[name] = product;

      final uniqueTokens = name
          .split(' ')
          .where((token) => token.length >= 3)
          .toSet();
      for (final token in uniqueTokens) {
        (tokenIndex[token] ??= <ProductRecord>[]).add(product);
        final folded = _foldOcrToken(token);
        if (folded.isNotEmpty) {
          (foldedTokenIndex[folded] ??= <ProductRecord>[]).add(product);
        }
      }
    }

    _indexedProducts = products;
    _barcodeIndex = barcodeIndex;
    _nameIndex = nameIndex;
    _tokenIndex = tokenIndex;
    _foldedTokenIndex = foldedTokenIndex;
  }

  List<ProductRecord> _candidateProducts(
    String queryName,
    List<ProductRecord> allProducts,
  ) {
    final unique = <String, ProductRecord>{};
    final tokens = queryName
        .split(' ')
        .where((token) => token.length >= 3)
        .toList();

    for (final token in tokens) {
      for (final product in _tokenIndex[token] ?? const <ProductRecord>[]) {
        unique[product.id] = product;
      }
      final folded = _foldOcrToken(token);
      for (final product in
          _foldedTokenIndex[folded] ?? const <ProductRecord>[]) {
        unique[product.id] = product;
      }
    }

    // If OCR changed every significant token, fall back to the complete local
    // list so accuracy is preserved. Normal scans usually stay in the much
    // smaller indexed candidate set.
    if (unique.isEmpty) return allProducts;
    return unique.values.toList(growable: false);
  }

  String _foldOcrToken(String value) => value
      .replaceAll('0', 'o')
      .replaceAll('1', 'i')
      .replaceAll('l', 'i')
      .replaceAll('5', 's')
      .replaceAll('8', 'b')
      .replaceAll('2', 'z')
      .replaceAll('9', 'g');

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
