import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OcrResult {
  const OcrResult({required this.rawText, required this.suggestedName});
  final String? rawText;
  final String? suggestedName;
}

class OcrService {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  Future<OcrResult> readProduct(String imagePath) async {
    final result = await _recognizer.processImage(InputImage.fromFilePath(imagePath));
    final raw = result.text.trim();
    return OcrResult(
      rawText: raw.isEmpty ? null : raw,
      suggestedName: _suggestProductName(result),
    );
  }

  String? _suggestProductName(RecognizedText result) {
    final candidates = <_Candidate>[];
    final allText = <String>[];
    var index = 0;

    for (final block in result.blocks) {
      for (final line in block.lines) {
        final raw = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (raw.isEmpty) continue;
        allText.add(raw);
        final cleaned = _clean(raw);
        if (cleaned == null) {
          index++;
          continue;
        }

        final letters = RegExp(r'[A-Za-zÀ-ÿ]').allMatches(cleaned).length;
        final uppercase = RegExp(r'[A-Z]').allMatches(cleaned).length;
        final digits = RegExp(r'\d').allMatches(cleaned).length;
        final wordCount = cleaned.split(RegExp(r'\s+')).length;
        final compactBonus = cleaned.length <= 24 ? 18 : 5;
        final earlyBonus = index < 7 ? (7 - index) * 2 : 0;
        final wordBonus = wordCount <= 4 ? 12 : 0;
        final score = letters * 3 + uppercase * 2 + compactBonus + earlyBonus + wordBonus - digits * 3;

        candidates.add(_Candidate(cleaned, index, score));
        index++;
      }
    }

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));

    final selected = <_Candidate>[];
    for (final candidate in candidates) {
      final normalized = _normalize(candidate.text);
      if (selected.any((e) {
        final existing = _normalize(e.text);
        return existing == normalized || existing.contains(normalized) || normalized.contains(existing);
      })) {
        continue;
      }
      selected.add(candidate);
      if (selected.length == 3) break;
    }

    selected.sort((a, b) => a.index.compareTo(b.index));
    var name = selected.map((e) => _pretty(e.text)).where((e) => e.isNotEmpty).join(' ').trim();
    if (name.isEmpty) return null;

    final size = _extractSize(allText.join(' '));
    if (size != null && !name.toLowerCase().contains(size.toLowerCase())) {
      name = '$name $size';
    }
    if (name.length > 72) name = name.substring(0, 72).trim();
    return name;
  }

  String? _clean(String input) {
    var text = input
        .replaceAll(RegExp(r'[^A-Za-z0-9À-ÿ&+\-\s.]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length < 2 || text.length > 46) return null;
    if (!RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(text)) return null;

    final lower = text.toLowerCase();
    const blocked = <String>[
      'ingredients', 'nutrition', 'nutritional', 'warning', 'directions',
      'manufactured', 'distributed', 'customer care', 'telephone', 'phone',
      'www.', 'http', 'instagram', 'facebook', 'made in', 'product of',
      'best before', 'expiry', 'exp date', 'batch', 'lot no', 'barcode',
      'protein', 'carbohydrate', 'sodium', 'sugar', 'calories', 'kcal',
      'keep away', 'storage', 'copyright', 'trademark',
    ];
    for (final phrase in blocked) {
      if (lower.contains(phrase)) return null;
    }

    if (RegExp(r'^\d+[\s.,%-]*(ml|l|g|kg|oz|cl|pcs?)?$', caseSensitive: false).hasMatch(text)) {
      return null;
    }
    final digits = RegExp(r'\d').allMatches(text).length;
    if (digits > 6 && digits > text.length ~/ 3) return null;
    return text;
  }

  String? _extractSize(String input) {
    final match = RegExp(r'\b(\d+(?:[.,]\d+)?)\s*(ml|l|g|kg|cl|oz)\b', caseSensitive: false).firstMatch(input);
    if (match == null) return null;
    final number = match.group(1)?.replaceAll(',', '.');
    final unit = match.group(2)?.toLowerCase();
    return number == null || unit == null ? null : '$number$unit';
  }

  String _pretty(String input) {
    final words = input.split(RegExp(r'\s+'));
    const connectors = {'de', 'da', 'do', 'dos', 'das', 'com', 'e', 'of', 'for', 'with'};
    return words.asMap().entries.map((entry) {
      final word = entry.value;
      final lower = word.toLowerCase();
      if (entry.key > 0 && connectors.contains(lower)) return lower;
      if (word.isEmpty) return word;
      return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
    }).join(' ');
  }

  String _normalize(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<void> dispose() => _recognizer.close();
}

class _Candidate {
  const _Candidate(this.text, this.index, this.score);
  final String text;
  final int index;
  final int score;
}
