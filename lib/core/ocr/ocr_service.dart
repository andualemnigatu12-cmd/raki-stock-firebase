import 'dart:async';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

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
    // Keep OCR to one native ML Kit pass for speed. Font tolerance is improved
    // below by using both full text lines and smaller text elements/fragments.
    final result =
        await _recognizer.processImage(InputImage.fromFilePath(imagePath));
    final raw = result.text.trim();
    final suggestion = _suggestProductName(result);

    return OcrResult(
      rawText: raw.isEmpty ? null : raw,
      suggestedName: suggestion?.name,
      primaryText: suggestion?.primary,
      confidence: suggestion?.confidence ?? 0,
    );
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
              index: index++,
              blockIndex: blockIndex,
              rect: line.boundingBox,
              confidence: line.confidence ?? _lineConfidence(line),
              fragment: false,
            ),
          );
        }

        // Decorative/cursive packaging sometimes makes ML Kit split a brand
        // into smaller elements even when the complete line is weak. Keep
        // useful element fragments as fallback candidates without doing a
        // second OCR/image-processing pass.
        final elements = line.elements;
        for (final element in elements) {
          final elementText =
              element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
          final elementCleaned = _clean(elementText);
          if (elementCleaned == null ||
              elementCleaned == cleaned ||
              !_looksLikeBrandFragment(elementCleaned)) {
            continue;
          }
          candidates.add(
            _Candidate(
              text: elementCleaned,
              index: index++,
              blockIndex: blockIndex,
              rect: element.boundingBox,
              confidence: element.confidence ?? line.confidence ?? 0.48,
              fragment: true,
            ),
          );
        }

        // Also join neighboring OCR elements. This helps names where a script
        // or logo-like font causes one word to be split into two visual pieces.
        if (elements.length >= 2) {
          for (var i = 0; i < elements.length - 1; i++) {
            final first = elements[i];
            final second = elements[i + 1];
            final joined = '${first.text} ${second.text}'
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            final joinedCleaned = _clean(joined);
            if (joinedCleaned == null ||
                joinedCleaned == cleaned ||
                !_looksLikeBrandFragment(joinedCleaned)) {
              continue;
            }
            candidates.add(
              _Candidate(
                text: joinedCleaned,
                index: index++,
                blockIndex: blockIndex,
                rect: _union(first.boundingBox, second.boundingBox),
                confidence: _average(
                  first.confidence ?? line.confidence ?? 0.48,
                  second.confidence ?? line.confidence ?? 0.48,
                ),
                fragment: true,
              ),
            );
          }
        }
      }
      blockIndex++;
    }

    if (candidates.isEmpty) return null;

    var maxHeight = 1.0;
    var maxArea = 1.0;
    var minLeft = candidates.first.rect.left;
    var maxRight = candidates.first.rect.right;

    for (final candidate in candidates) {
      if (candidate.height > maxHeight) maxHeight = candidate.height;
      if (candidate.area > maxArea) maxArea = candidate.area;
      if (candidate.rect.left < minLeft) minLeft = candidate.rect.left;
      if (candidate.rect.right > maxRight) maxRight = candidate.rect.right;
    }

    final labelCenterX = (minLeft + maxRight) / 2;
    final labelWidth = (maxRight - minLeft).abs().clamp(1.0, double.infinity);

    final scored = candidates.map((candidate) {
      final letters = RegExp(r'[A-Za-zÀ-ÿ]').allMatches(candidate.text).length;
      final uppercase = RegExp(r'[A-ZÀ-Þ]').allMatches(candidate.text).length;
      final lowercase = RegExp(r'[a-zà-ÿ]').allMatches(candidate.text).length;
      final digits = RegExp(r'\d').allMatches(candidate.text).length;
      final words = candidate.text.split(RegExp(r'\s+')).length;
      final upperRatio = letters == 0 ? 0.0 : uppercase / letters;
      final letterRatio = candidate.text.isEmpty ? 0.0 : letters / candidate.text.length;
      final heightScore = (candidate.height / maxHeight) * 90;
      final areaScore = (candidate.area / maxArea) * 27;
      final confidenceScore = candidate.confidence * 14;
      final compactScore = candidate.text.length <= 44 ? 14.0 : 5.0;
      final wordScore = words <= 5 ? 14.0 : (words <= 8 ? 8.0 : -4.0);
      final centerX = (candidate.rect.left + candidate.rect.right) / 2;
      final centerDistance = (centerX - labelCenterX).abs() / labelWidth;
      final centerScore = (1 - centerDistance.clamp(0.0, 1.0)) * 12;
      final letterScore = letters >= 3 ? 10.0 : 0.0;
      final brandLikeScore = letterRatio >= 0.65 && digits <= 2 ? 12.0 : 0.0;
      final mixedCaseScore = uppercase > 0 && lowercase > 0 ? 4.0 : 0.0;
      final fragmentPenalty = candidate.fragment ? 6.0 : 0.0;
      final digitPenalty = digits * 0.9;

      // Do not over-reward all-caps. Script/cursive and logo fonts are often
      // mixed/lower case, so geometry and letter density matter more.
      final score = heightScore +
          areaScore +
          confidenceScore +
          compactScore +
          wordScore +
          centerScore +
          letterScore +
          brandLikeScore +
          mixedCaseScore +
          upperRatio * 6 -
          fragmentPenalty -
          digitPenalty;
      return _ScoredCandidate(candidate, score);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final primary = scored.first;
    final related = <_RelatedCandidate>[];

    for (final candidate in scored.skip(1)) {
      if (_isDuplicate(primary.value.text, candidate.value.text)) continue;

      final sameBlock = candidate.value.blockIndex == primary.value.blockIndex;
      final overlap =
          _horizontalOverlapRatio(primary.value.rect, candidate.value.rect);
      final alignment = _centerAlignment(primary.value.rect, candidate.value.rect);
      final gap = _verticalGap(primary.value.rect, candidate.value.rect);
      final refHeight = _maxDouble(primary.value.height, candidate.value.height);
      final heightRatio = candidate.value.height / primary.value.height;
      final close = gap <= refHeight * 6.5;
      final aligned = overlap >= 0.07 || alignment >= 0.38;
      final readable = heightRatio >= 0.10;
      final confidenceOk = candidate.value.confidence >= 0.10;

      if (!(sameBlock || (close && aligned))) continue;
      if (!readable || !confidenceOk) continue;

      final relationScore =
          (sameBlock ? 48.0 : 0.0) +
          overlap * 28 +
          alignment * 26 +
          _minDouble(heightRatio, 1.0) * 20 +
          candidate.value.confidence * 10 -
          (gap / refHeight) * 3;

      related.add(_RelatedCandidate(candidate, relationScore));
    }

    related.sort((a, b) => b.relationScore.compareTo(a.relationScore));

    final selected = <_ScoredCandidate>[primary];
    for (final relatedCandidate in related) {
      if (selected.length >= 8) break;
      final candidate = relatedCandidate.scored;
      final normalized = _normalize(candidate.value.text);
      final duplicate = selected.any((existing) {
        final other = _normalize(existing.value.text);
        return other == normalized ||
            other.contains(normalized) ||
            normalized.contains(other);
      });
      if (!duplicate) selected.add(candidate);
    }

    selected.sort((a, b) {
      final top = a.value.rect.top.compareTo(b.value.rect.top);
      if (top != 0) return top;
      return a.value.rect.left.compareTo(b.value.rect.left);
    });

    final parts = <String>[];
    for (final selectedCandidate in selected) {
      final pretty = _pretty(selectedCandidate.value.text);
      if (pretty.isEmpty) continue;
      final normalized = _normalize(pretty);
      final duplicate = parts.any((existing) {
        final other = _normalize(existing);
        return other == normalized ||
            other.contains(normalized) ||
            normalized.contains(other);
      });
      if (!duplicate) parts.add(pretty);
    }

    var name = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) return null;

    final size = _extractSize(allText.join(' '));
    if (size != null && !_normalize(name).contains(_normalize(size))) {
      name = '$name $size';
    }

    if (name.length > 180) name = name.substring(0, 180).trim();

    final averageConfidence = selected
            .map((candidate) => candidate.value.confidence)
            .fold<double>(0, (total, value) => total + value) /
        selected.length;

    return _NameSuggestion(
      name: name,
      primary: _pretty(primary.value.text),
      confidence: averageConfidence,
    );
  }

  double _lineConfidence(TextLine line) {
    if (line.elements.isEmpty) return 0.55;
    var total = 0.0;
    var count = 0;
    for (final element in line.elements) {
      final confidence = element.confidence;
      if (confidence == null) continue;
      total += confidence;
      count++;
    }
    return count == 0 ? 0.55 : total / count;
  }

  bool _looksLikeBrandFragment(String text) {
    final letters = RegExp(r'[A-Za-zÀ-ÿ]').allMatches(text).length;
    final digits = RegExp(r'\d').allMatches(text).length;
    if (letters < 3) return false;
    if (digits > letters) return false;
    return text.length <= 48;
  }

  Rect _union(Rect a, Rect b) => Rect.fromLTRB(
        _minDouble(a.left, b.left),
        _minDouble(a.top, b.top),
        _maxDouble(a.right, b.right),
        _maxDouble(a.bottom, b.bottom),
      );

  double _average(double a, double b) => (a + b) / 2;

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
    return _maxDouble(0, 1 - distance / reference);
  }

  double _verticalGap(Rect a, Rect b) {
    if (b.top > a.bottom) return b.top - a.bottom;
    if (a.top > b.bottom) return a.top - b.bottom;
    return 0;
  }

  String? _clean(String input) {
    final text = input
        .replaceAll(RegExp(r"[^A-Za-z0-9À-ÿ&+'\-\s.,]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (text.length < 2 || text.length > 120) return null;
    if (!RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(text)) return null;

    final lower = text.toLowerCase();
    const blocked = <String>[
      'ingredients',
      'nutrition facts',
      'nutritional information',
      'warning',
      'directions',
      'manufactured by',
      'distributed by',
      'customer care',
      'telephone',
      'www.',
      'http',
      'instagram',
      'facebook',
      'best before',
      'expiry',
      'exp date',
      'batch no',
      'lot no',
      'barcode',
      'calories',
      'daily value',
      'keep away',
      'consumer service',
      'recycling',
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
    if (digits > 9 && digits > text.length ~/ 3) return null;
    return text;
  }

  String? _extractSize(String input) {
    final match = RegExp(
      r'\b(\d+(?:[.,]\d+)?)\s*(ml|l|g|kg|cl|oz|fl\s*oz|pcs?|pack)\b',
      caseSensitive: false,
    ).firstMatch(input);
    if (match == null) return null;
    final number = match.group(1)?.replaceAll(',', '.');
    final unit = match.group(2)?.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (number == null || unit == null) return null;
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

      // Preserve mixed-case brand spelling when OCR provides it (for example
      // iPhone/eBay-like marks) rather than forcing everything to title case.
      final hasUpper = RegExp(r'[A-ZÀ-Þ]').hasMatch(word);
      final hasLower = RegExp(r'[a-zà-ÿ]').hasMatch(word);
      if (hasUpper && hasLower && word.substring(1).contains(RegExp(r'[A-Z]'))) {
        return word;
      }

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
    required this.fragment,
  });

  final String text;
  final int index;
  final int blockIndex;
  final Rect rect;
  final double confidence;
  final bool fragment;

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
