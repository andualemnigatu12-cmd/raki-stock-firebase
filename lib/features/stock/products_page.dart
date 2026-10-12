import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/data/product_catalog_repository.dart';
import '../../core/theme/app_theme.dart';
import 'product_scan_page.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({
    super.key,
    required this.branchId,
    this.isOwner = false,
    this.userId,
  });

  final String branchId;
  final bool isOwner;
  final String? userId;

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  final _catalog = ProductCatalogRepository();
  final _search = TextEditingController();
  StreamSubscription<List<ProductRecord>>? _subscription;
  Timer? _searchDebounce;

  List<ProductRecord> _products = const [];
  List<ProductRecord> _visible = const [];
  bool _loading = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _search.addListener(_queueSearch);
    unawaited(_load());
  }

  Future<void> _load() async {
    final cached = await _catalog.loadCached(widget.branchId);
    if (mounted) {
      setState(() {
        _products = cached;
        _visible = _catalog.searchProducts(cached, _search.text, limit: 120);
        _loading = false;
      });
    }

    _subscription = _catalog.watchProducts(widget.branchId).listen(
      (products) {
        if (!mounted) return;
        setState(() {
          _products = products;
          _visible = _catalog.searchProducts(
            products,
            _search.text,
            limit: 120,
          );
          _loading = false;
          _message = null;
        });
      },
      onError: (_) {
        if (mounted && _products.isEmpty) {
          setState(() {
            _loading = false;
            _message = 'Products could not sync. Check the connection and try again.';
          });
        }
      },
    );
  }

  void _queueSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 90), _applySearch);
  }

  void _applySearch() {
    if (!mounted) return;
    setState(() {
      _visible = _catalog.searchProducts(
        _products,
        _search.text,
        limit: 120,
      );
    });
  }

  Future<void> _editProduct(ProductRecord product) async {
    if (!widget.isOwner || widget.userId == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _EditProductDialog(
        branchId: widget.branchId,
        userId: widget.userId!,
        product: product,
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.removeListener(_queueSearch);
    _search.dispose();
    unawaited(_subscription?.cancel());
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
              'Products',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: AppTheme.ink,
              ),
            ),
            Text(
              'Registered stock catalog',
              style: TextStyle(fontSize: 11, color: AppTheme.mutedInk),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Scan product',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ProductScanPage(branchId: widget.branchId),
              ),
            ),
            icon: const Icon(Icons.qr_code_scanner_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Column(
                children: [
                  TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search product name or barcode',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: _search.clear,
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _search.text.trim().isEmpty
                              ? '${_products.length} registered products'
                              : '${_visible.length} matching products',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.mutedInk,
                          ),
                        ),
                      ),
                      if (widget.isOwner)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Text(
                            'Tap a product to edit',
                            style: TextStyle(fontSize: 10, color: AppTheme.mutedInk),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ProductScanPage(branchId: widget.branchId),
                          ),
                        ),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('SCAN'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && _products.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_message != null && _products.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _message!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.mutedInk),
          ),
        ),
      );
    }

    if (_products.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No registered products yet.\nFinish a stock count, review the products, then approve them.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.mutedInk),
          ),
        ),
      );
    }

    if (_visible.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No product matches this search.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.mutedInk),
          ),
        ),
      );
    }

    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
      itemCount: _visible.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final product = _visible[index];
        return _ProductCard(
          product: product,
          onTap: widget.isOwner ? () => _editProduct(product) : null,
        );
      },
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, this.onTap});

  final ProductRecord product;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProductPhoto(path: product.localPhotoPath),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            product.name.isEmpty ? 'Unnamed product' : product.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.ink,
                            ),
                          ),
                        ),
                        if (onTap != null)
                          const Icon(
                            Icons.edit_outlined,
                            size: 18,
                            color: AppTheme.mutedInk,
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    if (product.barcode?.isNotEmpty == true)
                      Text(
                        'Barcode ${product.barcode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.mutedInk,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _MiniValue(
                            label: 'PRICE',
                            value: product.sellingPrice <= 0
                                ? 'Not set'
                                : '${product.sellingPrice.toStringAsFixed(2)} ETB',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _MiniValue(
                            label: 'STOCK',
                            value: '${product.stockQty}',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditProductDialog extends StatefulWidget {
  const _EditProductDialog({
    required this.branchId,
    required this.userId,
    required this.product,
  });

  final String branchId;
  final String userId;
  final ProductRecord product;

  @override
  State<_EditProductDialog> createState() => _EditProductDialogState();
}

class _EditProductDialogState extends State<_EditProductDialog> {
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _price;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.product.name);
    _barcode = TextEditingController(text: widget.product.barcode ?? '');
    _price = TextEditingController(
      text: widget.product.sellingPrice <= 0
          ? ''
          : widget.product.sellingPrice.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    final normalizedName = ProductCatalogRepository.normalizeName(name);
    final barcode = ProductCatalogRepository.normalizeBarcode(_barcode.text);
    final price = double.tryParse(_price.text.trim().replaceAll(',', '.')) ?? 0;

    if (name.isEmpty || normalizedName.isEmpty) {
      setState(() => _error = 'Product name is required.');
      return;
    }
    if (price < 0) {
      setState(() => _error = 'Selling price cannot be negative.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      if (barcode.isNotEmpty) {
        final matches = await FirebaseFirestore.instance
            .collection('products')
            .where('branchId', isEqualTo: widget.branchId)
            .where('barcode', isEqualTo: barcode)
            .limit(2)
            .get()
            .timeout(const Duration(seconds: 3));
        final duplicate = matches.docs.any((doc) => doc.id != widget.product.id);
        if (duplicate) {
          if (mounted) {
            setState(() {
              _saving = false;
              _error = 'That barcode already belongs to another product.';
            });
          }
          return;
        }
      }

      await FirebaseFirestore.instance
          .collection('products')
          .doc(widget.product.id)
          .set({
        'branchId': widget.branchId,
        'name': name,
        'normalizedName': normalizedName,
        'barcode': barcode.isEmpty ? null : barcode,
        'catalogKey': barcode.isNotEmpty
            ? 'barcode:$barcode'
            : 'name:$normalizedName',
        'sellingPrice': price,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': widget.userId,
      }, SetOptions(merge: true));

      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not update this product. Check the connection and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit product'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Product name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _barcode,
              decoration: const InputDecoration(labelText: 'Barcode'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Selling price'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Stock quantity is changed through stock count/review so quantity history stays controlled.',
              style: TextStyle(fontSize: 11, color: AppTheme.mutedInk),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'SAVING…' : 'SAVE'),
        ),
      ],
    );
  }
}

class _ProductPhoto extends StatelessWidget {
  const _ProductPhoto({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final value = path?.trim();

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 82,
        height: 82,
        child: value?.isNotEmpty == true
            ? Image.file(
                File(value!),
                fit: BoxFit.cover,
                cacheWidth: 240,
                errorBuilder: (_, _, _) => _placeholder(),
              )
            : _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: AppTheme.primarySoft,
      alignment: Alignment.center,
      child: const Icon(
        Icons.inventory_2_outlined,
        color: AppTheme.primary,
        size: 30,
      ),
    );
  }
}

class _MiniValue extends StatelessWidget {
  const _MiniValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.w800,
              color: AppTheme.mutedInk,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: AppTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}
