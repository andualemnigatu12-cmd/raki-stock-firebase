import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart'
    as barcode_ml;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/data/registration_repository.dart';
import '../../core/ocr/ocr_service.dart';
import '../../core/theme/app_theme.dart';

/// Worker-friendly V2 first-count capture. Every save is PENDING; workers
/// cannot create an approved product or set its official selling price.
class RegistrationPage extends StatefulWidget {
  const RegistrationPage({
    super.key,
    required this.branchId,
    required this.userId,
  });

  final String branchId;
  final String userId;

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  final _repo = RegistrationRepository();
  final _name = TextEditingController();
  final _barcode = TextEditingController();
  final _quantity = TextEditingController();
  final _section = TextEditingController();
  final _packaging = TextEditingController();
  final _ocr = OcrService();
  final _scanner = barcode_ml.BarcodeScanner();

  CameraController? _camera;
  String? _photoPath;
  bool _openingCamera = true;
  bool _capturing = false;
  bool _reading = false;
  bool _saving = false;
  String _status = 'Ready to capture the first product.';
  int _savedCount = 0;
  int _photoToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_openCamera());
  }

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera on this device.');
      final back = cameras.where((c) =>
          c.lensDirection == CameraLensDirection.back);
      final selected = back.isNotEmpty ? back.first : cameras.first;
      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      setState(() => _openingCamera = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _openingCamera = false;
          _status = 'Camera unavailable. Check camera permissions.';
        });
      }
    }
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized ||
        camera.value.isTakingPicture || _capturing || _saving) return;
    setState(() {
      _capturing = true;
      _status = 'Capturing...';
    });
    try {
      final image = await camera.takePicture();
      final token = ++_photoToken;
      if (!mounted) return;
      setState(() {
        _photoPath = image.path;
        _reading = true;
        _status = 'Photo ready. Enter quantity while scanning.';
      });
      unawaited(_readText(image.path, token));
    } catch (_) {
      if (mounted) setState(() => _status = 'Camera failed. Try again.');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _readText(String path, int token) async {
    try {
      final codes = await _scanner
          .processImage(barcode_ml.InputImage.fromFilePath(path))
          .timeout(const Duration(milliseconds: 2000));
      if (codes.isNotEmpty && mounted && token == _photoToken &&
          _barcode.text.trim().isEmpty) {
        _barcode.text = codes.first.rawValue ?? '';
      }
    } catch (_) {}

    try {
      final result = await _ocr
          .readProduct(path)
          .timeout(const Duration(milliseconds: 4000));
      if (mounted && token == _photoToken) {
        if (_name.text.trim().isEmpty) {
          _name.text = result.suggestedName ?? '';
        }
        if (_packaging.text.trim().isEmpty) {
          _packaging.text = result.rawText ?? '';
        }
      }
    } catch (_) {
      // Difficult scripts/fonts are still allowed: owner reviews the text.
    }
    if (mounted && token == _photoToken) {
      setState(() {
        _reading = false;
        _status = 'Review the name, enter quantity, then Save & Next.';
      });
    }
  }

  Future<String> _retainPhoto(String sourcePath, String entryId) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'raki_v2_photos'));
    await dir.create(recursive: true);
    final target = p.join(dir.path, '$entryId.jpg');
    await File(sourcePath).copy(target);
    return target;
  }

  Future<void> _save() async {
    if (_saving) return;
    final qty = int.tryParse(_quantity.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _status = 'Enter a positive quantity.');
      return;
    }
    final capturedPhoto = _photoPath;
    if (capturedPhoto == null) {
      setState(() => _status = 'Take the product photo first.');
      return;
    }
    setState(() => _saving = true);
    try {
      // Local, unique photo path never depends on the temporary camera file.
      // Each pending entry is uniquely identified and can never be approved twice.
      final entryId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final durablePhoto = await _retainPhoto(capturedPhoto, entryId);
      _repo.queueEntry(
        branchId: widget.branchId,
        userId: widget.userId,
        quantity: qty,
        nameCandidate: _name.text,
        barcodeCandidate: _barcode.text,
        productText: _packaging.text,
        section: _section.text,
        localPhotoPath: durablePhoto,
        onError: (error) {
          if (mounted) {
            setState(() => _status =
                'Sync error. Keep the app open and check connection. $error');
          }
        },
      );
      if (!mounted) return;
      _savedCount++;
      _photoToken++;
      setState(() {
        _photoPath = null;
        _name.clear();
        _barcode.clear();
        _quantity.clear();
        _packaging.clear();
        _reading = false;
        _status = 'Queued #$_savedCount locally for owner approval. '
            'Check that pending changes finish syncing.';
      });
      FocusManager.instance.primaryFocus?.unfocus();
    } catch (_) {
      if (mounted) setState(() => _status = 'Save failed. Retry this item.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _photoToken++;
    unawaited(_camera?.dispose());
    unawaited(_ocr.dispose());
    unawaited(_scanner.close());
    _name.dispose();
    _barcode.dispose();
    _quantity.dispose();
    _section.dispose();
    _packaging.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register Products · V2'),
        backgroundColor: AppTheme.background,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 36),
          children: [
            const Text(
              'One photo + quantity per occurrence. Stock only changes '
              'after owner review and price confirmation.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 215,
                child: _photoPath != null
                    ? Image.file(
                        File(_photoPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Center(child: Icon(Icons.broken_image)),
                      )
                    : camera != null && camera.value.isInitialized
                        ? CameraPreview(camera)
                        : Center(
                            child: Text(_openingCamera
                                ? 'Opening camera…'
                                : 'Camera unavailable'),
                          ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _capturing || _saving || _openingCamera
                  ? null
                  : _capture,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_photoPath == null
                  ? 'TAKE PHOTO'
                  : 'RETAKE PHOTO'),
            ),
            if (_reading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('Reading barcode and Latin packaging text…'),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Product name and size',
                hintText: 'e.g. Coca-Cola 500 ml (owner can correct)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _barcode,
              decoration: const InputDecoration(
                labelText: 'Barcode (auto-read when visible)',
              ),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _quantity,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Number of selling units *',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _section,
              decoration: const InputDecoration(
                labelText: 'Shelf/section (kept for next item)',
                hintText: 'e.g. A01',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _packaging,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Packaging words (OCR suggestion)',
              ),
            ),
            const SizedBox(height: 12),
            Text(_status),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'SAVING...' : 'SAVE PENDING & NEXT'),
            ),
            const SizedBox(height: 10),
            const Text(
              'Photo is saved on this phone only, NOT uploaded to Firebase. '
              'The website can review text and quantities but cannot '
              'display this photo until separate photo sync is configured.',
              style: TextStyle(fontSize: 12, color: AppTheme.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}
