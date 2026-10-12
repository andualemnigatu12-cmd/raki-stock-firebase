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
            .limit(50)
            .snapshots(),
        builder: (context, sessionSnapshot) {
          if (sessionSnapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Could not load stock counts. Check the connection and try again.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (sessionSnapshot.connectionState == ConnectionState.waiting &&
              !sessionSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final sessions = [...?sessionSnapshot.data?.docs];
          sessions.sort((a, b) {
            final aTime = a.data()['localCreatedAt'] as Timestamp?;
            final bTime = b.data()['localCreatedAt'] as Timestamp?;
            return (bTime?.millisecondsSinceEpoch ?? 0)
                .compareTo(aTime?.millisecondsSinceEpoch ?? 0);
          });

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
              final isLatest = index == 0;

              return Card(
                child: ExpansionTile(
                  initiallyExpanded: isLatest,
                  tilePadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                  title: Text(
                    isLatest
                        ? '${data['code'] as String? ?? 'Stock count'} • LATEST'
                        : data['code'] as String? ?? 'Stock count',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.ink,
                    ),
                  ),
                  subtitle: Text(
                    status == 'finalized'
                        ? 'Finished count • owner can approve, edit or delete'
                        : 'Draft count • owner can approve, edit or delete',
                  ),
                  trailing: _StatusPill(status: status),
                  children: [
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: session.reference
                          .collection('items')
                          .orderBy('localCreatedAt', descending: true)
                          .snapshots(),
                      builder: (context, itemSnapshot) {
                        if (itemSnapshot.hasError) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'Could not load the products in this count.',
                              textAlign: TextAlign.center,
                            ),
                          );
                        }

                        if (itemSnapshot.connectionState ==
                                ConnectionState.waiting &&
                            !itemSnapshot.hasData) {
                          return const Padding(
                            padding: EdgeInsets.all(18),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }

                        final items = itemSnapshot.data?.docs ?? const [];
                        if (items.isEmpty) {
                          return Column(
                            children: [
                              const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text('No products in this count yet.'),
                              ),
                              _DeleteCountButton(sessionId: session.id),
                            ],
                          );
                        }

                        final totalUnits = items.fold<int>(
                          0,
                          (sum, doc) =>
                              sum +
                              ((doc.data()['quantity'] as num?)?.toInt() ?? 0),
                        );
                        final pendingCount = items
                            .where((doc) => doc.data()['reviewState'] != 'added')
                            .length;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 6, bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.primarySoft,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '${items.length} products • $totalUnits units • $pendingCount waiting for approval',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: AppTheme.ink,
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: pendingCount == 0
                                        ? null
                                        : () => _approveAll(
                                              context,
                                              branchId: branchId,
                                              sessionId: session.id,
                                            ),
                                    icon: const Icon(Icons.done_all_rounded),
                                    label: const Text('APPROVE ALL'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => _deleteCount(
                                      context,
                                      sessionId: session.id,
                                    ),
                                    icon: const Icon(Icons.delete_outline_rounded),
                                    label: const Text('DELETE COUNT'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ...items.map((doc) {
                              final item = doc.data();
                              final name =
                                  (item['suggestedName'] as String?)?.trim();
                              final reviewedName =
                                  (item['reviewedName'] as String?)?.trim();
                              final displayName =
                                  reviewedName?.isNotEmpty == true
                                      ? reviewedName!
                                      : name?.isNotEmpty == true
                                          ? name!
                                          : (item['tempCode'] as String? ??
                                              'Unnamed product');
                              final localPath =
                                  (item['localPhotoPath'] as String?)?.trim();
                              final added = item['reviewState'] == 'added';
                              final quantity =
                                  (item['quantity'] as num?)?.toInt() ?? 0;
                              final reviewedPrice =
                                  (item['reviewedSellingPrice'] as num?)
                                      ?.toDouble();
                              final barcode = added
                                  ? (item['reviewedBarcode'] as String?) ??
                                      (item['barcodeCandidate'] as String?) ??
                                      ''
                                  : (item['barcodeCandidate'] as String?) ?? '';

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
                                                displayName,
                                                maxLines: 3,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  color: AppTheme.ink,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                added
                                                    ? 'APPROVED • ${_priceText(reviewedPrice)}'
                                                    : name?.isNotEmpty == true
                                                        ? 'AUTO NAME • REVIEW IF NEEDED'
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
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 7,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppTheme.background,
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            'QTY $quantity',
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w900,
                                              color: AppTheme.ink,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 9),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: added
                                              ? OutlinedButton.icon(
                                                  onPressed: () =>
                                                      _openReviewDialog(
                                                    context,
                                                    branchId: branchId,
                                                    sessionId: session.id,
                                                    itemId: doc.id,
                                                    quantity: quantity,
                                                    name: displayName,
                                                    barcode: barcode,
                                                    price: reviewedPrice,
                                                    localPhotoPath: localPath,
                                                    alreadyAdded: true,
                                                  ),
                                                  icon: const Icon(
                                                    Icons.edit_outlined,
                                                  ),
                                                  label: const Text(
                                                    'EDIT PRODUCT',
                                                  ),
                                                )
                                              : FilledButton.icon(
                                                  onPressed: () =>
                                                      _openReviewDialog(
                                                    context,
                                                    branchId: branchId,
                                                    sessionId: session.id,
                                                    itemId: doc.id,
                                                    quantity: quantity,
                                                    name: name ?? '',
                                                    barcode: barcode,
                                                    price: reviewedPrice,
                                                    localPhotoPath: localPath,
                                                    alreadyAdded: false,
                                                  ),
                                                  icon: const Icon(
                                                    Icons.fact_check_outlined,
                                                  ),
                                                  label: const Text(
                                                    'REVIEW & ADD',
                                                  ),
                                                ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton.filledTonal(
                                          tooltip: 'Delete product',
                                          onPressed: () => _deleteItem(
                                            context,
                                            sessionId: session.id,
                                            itemId: doc.id,
                                            name: displayName,
                                            alreadyAdded: added,
                                          ),
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
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

  static void _openReviewDialog(
    BuildContext context, {
    required String branchId,
    required String sessionId,
    required String itemId,
    required int quantity,
    required String name,
    required String barcode,
    required double? price,
    required String? localPhotoPath,
    required bool alreadyAdded,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => _ReviewProductDialog(
        branchId: branchId,
        sessionId: sessionId,
        itemId: itemId,
        initialQuantity: quantity,
        initialName: name,
        initialBarcode: barcode,
        initialPrice: price,
        localPhotoPath: localPhotoPath,
        alreadyAdded: alreadyAdded,
      ),
    );
  }

  static Future<void> _approveAll(
    BuildContext context, {
    required String branchId,
    required String sessionId,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approve all products?'),
        content: const Text(
          'This accepts every product that already has a detected name and quantity. '
          'Existing prices stay unchanged. New products without a price can be edited later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('APPROVE ALL'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final count = await InventoryRepository().approveAllPending(
        branchId: branchId,
        sessionId: sessionId,
        userId: user.uid,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count products approved.')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Approve all failed: ${_shortError(error)}')),
        );
      }
    }
  }

  static Future<void> _deleteItem(
    BuildContext context, {
    required String sessionId,
    required String itemId,
    required String name,
    required bool alreadyAdded,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete product?'),
        content: Text(
          alreadyAdded
              ? 'Delete "$name" from this stock count? The approved product will stay in Products.'
              : 'Delete "$name" from this stock count?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await InventoryRepository().deleteCountItem(
        sessionId: sessionId,
        itemId: itemId,
        deleteLinkedProduct: false,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: ${_shortError(error)}')),
        );
      }
    }
  }

  static Future<void> _deleteCount(
    BuildContext context, {
    required String sessionId,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this count?'),
        content: const Text(
          'This removes the count and its captured items. Products that were already approved stay in Products.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('DELETE COUNT'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await InventoryRepository().deleteSession(sessionId);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: ${_shortError(error)}')),
        );
      }
    }
  }

  static String _priceText(dynamic value) {
    final price = (value as num?)?.toDouble();
    if (price == null || price == 0) return 'PRICE NOT SET';
    return '${price.toStringAsFixed(2)} ETB';
  }

  static String _shortError(Object error) {
    if (error is FirebaseException) return error.code;
    final text = error.toString();
    return text.length > 90 ? '${text.substring(0, 90)}…' : text;
  }
}

