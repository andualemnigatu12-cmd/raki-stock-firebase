import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/data/product_catalog_repository.dart';
import '../../core/theme/app_theme.dart';
import 'product_scan_page.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key, required this.branchId});

  final String branchId;

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  final _catalog = ProductCatalogRepository();
  final _search = TextEditingController();
  StreamSubscription<List<ProductRecord>>? _subscription;

  List<ProductRecord> _products = const [];
  List<ProductRecord> _visible = const [];
  bool _loading = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _search.addListener(_applySearch);
    unawaited(_load());
  }

  Future<void> _load() async {
    final cached = await _catalog.loadCached(widget.branchId);
    if (mounted) {
      setState(() {
        _products = cached;
        _visible = _catalog.searchProducts(cached, _search.text, limit: 200);
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
            limit: 200,
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

  void _applySearch() {
    if (!mounted) return;
    setState(() {
      _visible = _catalog.searchProducts(
        _products,
        _search.text,
        limit: 200,
      );
    });
  }

  @override
  void dispose() {
    _search.removeListener(_applySearch);
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
      itemBuilder: (context, index) => _ProductCard(product: _visible[index]),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product});

  final ProductRecord product;

  @override
  Widget build(BuildContext context) {
    return Card(
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
                  Text(
                    product.name.isEmpty ? 'Unnamed product' : product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.ink,
                    ),
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
    );
  }
}

class _ProductPhoto extends StatelessWidget {
  const _ProductPhoto({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final value = path?.trim();
    final exists = value?.isNotEmpty == true && File(value!).existsSync();

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 82,
        height: 82,
        child: exists
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
