import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class StockReviewPage extends StatelessWidget {
  const StockReviewPage({super.key, required this.branchId});

  final String branchId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Text('Stock Review', style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.ink)),
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
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
            itemCount: sessions.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final session = sessions[index];
              final data = session.data();
              final status = data['status'] as String? ?? 'draft';
              return Card(
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                  title: Text(data['code'] as String? ?? 'Stock count', style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.ink)),
                  subtitle: Text(status == 'finalized' ? 'Finished count' : 'Draft count'),
                  trailing: _StatusPill(status: status),
                  children: [
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: session.reference.collection('items').orderBy('localCreatedAt', descending: true).snapshots(),
                      builder: (context, itemSnapshot) {
                        final items = itemSnapshot.data?.docs ?? const [];
                        if (items.isEmpty) return const Padding(padding: EdgeInsets.all(12), child: Text('No products in this count.'));
                        return Column(
                          children: items.map((doc) {
                            final item = doc.data();
                            final name = (item['suggestedName'] as String?)?.trim();
                            final title = name?.isNotEmpty == true ? name! : (item['tempCode'] as String? ?? 'Unnamed product');
                            final photoUrl = item['photoUrl'] as String?;
                            return Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(11),
                                    child: SizedBox(
                                      width: 56,
                                      height: 56,
                                      child: photoUrl == null
                                          ? Container(color: AppTheme.primarySoft, child: const Icon(Icons.image_outlined, color: AppTheme.primary))
                                          : Image.network(photoUrl, fit: BoxFit.cover),
                                    ),
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.ink)),
                                        const SizedBox(height: 4),
                                        Text(name?.isNotEmpty == true ? 'AUTO NAME' : 'NEEDS REVIEW', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: name?.isNotEmpty == true ? AppTheme.success : AppTheme.warning)),
                                      ],
                                    ),
                                  ),
                                  Text('×${item['quantity'] ?? 0}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppTheme.ink)),
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
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
      child: Text(finished ? 'DONE' : 'DRAFT', style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900)),
    );
  }
}
