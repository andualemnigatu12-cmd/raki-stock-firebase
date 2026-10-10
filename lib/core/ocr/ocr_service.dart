import 'dart:async';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OcrResult {
  const OcrResult({
    required this.rawText,
    required this.suggestedName,
    required this.primaryText,
  });

  final String? rawText;
  final String? suggestedName;
  final String? primaryText;
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
          const OcrResult(rawText: null, suggestedName: null, primaryText: null),
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
    final result =
        await _recognizer.processImage(InputImage.fromFilePath(imagePath));
    final raw = result.text.trim();
    final suggestion = _suggestProductName(result);
    return OcrResult(
      rawText: raw.isEmpty ? null : raw,
      suggestedName: suggestion?.name,
      primaryText: suggestion?.primary,
    );
  }

  _NameSuggestion? _suggestProductName(RecognizedText result) {
    final candidates = <_Candidate>[];
    final allText = <String>[];
    var index = 0;

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
              rect: line.boundingBox,
              confidence: line.confidence ?? 0.65,
            ),
          );
        }
        index++;
      }
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
      final uppercase = RegExp(r'[A-Z]').allMatches(candidate.text).length;
      final digits = RegExp(r'\d').allMatches(candidate.text).length;
      final words = candidate.text.split(RegExp(r'\s+')).length;
      final upperRatio = letters == 0 ? 0.0 : uppercase / letters;
      final heightScore = (candidate.height / maxHeight) * 92;
      final areaScore = (candidate.area / maxArea) * 38;
      final compactScore = candidate.text.length <= 28 ? 12 : 0;
      final wordScore = words <= 4 ? 12 : (words <= 6 ? 4 : -10);
      final confidenceScore = candidate.confidence * 10;
      final letterScore = letters >= 3 ? 8 : 0;
      final digitPenalty = digits * 1.8;
      final score = heightScore +
          areaScore +
          upperRatio * 20 +
          compactScore +
          wordScore +
          confidenceScore +
          letterScore -
          digitPenalty;
      return _ScoredCandidate(candidate, score);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final primary = scored.first;
    final selected = <_ScoredCandidate>[primary];

    for (final candidate in scored.skip(1)) {
      final primaryNorm = _normalize(primary.value.text);
      final candidateNorm = _normalize(candidate.value.text);
      if (primaryNorm == candidateNorm ||
          primaryNorm.contains(candidateNorm) ||
          candidateNorm.contains(primaryNorm)) {
        continue;
      }
      final closeEnough = _verticallyClose(primary.value.rect, candidate.value.rect);
      final stillProminent = candidate.value.height >= primary.value.height * 0.55 &&
          candidate.score >= primary.score * 0.70;
      final shortEnough = candidate.value.text.split(RegExp(r'\s+')).length <= 4;
      if (closeEnough && stillProminent && shortEnough) {
        selected.add(candidate);
      }
      break;
    }

    selected.sort((a, b) => a.value.rect.top.compareTo(b.value.rect.top));
    var name = selected
        .map((candidate) => _pretty(candidate.value.text))
        .where((value) => value.isNotEmpty)
        .join(' ')
        .trim();

    if (name.isEmpty) return null;
    final size = _extractSize(allText.join(' '));
    if (size != null && !name.toLowerCase().contains(size.toLowerCase())) {
      name = '$name $size';
    }
    if (name.length > 72) name = name.substring(0, 72).trim();

    return _NameSuggestion(
      name: name,
      primary: _pretty(primary.value.text),
    );
  }

  bool _verticallyClose(Rect a, Rect b) {
    final gap = b.top > a.bottom
        ? b.top - a.bottom
        : a.top > b.bottom
            ? a.top - b.bottom
            : 0.0;
    final reference = a.height > b.height ? a.height : b.height;
    return gap <= reference * 1.8;
  }

  String? _clean(String input) {
    final text = input
        .replaceAll(RegExp(r'[^A-Za-z0-9À-ÿ&+\-\s.]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length < 2 || text.length > 46) return null;
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
    ];
    for (final phrase in blocked) {
      if (lower.contains(phrase)) return null;
    }

    if (RegExp(r'^\d+[\s.,%-]*(ml|l|g|kg|oz|cl|pcs?)?$', caseSensitive: false)
        .hasMatch(text)) {
      return null;
    }
    final digits = RegExp(r'\d').allMatches(text).length;
    if (digits > 6 && digits > text.length ~/ 3) return null;
    return text;
  }

  String? _extractSize(String input) {
    final match = RegExp(
      r'\b(\d+(?:[.,]\d+)?)\s*(ml|l|g|kg|cl|oz)\b',
      caseSensitive: false,
    ).firstMatch(input);
    if (match == null) return null;
    final number = match.group(1)?.replaceAll(',', '.');
    final unit = match.group(2)?.toLowerCase();
    return number == null || unit == null ? null : '$number$unit';
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
    };
    return words.asMap().entries.map((entry) {
      final word = entry.value;
      final lower = word.toLowerCase();
      if (entry.key > 0 && connectors.contains(lower)) return lower;
      if (word.isEmpty) return word;
      if (word.length <= 4 && word == word.toUpperCase()) return word;
      return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
    }).join(' ');
  }

  String _normalize(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

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
    required this.rect,
    required this.confidence,
  });

  final String text;
  final int index;
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

class _NameSuggestion {
  const _NameSuggestion({required this.name, required this.primary});
  final String name;
  final String primary;
}
