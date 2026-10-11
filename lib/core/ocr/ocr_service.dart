import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

class OcrResult {
  const OcrResult({
    required this.rawText,
    required this.suggestedName,
    required this.primaryText,
    this.confidence = 0,
  });

  final String? rawText;
  final String? suggestedName;
  final String? primaryText;
  final double confidence;
}

class OcrService {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  Future<OcrResult> readProduct(String imagePath) {
    final completer = Completer<OcrResult>();
    _tail = _tail.then((_) async {
      if (_closed) {
        completer.complete(
          const OcrResult(
            rawText: null,
            suggestedName: null,
            primaryText: null,
          ),
        );
        return;
      }
      try {
        completer.complete(await _readNow(imagePath));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<OcrResult> _readNow(String imagePath) async {
    final fullResult =
        await _recognizer.processImage(InputImage.fromFilePath(imagePath));
    final fullSuggestion = _suggestProductName(fullResult);

    RecognizedText? enhancedResult;
    String? enhancedPath;
    try {
      enhancedPath = await _createEnhancedLabelCrop(imagePath);
      if (enhancedPath != null) {
        enhancedResult = await _recognizer.processImage(
          InputImage.fromFilePath(enhancedPath),
        );
      }
    } catch (_) {
      // The original high-resolution OCR result is still usable if image
      // preprocessing is unsupported or the temporary crop cannot be created.
    } finally {
      if (enhancedPath != null) {
        try {
          await File(enhancedPath).delete();
        } catch (_) {}
      }
    }

    final enhancedSuggestion = enhancedResult == null
        ? null
        : _suggestProductName(enhancedResult);
    final suggestion = _chooseSuggestion(fullSuggestion, enhancedSuggestion);
    final raw = _mergeRawText(
      fullResult.text,
      enhancedResult?.text,
    );

    return OcrResult(
      rawText: raw,
      suggestedName: suggestion?.name,
      primaryText: suggestion?.primary,
      confidence: suggestion?.confidence ?? 0,
    );
  }

  Future<String?> _createEnhancedLabelCrop(String imagePath) async {
    final file = File(imagePath);
    final bytes = await file.readAsBytes();
    final source = img.decodeImage(bytes);
    if (source == null || source.width < 240 || source.height < 240) return null;

    // Most retail labels occupy the central ~90% of the object. Removing the
    // extreme edges reduces background noise while keeping brand + variant +
    // size text. The crop is then enlarged and contrast-balanced for small text.
    final x = (source.width * 0.05).round();
    final y = (source.height * 0.10).round();
    final width = (source.width * 0.90).round().clamp(1, source.width - x);
    final height = (source.height * 0.80).round().clamp(1, source.height - y);
    var label = img.copyCrop(
      source,
      x: x,
      y: y,
      width: width,
      height: height,
    );

    final desiredWidth = label.width < 1800 ? 1800 : label.width;
    final safeWidth = desiredWidth > 2400 ? 2400 : desiredWidth;
    if (safeWidth != label.width) {
      label = img.copyResize(
        label,
        width: safeWidth,
        interpolation: img.Interpolation.cubic,
      );
    }

    label = img.adjustColor(
      label,
      contrast: 1.16,
      brightness: 1.03,
      saturation: 0.92,
    );

    final tempPath = '$imagePath.ocr-label.jpg';
    await File(tempPath).writeAsBytes(img.encodeJpg(label, quality: 95));
    return tempPath;
  }

  String? _mergeRawText(String first, String? second) {
    final lines = <String>[];
    final seen = <String>{};
    for (final source in [first, if (second != null) second]) {
      for (final line in source.split(RegExp(r'[\r\n]+'))) {
        final cleaned = line.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (cleaned.isEmpty) continue;
        final key = _normalize(cleaned);
        if (key.isEmpty || seen.contains(key)) continue;
        seen.add(key);
        lines.add(cleaned);
      }
    }
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  _NameSuggestion? _chooseSuggestion(
    _NameSuggestion? full,
    _NameSuggestion? enhanced,
  ) {
    if (full == null) return enhanced;
    if (enhanced == null) return full;

    final a = _normalize(full.name);
    final b = _normalize(enhanced.name);
    if (a == b) {
      return enhanced.confidence >= full.confidence ? enhanced : full;
    }

    // If one pass captured the other plus extra useful words, prefer the more
    // complete phrase unless its OCR confidence is dramatically worse.
    if ((a.contains(b) || b.contains(a)) &&
        (full.confidence - enhanced.confidence).abs() < 0.22) {
      return full.name.length >= enhanced.name.length ? full : enhanced;
    }

    double score(_NameSuggestion value) {
      final words = value.name
          .split(RegExp(r'\s+'))
          .where((word) => word.length > 1)
          .length;
      final completeness = words.clamp(1, 7) * 0.045;
      final lengthBonus = value.name.length.clamp(0, 90) / 900;
      return value.confidence + completeness + lengthBonus;
    }

    return score(enhanced) > score(full) ? enhanced : full;
  }

  _NameSuggestion? _suggestProductName(RecognizedText result) {
    final candidates = <_Candidate>[];
    final allText = <String>[];
    var index = 0;
    var blockIndex = 0;

    for (final block in result.blocks) {
      for (final line in block.lines) {
        final raw = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (raw.isEmpty) continue;
        allText.add(raw);
        final cleaned = _clean(raw);
        if (cleaned != null) {
          candidates.add(
            _Candidate(
              text: cleaned,
              index: index,
              blockIndex: blockIndex,
              rect: line.boundingBox,
              confidence: line.confidence ?? 0.65,
            ),
          );
        }
        index++;
      }
      blockIndex++;
    }

    if (candidates.isEmpty) return null;

    var maxHeight = 1.0;
    var maxArea = 1.0;
    for (final candidate in candidates) {
      if (candidate.height > maxHeight) maxHeight = candidate.height;
      if (candidate.area > maxArea) maxArea = candidate.area;
    }

    final scored = candidates.map((candidate) {
      final letters = RegExp(r'[A-Za-zÀ-ÿ]').allMatches(candidate.text).length;
      final uppercase = RegExp(r'[A-ZÀ-Þ]').allMatches(candidate.text).length;
      final digits = RegExp(r'\d').allMatches(candidate.text).length;
      final words = candidate.text.split(RegExp(r'\s+')).length;
      final upperRatio = letters == 0 ? 0.0 : uppercase / letters;
      final heightScore = (candidate.height / maxHeight) * 96;
      final areaScore = (candidate.area / maxArea) * 34;
      final compactScore = candidate.text.length <= 34 ? 13 : 5;
      final wordScore = words <= 5 ? 13 : (words <= 8 ? 7 : -5);
      final confidenceScore = candidate.confidence * 16;
      final letterScore = letters >= 3 ? 9 : 0;
      final digitPenalty = digits * 1.2;
      final score = heightScore +
          areaScore +
          upperRatio * 18 +
          compactScore +
          wordScore +
          confidenceScore +
          letterScore -
          digitPenalty;
      return _ScoredCandidate(candidate, score);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final primary = scored.first;
    final related = <_RelatedCandidate>[];

    for (final candidate in scored.skip(1)) {
      if (_isDuplicate(primary.value.text, candidate.value.text)) continue;

      final sameBlock = candidate.value.blockIndex == primary.value.blockIndex;
      final overlap = _horizontalOverlapRatio(
        primary.value.rect,
        candidate.value.rect,
      );
      final centerAlignment = _centerAlignment(
        primary.value.rect,
        candidate.value.rect,
      );
      final gap = _verticalGap(primary.value.rect, candidate.value.rect);
      final referenceHeight = _maxDouble(
        primary.value.height,
        candidate.value.height,
      );
      final heightRatio = candidate.value.height / primary.value.height;
      final closeVertically = gap <= referenceHeight * 4.0;
      final aligned = overlap >= 0.14 || centerAlignment >= 0.50;
      final readableSize = heightRatio >= 0.22;
      final usefulConfidence = candidate.value.confidence >= 0.28;

      if (!(sameBlock || (closeVertically && aligned))) continue;
      if (!readableSize || !usefulConfidence) continue;

      final relationScore =
          (sameBlock ? 48.0 : 0.0) +
          overlap * 32 +
          centerAlignment * 24 +
          _minDouble(heightRatio, 1.0) * 20 +
          candidate.value.confidence * 12 -
          (gap / referenceHeight) * 5;
      related.add(_RelatedCandidate(candidate, relationScore));
    }

    related.sort((a, b) => b.relationScore.compareTo(a.relationScore));

    final selected = <_ScoredCandidate>[primary];
    for (final relatedCandidate in related) {
      if (selected.length >= 7) break;
      final candidate = relatedCandidate.scored;
      final normalized = _normalize(candidate.value.text);
      final duplicate = selected.any((existing) {
        final existingNormalized = _normalize(existing.value.text);
        return existingNormalized == normalized ||
            existingNormalized.contains(normalized) ||
            normalized.contains(existingNormalized);
      });
      if (!duplicate) selected.add(candidate);
    }

    selected.sort((a, b) {
      final topCompare = a.value.rect.top.compareTo(b.value.rect.top);
      if (topCompare != 0) return topCompare;
      return a.value.rect.left.compareTo(b.value.rect.left);
    });

    final nameParts = <String>[];
    for (final candidate in selected) {
      final pretty = _pretty(candidate.value.text);
      if (pretty.isEmpty) continue;
      final normalized = _normalize(pretty);
      if (nameParts.any((part) {
        final existing = _normalize(part);
        return existing == normalized ||
            existing.contains(normalized) ||
            normalized.contains(existing);
      })) {
        continue;
      }
      nameParts.add(pretty);
    }

    var name = nameParts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) return null;

    final size = _extractSize(allText.join(' '));
    if (size != null && !_normalize(name).contains(_normalize(size))) {
      name = '$name $size';
    }

    if (name.length > 180) name = name.substring(0, 180).trim();

    final averageConfidence = selected.isEmpty
        ? 0.0
        : selected
                .map((candidate) => candidate.value.confidence)
                .fold<double>(0, (sum, value) => sum + value) /
            selected.length;

    return _NameSuggestion(
      name: name,
      primary: _pretty(primary.value.text),
      confidence: averageConfidence,
    );
  }

  bool _isDuplicate(String a, String b) {
    final first = _normalize(a);
    final second = _normalize(b);
    return first == second || first.contains(second) || second.contains(first);
  }

  double _horizontalOverlapRatio(Rect a, Rect b) {
    final left = _maxDouble(a.left, b.left);
    final right = _minDouble(a.right, b.right);
    final overlap = right - left;
    if (overlap <= 0) return 0;
    final smallerWidth = _minDouble(a.width, b.width);
    if (smallerWidth <= 0) return 0;
    return _minDouble(overlap / smallerWidth, 1);
  }

  double _centerAlignment(Rect a, Rect b) {
    final aCenter = (a.left + a.right) / 2;
    final bCenter = (b.left + b.right) / 2;
    final distance = (aCenter - bCenter).abs();
    final reference = _maxDouble(a.width, b.width);
    if (reference <= 0) return 0;
    return _maxDouble(0, 1 - (distance / reference));
  }

  double _verticalGap(Rect a, Rect b) {
    if (b.top > a.bottom) return b.top - a.bottom;
    if (a.top > b.bottom) return a.top - b.bottom;
    return 0;
  }

  String? _clean(String input) {
    final text = input
        .replaceAll(RegExp(r'[^A-Za-z0-9À-ÿ&+\-\s.,]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length < 2 || text.length > 80) return null;
    if (!RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(text)) return null;

    final lower = text.toLowerCase();
    const blocked = <String>[
      'ingredients',
      'nutrition',
      'nutritional',
      'warning',
      'directions',
      'manufactured',
      'distributed',
      'customer care',
      'telephone',
      'phone',
      'www.',
      'http',
      'instagram',
      'facebook',
      'made in',
      'product of',
      'best before',
      'expiry',
      'exp date',
      'batch',
      'lot no',
      'barcode',
      'protein',
      'carbohydrate',
      'sodium',
      'sugar',
      'calories',
      'kcal',
      'keep away',
      'storage',
      'copyright',
      'trademark',
      'recycle',
      'recycling',
      'consumer service',
      'serving size',
      'daily value',
    ];
    for (final phrase in blocked) {
      if (lower.contains(phrase)) return null;
    }

    if (RegExp(
      r'^\d+[\s.,%-]*(ml|l|g|kg|oz|cl|pcs?|pack)?$',
      caseSensitive: false,
    ).hasMatch(text)) {
      return null;
    }
    final digits = RegExp(r'\d').allMatches(text).length;
    if (digits > 8 && digits > text.length ~/ 3) return null;
    return text;
  }

  String? _extractSize(String input) {
    final match = RegExp(
      r'\b(\d+(?:[.,]\d+)?)\s*(ml|l|g|kg|cl|oz|fl\s*oz|pcs?|pack)\b',
      caseSensitive: false,
    ).firstMatch(input);
    if (match == null) return null;
    final number = match.group(1)?.replaceAll(',', '.');
    var unit = match.group(2)?.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (number == null || unit == null) return null;
    if (unit == 'fl oz') unit = 'fl oz';
    return '$number$unit';
  }

  String _pretty(String input) {
    final words = input.split(RegExp(r'\s+'));
    const connectors = {
      'de',
      'da',
      'do',
      'dos',
      'das',
      'com',
      'e',
      'of',
      'for',
      'with',
      'and',
      'the',
    };
    return words.asMap().entries.map((entry) {
      final word = entry.value;
      final lower = word.toLowerCase();
      if (entry.key > 0 && connectors.contains(lower)) return lower;
      if (word.isEmpty) return word;
      if (word.length <= 4 && word == word.toUpperCase()) return word;
      if (RegExp(r'^\d').hasMatch(word)) return word;
      return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
    }).join(' ');
  }

  String _normalize(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  double _maxDouble(double a, double b) => a > b ? a : b;
  double _minDouble(double a, double b) => a < b ? a : b;

  Future<void> dispose() async {
    _closed = true;
    await _tail;
    await _recognizer.close();
  }
}

class _Candidate {
  const _Candidate({
    required this.text,
    required this.index,
    required this.blockIndex,
    required this.rect,
    required this.confidence,
  });

  final String text;
  final int index;
  final int blockIndex;
  final Rect rect;
  final double confidence;

  double get height => rect.height <= 0 ? 1 : rect.height;
  double get area {
    final value = rect.width * rect.height;
    return value <= 0 ? 1 : value;
  }
}

class _ScoredCandidate {
  const _ScoredCandidate(this.value, this.score);
  final _Candidate value;
  final double score;
}

class _RelatedCandidate {
  const _RelatedCandidate(this.scored, this.relationScore);
  final _ScoredCandidate scored;
  final double relationScore;
}

class _NameSuggestion {
  const _NameSuggestion({
    required this.name,
    required this.primary,
    required this.confidence,
  });

  final String name;
  final String primary;
  final double confidence;
}
