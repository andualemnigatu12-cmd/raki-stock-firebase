import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/data/inventory_repository.dart';
import '../../core/theme/app_theme.dart';
import '../count/fast_count_page.dart';
import '../stock/stock_review_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _repo = InventoryRepository();
  bool _starting = false;

  Future<void> _startCount(String branchId, String userId) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final session = await _repo.startOrContinueCount(
        branchId: branchId,
        userId: userId,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FastCountPage(
            sessionId: session.id,
            branchId: branchId,
            userId: userId,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
      builder: (context, profileSnapshot) {
        final profile = profileSnapshot.data?.data();
        final branchId = profile?['branchId'] as String? ?? 'raki-bale-robe';
        final displayName = profile?['displayName'] as String? ?? 'Owner';
        final role = profile?['role'] as String? ?? 'owner';

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppTheme.background,
            elevation: 0,
            titleSpacing: 20,
            title: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  alignment: Alignment.center,
                  child: const Text('R', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                ),
                const SizedBox(width: 10),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Raki Stock', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.ink)),
                    Text('Bale Robe', style: TextStyle(fontSize: 11, color: AppTheme.mutedInk)),
                  ],
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Sign out',
                onPressed: () => FirebaseAuth.instance.signOut(),
                icon: const Icon(Icons.logout_rounded),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text('Good day, $displayName', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 5),
                Text('Inventory at a glance • ${role.toUpperCase()}'),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('FAST COUNT MODE', style: TextStyle(color: Color(0xFFDDE2FF), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
                      const SizedBox(height: 8),
                      const Text('Count stock without slowing down.', style: TextStyle(color: Colors.white, fontSize: 24, height: 1.1, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      const Text('Photo → automatic name → quantity → next product.', style: TextStyle(color: Color(0xFFDDE2FF), height: 1.4)),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppTheme.primary),
                        onPressed: _starting ? null : () => _startCount(branchId, user.uid),
                        icon: const Icon(Icons.camera_alt_rounded),
                        label: Text(_starting ? 'OPENING…' : 'START / CONTINUE COUNT'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _repo.watchRecentSessions(branchId),
                  builder: (context, snapshot) {
                    final docs = snapshot.data?.docs ?? const [];
                    final drafts = docs.where((d) => d.data()['status'] == 'draft').length;
                    final completed = docs.where((d) => d.data()['status'] == 'finalized').length;
                    return Row(
                      children: [
                        Expanded(child: _MetricCard(label: 'Recent counts', value: '${docs.length}', icon: Icons.inventory_2_outlined)),
                        const SizedBox(width: 10),
                        Expanded(child: _MetricCard(label: 'Draft', value: '$drafts', icon: Icons.edit_note_rounded)),
                        const SizedBox(width: 10),
                        Expanded(child: _MetricCard(label: 'Finished', value: '$completed', icon: Icons.check_circle_outline_rounded)),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 22),
                Text('Quick actions', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _ActionCard(
                        icon: Icons.camera_alt_outlined,
                        title: 'Fast count',
                        subtitle: 'Photo-first stock intake',
                        onTap: () => _startCount(branchId, user.uid),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionCard(
                        icon: Icons.grid_view_rounded,
                        title: 'Stock review',
                        subtitle: 'Names, quantities & photos',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => StockReviewPage(branchId: branchId)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(color: const Color(0xFFEAF8F0), borderRadius: BorderRadius.circular(14)),
                          child: const Icon(Icons.cloud_done_outlined, color: AppTheme.success),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Offline-first', style: TextStyle(fontWeight: FontWeight.w800, color: AppTheme.ink)),
                              SizedBox(height: 3),
                              Text('Firestore keeps cached data available and syncs changes when connection returns.', style: TextStyle(fontSize: 12, color: AppTheme.mutedInk, height: 1.4)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: AppTheme.primary),
            const SizedBox(height: 12),
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppTheme.ink)),
            const SizedBox(height: 2),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: AppTheme.mutedInk)),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(13)),
                child: Icon(icon, color: AppTheme.primary),
              ),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(fontSize: 11, color: AppTheme.mutedInk)),
            ],
          ),
        ),
      ),
    );
  }
}
