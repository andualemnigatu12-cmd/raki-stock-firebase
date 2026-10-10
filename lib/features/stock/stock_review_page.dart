import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/data/inventory_repository.dart';
import '../../core/theme/app_theme.dart';

class StockReviewPage extends StatelessWidget {
  const StockReviewPage({super.key, required this.branchId});

  final String branchId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Text(
          'Stock Review',
          style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.ink),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('stock_count_sessions')
            .where('branchId', isEqualTo: branchId)
            .orderBy('localCreatedAt', descending: true)
            .limit(30)
            .snapshots(),
        builder: (context, sessionSnapshot) {
          final sessions = sessionSnapshot.data?.docs ?? const [];
          if (sessions.isEmpty) {
            return const Center(child: Text('No stock counts yet.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
            itemCount: sessions.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final session = sessions[index];
              final data = session.data();
              final status = data['status'] as String? ?? 'draft';
              return Card(
                child: ExpansionTile(
                  tilePadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                  title: Text(
                    data['code'] as String? ?? 'Stock count',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.ink,
                    ),
                  ),
                  subtitle: Text(
                    status == 'finalized' ? 'Finished count' : 'Draft count',
                  ),
                  trailing: _StatusPill(status: status),
                  children: [
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: session.reference
                          .collection('items')
                          .orderBy('localCreatedAt', descending: true)
                          .snapshots(),
                      builder: (context, itemSnapshot) {
                        final items = itemSnapshot.data?.docs ?? const [];
                        if (items.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('No products in this count.'),
                          );
                        }
                        return Column(
                          children: items.map((doc) {
                            final item = doc.data();
                            final name =
                                (item['suggestedName'] as String?)?.trim();
                            final title = name?.isNotEmpty == true
                                ? name!
                                : (item['tempCode'] as String? ??
                                    'Unnamed product');
                            final localPath =
                                (item['localPhotoPath'] as String?)?.trim();
                            final added = item['reviewState'] == 'added';
                            final quantity =
                                (item['quantity'] as num?)?.toInt() ?? 0;
                            return Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      _LocalPhoto(path: localPath),
                                      const SizedBox(width: 11),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                color: AppTheme.ink,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              added
                                                  ? 'ADDED TO STOCK'
                                                  : name?.isNotEmpty == true
                                                      ? 'AUTO NAME • REVIEW IT'
                                                      : 'NEEDS REVIEW',
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w800,
                                                color: added
                                                    ? AppTheme.success
                                                    : AppTheme.warning,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Text(
                                        '×$quantity',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                          color: AppTheme.ink,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 9),
                                  SizedBox(
                                    width: double.infinity,
                                    child: added
                                        ? OutlinedButton.icon(
                                            onPressed: null,
                                            icon: const Icon(
                                              Icons.check_circle_rounded,
                                            ),
                                            label: Text(
                                              'IN STOCK • ${_priceText(item['reviewedSellingPrice'])}',
                                            ),
                                          )
                                        : FilledButton.icon(
                                            onPressed: () {
                                              showDialog<void>(
                                                context: context,
                                                builder: (_) =>
                                                    _ReviewProductDialog(
                                                  branchId: branchId,
                                                  sessionId: session.id,
                                                  itemId: doc.id,
                                                  quantity: quantity,
                                                  initialName: name ?? '',
                                                  initialBarcode: (item[
                                                              'barcodeCandidate']
                                                          as String?) ??
                                                      '',
                                                  localPhotoPath: localPath,
                                                ),
                                              );
                                            },
                                            icon: const Icon(
                                              Icons.fact_check_outlined,
                                            ),
                                            label: const Text(
                                              'REVIEW & ADD TO STOCK',
                                            ),
                                          ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _priceText(dynamic value) {
    final price = (value as num?)?.toDouble();
    if (price == null) return 'PRICE NOT SET';
    return '${price.toStringAsFixed(2)} ETB';
  }
}

class _ReviewProductDialog extends StatefulWidget {
  const _ReviewProductDialog({
    required this.branchId,
    required this.sessionId,
    required this.itemId,
    required this.quantity,
    required this.initialName,
    required this.initialBarcode,
    required this.localPhotoPath,
  });

  final String branchId;
  final String sessionId;
  final String itemId;
  final int quantity;
  final String initialName;
  final String initialBarcode;
  final String? localPhotoPath;

  @override
  State<_ReviewProductDialog> createState() => _ReviewProductDialogState();
}

class _ReviewProductDialogState extends State<_ReviewProductDialog> {
  final _repo = InventoryRepository();
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  final _price = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _barcode = TextEditingController(text: widget.initialBarcode);
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = _name.text.trim();
    final price = double.tryParse(_price.text.trim());
    if (name.isEmpty) {
      setState(() => _error = 'Confirm the product name.');
      return;
    }
    if (price == null || price < 0) {
      setState(() => _error = 'Enter the selling price.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('Not signed in.');
      await _repo.reviewItemIntoStock(
        branchId: widget.branchId,
        sessionId: widget.sessionId,
        itemId: widget.itemId,
        name: name,
        quantity: widget.quantity,
        sellingPrice: price,
        barcode: _barcode.text.trim(),
        userId: user.uid,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not add this product. Check connection and Firestore rules.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Review product'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _LocalPhoto(path: widget.localPhotoPath, large: true),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Product name',
                  helperText: 'Fix the automatic name if needed.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _barcode,
                decoration: const InputDecoration(
                  labelText: 'Barcode (optional)',
                  helperText: 'Barcode gives the fastest future match.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _price,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Selling price (ETB)',
                ),
              ),
              const SizedBox(height: 8),
              Text('Opening quantity: ${widget.quantity}'),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'ADDING…' : 'ADD TO STOCK'),
        ),
      ],
    );
  }
}

class _LocalPhoto extends StatelessWidget {
  const _LocalPhoto({required this.path, this.large = false});

  final String? path;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final valid = path?.isNotEmpty == true && File(path!).existsSync();
    final size = large ? 150.0 : 56.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: SizedBox(
        width: large ? double.infinity : size,
        height: size,
        child: valid
            ? Image.file(File(path!), fit: BoxFit.cover, cacheWidth: 700)
            : Container(
                color: AppTheme.primarySoft,
                child: const Icon(Icons.image_outlined, color: AppTheme.primary),
              ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final finished = status == 'finalized';
    final color = finished ? AppTheme.success : AppTheme.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        finished ? 'DONE' : 'DRAFT',
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
