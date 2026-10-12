import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/data/product_catalog_repository.dart';
import '../../core/theme/app_theme.dart';

class QuickAddProductPage extends StatefulWidget {
  const QuickAddProductPage({
    super.key,
    required this.branchId,
    required this.userId,
  });

  final String branchId;
  final String userId;

  @override
  State<QuickAddProductPage> createState() => _QuickAddProductPageState();
}

class _QuickAddProductPageState extends State<QuickAddProductPage> {
  final _name = TextEditingController();
  final _barcode = TextEditingController();
  final _quantity = TextEditingController();
  final _price = TextEditingController();
  final _nameFocus = FocusNode();
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _nameFocus.requestFocus());
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _quantity.dispose();
    _price.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<DocumentReference<Map<String, dynamic>>?> _findExisting({
    required String barcode,
    required String normalizedName,
  }) async {
    final products = FirebaseFirestore.instance.collection('products');

    Future<DocumentReference<Map<String, dynamic>>?> find(
      Query<Map<String, dynamic>> query,
    ) async {
      try {
        final cached = await query.get(const GetOptions(source: Source.cache));
        if (cached.docs.isNotEmpty) return cached.docs.first.reference;
      } catch (_) {}
      try {
        final fresh = await query.get().timeout(const Duration(milliseconds: 900));
        if (fresh.docs.isNotEmpty) return fresh.docs.first.reference;
      } catch (_) {}
      return null;
    }

    if (barcode.isNotEmpty) {
      final byBarcode = await find(
        products
            .where('branchId', isEqualTo: widget.branchId)
            .where('barcode', isEqualTo: barcode)
            .limit(1),
      );
      if (byBarcode != null) return byBarcode;
    }

    return find(
      products
          .where('branchId', isEqualTo: widget.branchId)
          .where('normalizedName', isEqualTo: normalizedName)
          .limit(1),
    );
  }

  Future<void> _save({bool addAnother = false}) async {
    if (_saving) return;

    final name = _name.text.trim();
    final quantity = int.tryParse(_quantity.text.trim());
    final rawPrice = _price.text.trim().replaceAll(',', '.');
    final price = rawPrice.isEmpty ? 0.0 : double.tryParse(rawPrice);
    final barcode = ProductCatalogRepository.normalizeBarcode(_barcode.text);
    final normalizedName = ProductCatalogRepository.normalizeName(name);

    if (name.isEmpty || normalizedName.isEmpty) {
      setState(() => _message = 'Enter the product name.');
      _nameFocus.requestFocus();
      return;
    }
    if (quantity == null || quantity < 0) {
      setState(() => _message = 'Enter a valid quantity.');
      return;
    }
    if (price == null || price < 0) {
      setState(() => _message = 'Enter a valid selling price.');
      return;
    }

    setState(() {
      _saving = true;
      _message = null;
    });

    try {
      final products = FirebaseFirestore.instance.collection('products');
      final existing = await _findExisting(
        barcode: barcode,
        normalizedName: normalizedName,
      );
      final ref = existing ??
          products.doc(
            _fallbackProductId(
              normalizedName: normalizedName,
              normalizedBarcode: barcode,
            ),
          );
      final isNew = existing == null;
      final now = FieldValue.serverTimestamp();

      final write = ref.set({
        'branchId': widget.branchId,
        'name': name,
        'normalizedName': normalizedName,
        'barcode': barcode.isEmpty ? null : barcode,
        'catalogKey': barcode.isNotEmpty
            ? 'barcode:$barcode'
            : 'name:$normalizedName',
        'sellingPrice': price,
        'stockQty': quantity,
        'active': true,
        'updatedAt': now,
        'updatedBy': widget.userId,
        'registrationSource': 'quick_add',
        if (isNew) 'createdAt': now,
        if (isNew) 'createdBy': widget.userId,
      }, SetOptions(merge: true));

      // Firestore applies the write to local persistence immediately. Do not
      // make a shop employee stare at a spinner while the network confirms it.
      unawaited(
        write.catchError((_) {
          if (mounted) {
            setState(() {
              _message = 'This product could not sync. Check the connection and try again.';
            });
          }
        }),
      );

      if (!mounted) return;
      if (addAnother) {
        _name.clear();
        _barcode.clear();
        _quantity.clear();
        _price.clear();
        setState(() {
          _message = isNew
              ? 'Saved locally. Ready for the next product.'
              : 'Existing product updated locally. Ready for the next one.';
        });
        _nameFocus.requestFocus();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not prepare this product. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fallbackProductId({
    required String normalizedName,
    required String normalizedBarcode,
  }) {
    final branch = widget.branchId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (normalizedBarcode.isNotEmpty) {
      return '$branch-b-$normalizedBarcode';
    }

    var hash = 0x811c9dc5;
    for (final codeUnit in normalizedName.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '$branch-n-${hash.toRadixString(16).padLeft(8, '0')}';
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
              'Quick Add Product',
              style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.ink),
            ),
            Text(
              'Fast manual registration • no camera wait',
              style: TextStyle(fontSize: 11, color: AppTheme.mutedInk),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.primarySoft,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text(
                'Use this when the product name is easy to type or OCR is unnecessary. Barcode and selling price are optional.',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.ink),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              focusNode: _nameFocus,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Product name',
                hintText: 'e.g. Coca Cola 500ml',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _barcode,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Barcode (optional)',
                hintText: 'Type the barcode if available',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quantity,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Quantity',
                      hintText: '0',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Selling price',
                      hintText: 'Optional',
                    ),
                    onSubmitted: (_) => _save(addAnother: true),
                  ),
                ),
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.mutedInk),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _saving ? null : () => _save(addAnother: true),
                icon: const Icon(Icons.add_rounded),
                label: Text(_saving ? 'PREPARING…' : 'SAVE & ADD NEXT'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _saving ? null : () => _save(addAnother: false),
              child: const Text('SAVE & DONE'),
            ),
          ],
        ),
      ),
    );
  }
}
