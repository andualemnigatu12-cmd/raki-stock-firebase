import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart'
    as ml_barcode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/data/inventory_repository.dart';
import '../../core/data/product_catalog_repository.dart';
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

class _FastCountPageState extends State<FastCountPage>
    with WidgetsBindingObserver {
  final _repo = InventoryRepository();
  final _catalog = ProductCatalogRepository();
  final _uuid = const Uuid();
  final _qty = TextEditingController();
  final _qtyFocus = FocusNode();
  final _ocr = OcrService();
  final _barcodeScanner = ml_barcode.BarcodeScanner();

  CameraController? _camera;
  StreamSubscription<List<ProductRecord>>? _catalogSub;
  List<ProductRecord> _products = const [];
  Future<_CaptureAnalysis>? _analysisFuture;
  ProductMatch? _catalogMatch;
  String? _photoPath;
  String? _detectedName;
  String? _primaryText;
  String? _rawOcr;
  String? _barcode;
  bool _cameraLoading = true;
  bool _cameraBusy = false;
  bool _ocrReading = false;
  bool _saving = false;
  int _photoToken = 0;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadCatalog());
    unawaited(_initCamera());
  }

  Future<void> _loadCatalog() async {
    final cached = await _catalog.loadCached(widget.branchId);
    if (mounted && cached.isNotEmpty) {
      setState(() => _products = cached);
    }
    _catalogSub = _catalog.watchProducts(widget.branchId).listen((products) {
      if (mounted) setState(() => _products = products);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final camera = _camera;
      _camera = null;
      if (camera != null) unawaited(camera.dispose());
    } else if (state == AppLifecycleState.resumed && _camera == null) {
      unawaited(_initCamera());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_catalogSub?.cancel());
    _qty.dispose();
    _qtyFocus.dispose();
    final camera = _camera;
    if (camera != null) unawaited(camera.dispose());
    unawaited(_ocr.dispose());
    unawaited(_barcodeScanner.close());
    super.dispose();
  }

  Future<void> _initCamera() async {
    if (mounted) {
      setState(() {
        _cameraLoading = true;
        _message = null;
      });
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera found.');
      final back = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      try {
        await controller.setJpegImageQuality(86);
      } catch (_) {
        // Some Android camera implementations do not expose JPEG quality.
      }
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {}
      if (!mounted) {
        await controller.dispose();
        return;
      }
      final old = _camera;
      _camera = controller;
      if (old != null) unawaited(old.dispose());
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Camera could not start. Tap Retry.');
      }
    } finally {
      if (mounted) setState(() => _cameraLoading = false);
    }
  }

  Future<void> _focusCamera(Offset position, Size size) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    final x = (position.dx / size.width).clamp(0.0, 1.0).toDouble();
    final y = (position.dy / size.height).clamp(0.0, 1.0).toDouble();
    final point = Offset(x, y);
    try {
      await camera.setFocusPoint(point);
      await camera.setExposurePoint(point);
    } catch (_) {
      // Tap-to-focus is optional on devices that do not support it.
    }
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null ||
        !camera.value.isInitialized ||
        camera.value.isTakingPicture ||
        _cameraBusy ||
        _saving) {
      return;
    }

    setState(() {
      _cameraBusy = true;
      _message = null;
    });
    try {
      final image = await camera.takePicture();
      final token = ++_photoToken;
      final analysis = _analyzeCapture(image.path);
      _analysisFuture = analysis;
      setState(() {
        _photoPath = image.path;
        _detectedName = null;
        _primaryText = null;
        _rawOcr = null;
        _barcode = null;
        _catalogMatch = null;
        _ocrReading = true;
      });
      _qty.clear();
      _qtyFocus.requestFocus();
      unawaited(
        analysis.then((result) {
          if (!mounted || token != _photoToken || _photoPath != image.path) {
            return;
          }
          setState(() {
            _ocrReading = false;
            _detectedName = result.ocr?.suggestedName;
            _primaryText = result.ocr?.primaryText;
            _rawOcr = result.ocr?.rawText;
            _barcode = result.barcode;
            _catalogMatch = result.catalogMatch;
          });
        }).catchError((_) {
          if (mounted && token == _photoToken) {
            setState(() => _ocrReading = false);
          }
        }),
      );
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not capture. Try again.');
    } finally {
      if (mounted) setState(() => _cameraBusy = false);
    }
  }

  Future<_CaptureAnalysis> _analyzeCapture(String path) async {
    String? barcode;
    try {
      final codes = await _barcodeScanner.processImage(
        ml_barcode.InputImage.fromFilePath(path),
      );
      for (final code in codes) {
        final value = code.rawValue?.trim();
        if (value != null && value.isNotEmpty) {
          barcode = value;
          break;
        }
      }
    } catch (_) {}

    // Exact barcode matches are the fastest and most reliable result. When the
    // product already exists we skip OCR completely and use the reviewed name.
    final barcodeMatch = _catalog.findBestMatch(_products, barcode: barcode);
    if (barcodeMatch != null && barcodeMatch.source == 'barcode') {
      return _CaptureAnalysis(
        ocr: OcrResult(
          rawText: null,
          suggestedName: barcodeMatch.product.name,
          primaryText: barcodeMatch.product.name,
          confidence: 1,
        ),
        barcode: barcode,
        catalogMatch: barcodeMatch,
      );
    }

    OcrResult? ocr;
    try {
      ocr = await _ocr.readProduct(path);
    } catch (_) {}

    ProductMatch? nameMatch;
    if (ocr?.suggestedName?.trim().isNotEmpty == true) {
      nameMatch = _catalog.findBestMatch(
        _products,
        barcode: barcode,
        ocrName: ocr!.suggestedName,
      );
    }

    // Only replace OCR spelling when the existing catalog match is strong.
    // Lower-confidence cases stay as OCR suggestions for owner review.
    if (nameMatch != null && nameMatch.confidence >= 0.82 && ocr != null) {
      ocr = OcrResult(
        rawText: ocr.rawText,
        suggestedName: nameMatch.product.name,
        primaryText: ocr.primaryText,
        confidence: nameMatch.confidence,
      );
    }

    return _CaptureAnalysis(
      ocr: ocr,
      barcode: barcode,
      catalogMatch: nameMatch,
    );
  }

  Future<String> _makeDurable(String sourcePath, String itemId) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(
      p.join(root.path, 'raki_stock_photos', widget.sessionId),
    );
    await dir.create(recursive: true);
    final target = p.join(dir.path, '$itemId.jpg');
    await File(sourcePath).copy(target);
    return target;
  }

  Future<void> _saveAndNext() async {
    final sourcePath = _photoPath;
    final quantity = int.tryParse(_qty.text.trim());
    if (sourcePath == null) {
      setState(() => _message = 'Capture the product first.');
      return;
    }
    if (quantity == null || quantity <= 0) {
      setState(() => _message = 'Enter the quantity.');
      _qtyFocus.requestFocus();
      return;
    }
    if (_saving) return;

    setState(() => _saving = true);
    final itemId = _uuid.v4();
    final tempCode =
        'STK-${itemId.replaceAll('-', '').substring(0, 6).toUpperCase()}';
    final analysis = _analysisFuture;
    final currentName = _detectedName;
    final currentPrimary = _primaryText;
    final currentRaw = _rawOcr;
    final currentBarcode = _barcode;

    try {
      final durablePath = await _makeDurable(sourcePath, itemId);

      unawaited(
        _repo
            .saveCountItem(
              sessionId: widget.sessionId,
              branchId: widget.branchId,
              clientEntryId: itemId,
              tempCode: tempCode,
              quantity: quantity,
              userId: widget.userId,
              localCreatedAt: DateTime.now(),
              localPhotoPath: durablePath,
              suggestedName: currentName,
              primaryText: currentPrimary,
              rawOcr: currentRaw,
              barcode: currentBarcode,
            )
            .catchError((_) {}),
      );

      if (analysis != null) {
        unawaited(
          analysis.then((result) {
            return _repo.patchRecognizedData(
              sessionId: widget.sessionId,
              itemId: itemId,
              suggestedName: result.ocr?.suggestedName,
              primaryText: result.ocr?.primaryText,
              rawOcr: result.ocr?.rawText,
              barcode: result.barcode,
            );
          }).catchError((_) {}),
        );
      }

      if (!mounted) return;
      _photoToken++;
      _analysisFuture = null;
      setState(() {
        _photoPath = null;
        _detectedName = null;
        _primaryText = null;
        _rawOcr = null;
        _barcode = null;
        _catalogMatch = null;
        _ocrReading = false;
        _qty.clear();
        _message = 'Saved $tempCode. Camera is ready for the next product.';
      });
      FocusManager.instance.primaryFocus?.unfocus();
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not save this product. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _retake() {
    _photoToken++;
    _analysisFuture = null;
    setState(() {
      _photoPath = null;
      _detectedName = null;
      _primaryText = null;
      _rawOcr = null;
      _barcode = null;
      _catalogMatch = null;
      _ocrReading = false;
      _qty.clear();
      _message = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _finishCount() {
    unawaited(_repo.finalizeSession(widget.sessionId).catchError((_) {}));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fast Count',
              style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.ink),
            ),
            Text(
              'Barcode first • improved full-label OCR',
              style: TextStyle(fontSize: 11, color: AppTheme.mutedInk),
            ),
          ],
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _repo.watchItems(widget.sessionId),
        builder: (context, snapshot) {
          final items = snapshot.data?.docs ?? const [];
          final units = items.fold<int>(
            0,
            (total, doc) =>
                total + ((doc.data()['quantity'] as num?)?.toInt() ?? 0),
          );

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
            children: [
              Row(
                children: [
                  Expanded(
                    child: _MiniMetric(label: 'PRODUCTS', value: '${items.length}'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _MiniMetric(label: 'UNITS', value: '$units')),
                ],
              ),
              const SizedBox(height: 12),
              _cameraCard(),
              if (_photoPath != null) ...[
                const SizedBox(height: 12),
                _capturedCard(),
              ],
              if (_message != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primarySoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Recent products',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: items.isEmpty ? null : _finishCount,
                    child: const Text('Finish count'),
                  ),
                ],
              ),
              if (items.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('Captured products will appear here.'),
                  ),
                )
              else
                ...items.take(5).map((doc) {
                  final data = doc.data();
                  final name = (data['suggestedName'] as String?)?.trim();
                  final title = name?.isNotEmpty == true
                      ? name!
                      : (data['tempCode'] as String? ?? 'Unnamed product');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.inventory_2_outlined,
                          color: AppTheme.primary,
                        ),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          data['reviewState'] == 'added'
                              ? 'ADDED TO STOCK'
                              : name?.isNotEmpty == true
                                  ? 'AUTO NAME • REVIEW LATER'
                                  : 'NEEDS REVIEW',
                        ),
                        trailing: Text(
                          '×${data['quantity'] ?? 0}',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
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

  Widget _cameraCard() {
    final camera = _camera;
    if (_cameraLoading) {
      return const SizedBox(
        height: 300,
        child: Card(child: Center(child: CircularProgressIndicator())),
      );
    }
    if (camera == null || !camera.value.isInitialized) {
      return SizedBox(
        height: 220,
        child: Card(
          child: Center(
            child: FilledButton.icon(
              onPressed: _initCamera,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('RETRY CAMERA'),
            ),
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: camera.value.aspectRatio,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _focusCamera(
                    details.localPosition,
                    constraints.biggest,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(camera),
                      Center(
                        child: Container(
                          width: constraints.maxWidth * 0.76,
                          height: constraints.maxHeight * 0.58,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                      ),
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 12,
                        child: Text(
                          'Keep the main label inside the frame • tap label to focus',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            shadows: [
                              Shadow(blurRadius: 5, color: Colors.black),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _photoPath != null || _cameraBusy ? null : _capture,
                icon: const Icon(Icons.camera_alt_rounded),
                label: Text(
                  _cameraBusy ? 'CAPTURING…' : 'CAPTURE PRODUCT',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _capturedCard() {
    final detected = _detectedName?.trim().isNotEmpty == true;
    final matched = _catalogMatch != null && _catalogMatch!.confidence >= 0.82;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(_photoPath!),
                    width: 74,
                    height: 74,
                    fit: BoxFit.cover,
                    cacheWidth: 320,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _ocrReading
                            ? 'Reading main label…'
                            : detected
                                ? _detectedName!
                                : 'Name needs review',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: AppTheme.ink,
                        ),
                      ),
                      if (matched) ...[
                        const SizedBox(height: 3),
                        const Text(
                          'MATCHED TO REVIEWED PRODUCT',
                          style: TextStyle(
                            fontSize: 9,
                            color: AppTheme.success,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ] else if (_primaryText?.isNotEmpty == true) ...[
                        const SizedBox(height: 3),
                        Text(
                          'Main text: $_primaryText',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.mutedInk,
                          ),
                        ),
                      ],
                      if (_barcode?.isNotEmpty == true) ...[
                        const SizedBox(height: 3),
                        Text(
                          'Barcode: $_barcode',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.mutedInk,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _qty,
              focusNode: _qtyFocus,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Quantity',
                hintText: 'e.g. 12',
              ),
              onSubmitted: (_) => _saveAndNext(),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _saving ? null : _saveAndNext,
              child: Text(_saving ? 'SAVING…' : 'SAVE & NEXT'),
            ),
            const SizedBox(height: 6),
            TextButton(onPressed: _retake, child: const Text('Retake')),
          ],
        ),
      ),
    );
  }
}

class _CaptureAnalysis {
  const _CaptureAnalysis({
    required this.ocr,
    required this.barcode,
    required this.catalogMatch,
  });

  final OcrResult? ocr;
  final String? barcode;
  final ProductMatch? catalogMatch;
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 9,
              color: AppTheme.mutedInk,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 21,
              color: AppTheme.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
