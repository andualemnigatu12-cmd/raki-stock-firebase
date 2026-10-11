import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart'
    as ml_barcode;

import '../../core/data/product_catalog_repository.dart';
import '../../core/ocr/ocr_service.dart';
import '../../core/theme/app_theme.dart';

class ProductScanPage extends StatefulWidget {
  const ProductScanPage({super.key, required this.branchId});

  final String branchId;

  @override
  State<ProductScanPage> createState() => _ProductScanPageState();
}

class _ProductScanPageState extends State<ProductScanPage>
    with WidgetsBindingObserver {
  final _catalog = ProductCatalogRepository();
  final _ocr = OcrService();
  final _barcodeScanner = ml_barcode.BarcodeScanner();

  CameraController? _camera;
  StreamSubscription<List<ProductRecord>>? _catalogSub;
  List<ProductRecord> _products = const [];
  ProductMatch? _match;
  bool _cameraLoading = true;
  bool _scanning = false;
  String? _barcode;
  String? _detectedName;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadCatalog());
    unawaited(_initCamera());
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

  Future<void> _loadCatalog() async {
    final cached = await _catalog.loadCached(widget.branchId);
    if (mounted && cached.isNotEmpty) setState(() => _products = cached);
    _catalogSub = _catalog.watchProducts(widget.branchId).listen(
      (products) {
        if (mounted) setState(() => _products = products);
      },
      onError: (_) {
        if (mounted && _products.isEmpty) {
          setState(() {
            _message =
                'Product list could not sync yet. Connect once and try again.';
          });
        }
      },
    );
  }

  Future<void> _initCamera() async {
    if (mounted) setState(() => _cameraLoading = true);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera.');
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
      } catch (_) {}
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
      if (mounted) setState(() => _message = 'Camera could not start.');
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
    } catch (_) {}
  }

  Future<void> _scan() async {
    final camera = _camera;
    if (camera == null ||
        !camera.value.isInitialized ||
        camera.value.isTakingPicture ||
        _scanning) {
      return;
    }

    setState(() {
      _scanning = true;
      _match = null;
      _barcode = null;
      _detectedName = null;
      _message = null;
    });

    try {
      final image = await camera.takePicture();
      String? barcode;
      try {
        final codes = await _barcodeScanner.processImage(
          ml_barcode.InputImage.fromFilePath(image.path),
        );
        for (final code in codes) {
          final value = code.rawValue?.trim();
          if (value != null && value.isNotEmpty) {
            barcode = value;
            break;
          }
        }
      } catch (_) {}

      ProductMatch? match = _catalog.findBestMatch(
        _products,
        barcode: barcode,
      );

      String? detectedName;
      if (match == null) {
        try {
          final ocr = await _ocr.readProduct(image.path);
          detectedName = ocr.suggestedName;
          match = _catalog.findBestMatch(
            _products,
            barcode: barcode,
            ocrName: detectedName,
          );
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _barcode = barcode;
        _detectedName = detectedName;
        _match = match;
        if (_products.isEmpty) {
          _message =
              'No reviewed products are available yet. Review products in Stock Review first.';
        } else if (match == null) {
          _message = detectedName?.isNotEmpty == true
              ? 'Label detected, but no safe catalog match. Ask the owner to review this product.'
              : 'No confident match. Ask the owner to review/register this product.';
        } else {
          _message = null;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not scan. Try again.');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_catalogSub?.cancel());
    final camera = _camera;
    if (camera != null) unawaited(camera.dispose());
    unawaited(_ocr.dispose());
    unawaited(_barcodeScanner.close());
    super.dispose();
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
              'Scan Product',
              style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.ink),
            ),
            Text(
              'Barcode first • reviewed name if matched',
              style: TextStyle(fontSize: 11, color: AppTheme.mutedInk),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.primarySoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              '${_products.length} reviewed products available for instant matching',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.ink,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _cameraCard(),
          const SizedBox(height: 12),
          if (_match != null) _matchCard(_match!),
          if (_message != null)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7E8),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                _message!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          if (_barcode?.isNotEmpty == true || _detectedName?.isNotEmpty == true) ...[
            const SizedBox(height: 10),
            Text(
              [
                if (_barcode?.isNotEmpty == true) 'Barcode: $_barcode',
                if (_detectedName?.isNotEmpty == true) 'OCR: $_detectedName',
              ].join(' • '),
              style: const TextStyle(fontSize: 11, color: AppTheme.mutedInk),
              textAlign: TextAlign.center,
            ),
          ],
        ],
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
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  onTapDown: (details) =>
                      _focusCamera(details.localPosition, size),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(camera),
                      Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: constraints.maxWidth * 0.78,
                          height: constraints.maxHeight * 0.42,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.92),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 14,
                        child: Text(
                          'Keep the main label inside the box • tap label to focus',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            shadows: [
                              Shadow(
                                blurRadius: 8,
                                color: Colors.black.withValues(alpha: 0.75),
                              ),
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
                onPressed: _scanning ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: Text(_scanning ? 'MATCHING…' : 'SCAN PRODUCT'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _matchCard(ProductMatch match) {
    final product = match.product;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF8F0),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: AppTheme.success,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'MATCH FOUND',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.success,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        product.name,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _ValueBox(
                    label: 'SELLING PRICE',
                    value: '${product.sellingPrice.toStringAsFixed(2)} ETB',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ValueBox(
                    label: 'STOCK',
                    value: '${product.stockQty}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              match.source == 'barcode'
                  ? 'Matched instantly by barcode. Official reviewed spelling used.'
                  : 'Matched to the reviewed product name (${(match.confidence * 100).round()}% confidence).',
              style: const TextStyle(fontSize: 11, color: AppTheme.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueBox extends StatelessWidget {
  const _ValueBox({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(14),
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
              fontWeight: FontWeight.w900,
              color: AppTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}
