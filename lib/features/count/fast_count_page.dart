import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/data/inventory_repository.dart';
import '../../core/ocr/ocr_service.dart';
import '../../core/theme/app_theme.dart';

class FastCountPage extends StatefulWidget {
  const FastCountPage({
    super.key,
    required this.sessionId,
    required this.branchId,
    required this.userId,
  });

  final String sessionId;
  final String branchId;
  final String userId;

  @override
  State<FastCountPage> createState() => _FastCountPageState();
}

class _FastCountPageState extends State<FastCountPage> {
  final _picker = ImagePicker();
  final _repo = InventoryRepository();
  final _uuid = const Uuid();
  final _qty = TextEditingController();

  String? _photoPath;
  String? _detectedName;
  String? _rawOcr;
  bool _ocrReading = false;
  bool _cameraBusy = false;
  bool _saving = false;
  int _photoToken = 0;
  String? _message;

  String get _queueKey => 'raki-photo-queue-${widget.sessionId}';

  @override
  void initState() {
    super.initState();
    unawaited(_retryPhotoQueue());
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  Future<OcrResult?> _readOcr(String path) async {
    final service = OcrService();
    try {
      return await service.readProduct(path);
    } catch (_) {
      return null;
    } finally {
      await service.dispose();
    }
  }

  Future<void> _takePhoto() async {
    if (_cameraBusy) return;
    setState(() {
      _cameraBusy = true;
      _message = null;
    });
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 95,
        maxWidth: 2400,
        maxHeight: 2400,
        requestFullMetadata: false,
      );
      if (picked == null || !mounted) return;
      final token = ++_photoToken;
      setState(() {
        _photoPath = picked.path;
        _detectedName = null;
        _rawOcr = null;
        _ocrReading = true;
      });
      unawaited(_previewOcr(picked.path, token));
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not open the camera. Try again.');
    } finally {
      if (mounted) setState(() => _cameraBusy = false);
    }
  }

  Future<void> _previewOcr(String path, int token) async {
    final result = await _readOcr(path);
    if (!mounted || token != _photoToken || _photoPath != path) return;
    setState(() {
      _ocrReading = false;
      _detectedName = result?.suggestedName;
      _rawOcr = result?.rawText;
    });
  }

  Future<String> _makeDurable(String sourcePath, String itemId) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'raki_stock_photos', widget.sessionId));
    await dir.create(recursive: true);
    final target = p.join(dir.path, '$itemId.jpg');
    await File(sourcePath).copy(target);
    return target;
  }

  Future<void> _saveAndNext() async {
    final sourcePath = _photoPath;
    final quantity = int.tryParse(_qty.text.trim());
    if (sourcePath == null) {
      setState(() => _message = 'Take a product photo first.');
      return;
    }
    if (quantity == null || quantity <= 0) {
      setState(() => _message = 'Enter the quantity.');
      return;
    }
    if (_saving) return;

    setState(() => _saving = true);
    final itemId = _uuid.v4();
    final tempCode = 'STK-${itemId.replaceAll('-', '').substring(0, 6).toUpperCase()}';
    final capturedName = _ocrReading ? null : _detectedName;
    final capturedRaw = _ocrReading ? null : _rawOcr;

    try {
      final durablePath = await _makeDurable(sourcePath, itemId);
      await _repo.saveCountItem(
        sessionId: widget.sessionId,
        clientEntryId: itemId,
        tempCode: tempCode,
        quantity: quantity,
        userId: widget.userId,
        localCreatedAt: DateTime.now(),
        suggestedName: capturedName,
        rawOcr: capturedRaw,
      );

      await _enqueuePhoto(itemId, durablePath);
      unawaited(_uploadPhoto(itemId, durablePath));
      if (capturedName == null) {
        unawaited(_finishOcrAndPatch(itemId, durablePath));
      }

      if (!mounted) return;
      _photoToken++;
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _photoPath = null;
        _detectedName = null;
        _rawOcr = null;
        _ocrReading = false;
        _qty.clear();
        _message = capturedName == null
            ? 'Saved as $tempCode. Name detection continues in background.'
            : 'Saved as $capturedName.';
      });
      unawaited(_openNextCamera());
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not save this product. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _finishOcrAndPatch(String itemId, String path) async {
    final result = await _readOcr(path);
    try {
      await FirebaseFirestore.instance
          .collection('stock_count_sessions')
          .doc(widget.sessionId)
          .collection('items')
          .doc(itemId)
          .set({
        'rawOcr': result?.rawText,
        'suggestedName': result?.suggestedName,
        'nameState': result?.suggestedName == null ? 'needs_review' : 'auto',
        'ocrSource': result?.suggestedName == null ? null : 'on_device_mlkit',
        'cloudOcrNeeded': result?.suggestedName == null,
      }, SetOptions(merge: true));
    } catch (_) {
      // Firestore retries local writes automatically when connection returns.
    }
  }

  Future<void> _openNextCamera() async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted || _photoPath != null || _cameraBusy) return;
    await _takePhoto();
  }

  Future<void> _enqueuePhoto(String itemId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? <String>[];
    final row = '$itemId|$path';
    if (!queue.contains(row)) queue.add(row);
    await prefs.setStringList(_queueKey, queue);
  }

  Future<void> _dequeuePhoto(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? <String>[];
    queue.removeWhere((row) => row.startsWith('$itemId|'));
    await prefs.setStringList(_queueKey, queue);
  }

  Future<void> _uploadPhoto(String itemId, String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      await _repo.uploadItemPhoto(sessionId: widget.sessionId, itemId: itemId, file: file);
      await _dequeuePhoto(itemId);
    } catch (_) {
      // Keep it queued. Counting never waits for the network.
    }
  }

  Future<void> _retryPhotoQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final queue = List<String>.from(prefs.getStringList(_queueKey) ?? const []);
    for (final row in queue) {
      final split = row.indexOf('|');
      if (split <= 0) continue;
      await _uploadPhoto(row.substring(0, split), row.substring(split + 1));
    }
  }

  Future<void> _finishCount() async {
    await _repo.finalizeSession(widget.sessionId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fast Count', style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.ink)),
            Text('Photo → name → quantity', style: TextStyle(fontSize: 11, color: AppTheme.mutedInk)),
          ],
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _repo.watchItems(widget.sessionId),
        builder: (context, snapshot) {
          final items = snapshot.data?.docs ?? const [];
          final units = items.fold<int>(0, (sum, doc) => sum + ((doc.data()['quantity'] as num?)?.toInt() ?? 0));
          final autoNamed = items.where((doc) => (doc.data()['suggestedName'] as String?)?.trim().isNotEmpty == true).length;

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Row(
                children: [
                  Expanded(child: _MiniMetric(label: 'CAPTURES', value: '${items.length}')),
                  const SizedBox(width: 10),
                  Expanded(child: _MiniMetric(label: 'UNITS', value: '$units')),
                  const SizedBox(width: 10),
                  Expanded(child: _MiniMetric(label: 'AUTO NAMED', value: '$autoNamed')),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_photoPath == null ? 'Photograph the product' : 'Confirm quantity', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 5),
                      Text(_photoPath == null
                          ? 'Keep the front label clear. OCR starts immediately and does not block counting.'
                          : 'The product name is automatic. You only enter how many pieces are here.'),
                      const SizedBox(height: 16),
                      if (_photoPath == null)
                        SizedBox(
                          height: 170,
                          child: FilledButton.icon(
                            onPressed: _cameraBusy ? null : _takePhoto,
                            icon: const Icon(Icons.camera_alt_rounded, size: 30),
                            label: Text(_cameraBusy ? 'OPENING CAMERA…' : 'TAKE PRODUCT PHOTO'),
                          ),
                        )
                      else ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.file(File(_photoPath!), height: 220, fit: BoxFit.cover, cacheWidth: 1000),
                        ),
                        const SizedBox(height: 12),
                        _NameResult(reading: _ocrReading, name: _detectedName),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _qty,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(labelText: 'Quantity', hintText: 'e.g. 12'),
                          onSubmitted: (_) => _saveAndNext(),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _saving ? null : _saveAndNext,
                          child: Text(_saving ? 'SAVING…' : 'SAVE & NEXT PRODUCT'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(onPressed: _cameraBusy ? null : _takePhoto, child: const Text('Retake photo')),
                      ],
                    ],
                  ),
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(14)),
                  child: Text(_message!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.ink, fontWeight: FontWeight.w700)),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: Text('Recent products', style: Theme.of(context).textTheme.titleLarge)),
                  TextButton(onPressed: items.isEmpty ? null : _finishCount, child: const Text('Finish count')),
                ],
              ),
              const SizedBox(height: 8),
              if (items.isEmpty)
                const Card(child: Padding(padding: EdgeInsets.all(20), child: Text('Your counted products will appear here.')))
              else
                ...items.take(5).map((doc) {
                  final data = doc.data();
                  final name = (data['suggestedName'] as String?)?.trim();
                  final title = name?.isNotEmpty == true ? name! : (data['tempCode'] as String? ?? 'Unnamed product');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(12)),
                          child: Icon(name?.isNotEmpty == true ? Icons.auto_awesome_rounded : Icons.inventory_2_outlined, color: AppTheme.primary),
                        ),
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(name?.isNotEmpty == true ? 'AUTO NAME' : 'TEMP CODE • REVIEW LATER'),
                        trailing: Text('×${data['quantity'] ?? 0}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: AppTheme.ink)),
                      ),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(17), border: Border.all(color: AppTheme.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 8, color: AppTheme.mutedInk, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(value, style: const TextStyle(fontSize: 20, color: AppTheme.ink, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _NameResult extends StatelessWidget {
  const _NameResult({required this.reading, required this.name});
  final bool reading;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final detected = name?.trim().isNotEmpty == true;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: detected ? const Color(0xFFEAF8F0) : AppTheme.primarySoft,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          Icon(reading ? Icons.hourglass_top_rounded : detected ? Icons.auto_awesome_rounded : Icons.help_outline_rounded,
              color: detected ? AppTheme.success : AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(reading ? 'Reading product label…' : detected ? name! : 'No reliable name found yet',
                    style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.ink)),
                const SizedBox(height: 2),
                Text(reading ? 'Enter quantity while OCR works.' : detected ? 'AUTO-DETECTED NAME' : 'We will keep the photo + STK code and retry later.',
                    style: const TextStyle(fontSize: 10, color: AppTheme.mutedInk)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
