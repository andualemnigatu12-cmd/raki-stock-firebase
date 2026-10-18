import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/data/product_catalog_repository.dart';
import '../../core/data/registration_repository.dart';
import '../../core/theme/app_theme.dart';

/// V2 owner-only approval. This page intentionally has no Approve All:
/// every new variant needs a confirmed name, size and selling price.
class RegistrationReviewPage extends StatelessWidget {
  const RegistrationReviewPage({
    super.key,
    required this.branchId,
  });

  final String branchId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Text('Review registrations · V2'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: RegistrationRepository().watchEntries(branchId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Review could not load: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final pending = snapshot.data!.docs.where(
            (doc) => doc.data()['status'] == 'pending',
          ).toList()
            ..sort((a, b) {
              final left = a.data()['createdAt'] as Timestamp?;
              final right = b.data()['createdAt'] as Timestamp?;
              return (left?.millisecondsSinceEpoch ?? 0).compareTo(
                right?.millisecondsSinceEpoch ?? 0,
              );
            });
          if (pending.isEmpty) {
            return const Center(
              child: Text('No pending registrations.'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(14),
            itemCount: pending.length,
            itemBuilder: (context, index) {
              final doc = pending[index];
              final data = doc.data();
              final name = (data['nameCandidate'] as String?)?.trim() ?? '';
              final qty = (data['quantity'] as num?)?.toInt() ?? 0;
              final path = (data['localPhotoPath'] as String?)?.trim();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 62,
                        height: 68,
                        child: path != null && path.isNotEmpty
                            ? Image.file(
                                File(path),
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(
                                  Icons.image_not_supported_outlined,
                                ),
                              )
                            : const Icon(Icons.image_not_supported_outlined),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name.isEmpty ? 'NAME NEEDS REVIEW' : name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              'Qty $qty • ${data['section'] ?? 'No section'}',
                            ),
                            const Text(
                              'Pending price and owner approval',
                              style: TextStyle(
                                color: AppTheme.mutedInk,
                                fontSize: 12,
                              ),
                            ),
                            if (doc.metadata.hasPendingWrites)
                              const Text(
                                'Syncing...',
                                style: TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Review',
                        icon: const Icon(Icons.arrow_forward_ios),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => _ApproveEntryDialog(
                            branchId: branchId,
                            entryId: doc.id,
                            data: data,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ApproveEntryDialog extends StatefulWidget {
  const _ApproveEntryDialog({
    required this.branchId,
    required this.entryId,
    required this.data,
  });

  final String branchId;
  final String entryId;
  final Map<String, dynamic> data;

  @override
  State<_ApproveEntryDialog> createState() => _ApproveEntryDialogState();
}

class _ApproveEntryDialogState extends State<_ApproveEntryDialog> {
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _price;
  String? _existingProductId;
  bool _saving = false;
  bool _loadingMatches = true;
  List<ProductRecord> _matches = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: (widget.data['nameCandidate'] as String?)?.trim() ?? '',
    );
    _barcode = TextEditingController(
      text: (widget.data['barcodeCandidate'] as String?)?.trim() ?? '',
    );
    _price = TextEditingController();
    _name.addListener(_filterMatches);
    _barcode.addListener(_filterMatches);
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    try {
      final products = await FirebaseFirestore.instance
          .collection('products')
          .where('branchId', isEqualTo: widget.branchId)
          .limit(2000)
          .get();
      if (!mounted) return;
      setState(() {
        _matches = products.docs
            .map(ProductRecord.fromDoc)
            .where((p) => p.active)
            .toList();
        _loadingMatches = false;
      });
      _filterMatches();
    } catch (_) {
      if (mounted) setState(() => _loadingMatches = false);
    }
  }

  void _filterMatches() {
    if (!mounted) return;
    // Clearing a manual link when the fields change prevents accidental merges
    // if the owner edits the name/size or barcode afterwards.
    if (_existingProductId != null) {
      setState(() => _existingProductId = null);
    }
    setState(() {});
  }

  List<ProductRecord> get _suggestions {
    final code = ProductCatalogRepository.normalizeBarcode(_barcode.text);
    final name = ProductCatalogRepository.normalizeName(_name.text);
    final found = _matches.where((p) {
      final otherCode = ProductCatalogRepository.normalizeBarcode(
        p.barcode ?? '',
      );
      final otherName = ProductCatalogRepository.normalizeName(p.name);
      if (code.isNotEmpty && otherCode == code) return true;
      return name.isNotEmpty && otherName == name;
    }).take(5).toList();
    return found;
  }

  @override
  void dispose() {
    _name.removeListener(_filterMatches);
    _barcode.removeListener(_filterMatches);
    _name.dispose();
    _barcode.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    if (_saving) return;
    final price = double.tryParse(_price.text.trim().replaceAll(',', '.'));
    if (price == null || price <= 0) {
      setState(() => _error = 'Confirm a price greater than zero.');
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _error = 'Sign in again.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await RegistrationRepository().approveEntry(
        branchId: widget.branchId,
        entryId: widget.entryId,
        ownerId: user.uid,
        officialName: _name.text,
        barcode: _barcode.text,
        sellingPrice: price,
        existingProductId: _existingProductId,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions;
    return AlertDialog(
      title: const Text('Owner approval'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Counted: ${widget.data['quantity']} units'),
              const SizedBox(height: 6),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Official product name + size',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _barcode,
                decoration: const InputDecoration(
                  labelText: 'Barcode (if present)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _price,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Selling price (ETB) *',
                ),
              ),
              const SizedBox(height: 8),
              if (_loadingMatches)
                const LinearProgressIndicator()
              else if (suggestions.isNotEmpty) ...[
                const Text(
                  'Existing product detected: select it to ADD quantity.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                for (final product in suggestions)
                  RadioListTile<String>(
                    title: Text(product.name),
                    subtitle: Text(
                      'Stock ${product.stockQty}, '
                      'price ${product.sellingPrice} ETB',
                    ),
                    value: product.id,
                    groupValue: _existingProductId,
                    onChanged: (value) => setState(() {
                      _existingProductId = value;
                      if (_price.text.trim().isEmpty) {
                        _price.text = product.sellingPrice.toStringAsFixed(2);
                      }
                    }),
                  ),
              ],
              const Text(
                'Always verify variant and size before merging quantities. '
                'Photo is only visible on the capture phone.',
                style: TextStyle(fontSize: 12),
              ),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _loadingMatches ? null : _approve,
          child: Text(_saving ? 'Approving...' : 'APPROVE + ADD STOCK'),
        ),
      ],
    );
  }
}