class _ReviewProductDialog extends StatefulWidget {
  const _ReviewProductDialog({
    required this.branchId,
    required this.sessionId,
    required this.itemId,
    required this.initialQuantity,
    required this.initialName,
    required this.initialBarcode,
    required this.initialPrice,
    required this.localPhotoPath,
    required this.alreadyAdded,
  });

  final String branchId;
  final String sessionId;
  final String itemId;
  final int initialQuantity;
  final String initialName;
  final String initialBarcode;
  final double? initialPrice;
  final String? localPhotoPath;
  final bool alreadyAdded;

  @override
  State<_ReviewProductDialog> createState() => _ReviewProductDialogState();
}

class _ReviewProductDialogState extends State<_ReviewProductDialog> {
  final _repo = InventoryRepository();
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _quantity;
  late final TextEditingController _price;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _barcode = TextEditingController(text: widget.initialBarcode);
    _quantity = TextEditingController(text: '${widget.initialQuantity}');
    _price = TextEditingController(
      text: widget.initialPrice == null || widget.initialPrice == 0
          ? ''
          : widget.initialPrice!.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _quantity.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = _name.text.trim();
    final price = double.tryParse(_price.text.trim());
    final quantity = int.tryParse(_quantity.text.trim());
    if (name.isEmpty) {
      setState(() => _error = 'Confirm the product name.');
      return;
    }
    if (quantity == null || quantity <= 0) {
      setState(() => _error = 'Enter a valid quantity.');
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
        quantity: quantity,
        sellingPrice: price,
        barcode: _barcode.text.trim(),
        userId: user.uid,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        final detail = error is FirebaseException ? error.code : error.toString();
        setState(() => _error = 'Could not save product: $detail');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.alreadyAdded ? 'Edit product' : 'Review product'),
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
                  helperText: 'Owner can correct any missed word or letter.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _barcode,
                decoration: const InputDecoration(
                  labelText: 'Barcode (optional)',
                  helperText: 'Barcode gives the fastest future scan.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _quantity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Counted quantity'),
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
              if (_error != null) ...[
                const SizedBox(height: 10),
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
          child: Text(
            _saving
                ? 'SAVING…'
                : widget.alreadyAdded
                    ? 'SAVE CHANGES'
                    : 'ADD TO PRODUCTS',
          ),
        ),
      ],
    );
  }
}

class _DeleteCountButton extends StatelessWidget {
  const _DeleteCountButton({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: OutlinedButton.icon(
        onPressed: () => StockReviewPage._deleteCount(
          context,
          sessionId: sessionId,
        ),
        icon: const Icon(Icons.delete_outline_rounded),
        label: const Text('DELETE COUNT'),
      ),
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
