import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/data/registration_repository.dart';
import '../../core/theme/app_theme.dart';
import '../registration/registration_page.dart';
import '../registration/registration_review_page.dart';
import '../stock/product_scan_page.dart';
import '../stock/products_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _registration = RegistrationRepository();

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
      builder: (context, profileSnapshot) {
        final profile = profileSnapshot.data?.data();
        final branchId = profile?['branchId'] as String? ?? 'raki-bale-robe';
        final displayName = profile?['displayName'] as String? ?? 'User';
        final role = profile?['role'] as String? ?? 'employee';
        final isOwner = role == 'owner';

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
                  child: const Text(
                    'R',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Raki Stock',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.ink,
                      ),
                    ),
                    Text(
                      'Bale Robe',
                      style: TextStyle(fontSize: 11, color: AppTheme.mutedInk),
                    ),
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
                Text(
                  'Good day, $displayName',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                Text('${role.toUpperCase()} • fast local-first workflow'),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'QUICK PRODUCT LOOKUP',
                        style: TextStyle(
                          color: Color(0xFFDDE2FF),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Search or scan. Find it fast.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Registered products stay in a local catalog for quick search and matching. Barcode matches are instant.',
                        style: TextStyle(
                          color: Color(0xFFDDE2FF),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: AppTheme.primary,
                              ),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ProductsPage(
                                    branchId: branchId,
                                    isOwner: isOwner,
                                    userId: user.uid,
                                  ),
                                ),
                              ),
                              icon: const Icon(Icons.inventory_2_outlined),
                              label: const Text('PRODUCTS'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: AppTheme.primary,
                              ),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ProductScanPage(branchId: branchId),
                                ),
                              ),
                              icon: const Icon(Icons.qr_code_scanner_rounded),
                              label: const Text('SCAN'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'V2 registration pilot',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Capture entries first. Stock changes only after an owner '
                  'verifies name, variant, quantity and selling price.',
                  style: TextStyle(color: AppTheme.mutedInk),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _ActionCard(
                        icon: Icons.add_a_photo_outlined,
                        title: 'Register products',
                        subtitle: 'Capture to pending review',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RegistrationPage(
                              branchId: branchId,
                              userId: user.uid,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionCard(
                        icon: Icons.inventory_2_outlined,
                        title: 'Products',
                        subtitle: 'Approved catalog and search',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ProductsPage(
                              branchId: branchId,
                              isOwner: isOwner,
                              userId: user.uid,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (isOwner) ...[
                  const SizedBox(height: 12),
                  _ActionCard(
                    icon: Icons.verified_outlined,
                    title: 'Owner review · V2',
                    subtitle: 'Confirm name, price and add quantity atomically',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RegistrationReviewPage(
                          branchId: branchId,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _registration.watchEntries(branchId),
                  builder: (context, snapshot) {
                    final docs = snapshot.data?.docs ?? const [];
                    final pending = docs
                        .where((doc) => doc.data()['status'] == 'pending')
                        .length;
                    final approved = docs
                        .where((doc) => doc.data()['status'] == 'approved')
                        .length;
                    return Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            label: 'Pending V2',
                            value: '$pending',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MetricCard(
                            label: 'Approved V2',
                            value: '$approved',
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  'Pilot mode: do not use this for real cash sales yet. '
                  'Old Fast Count, Quick Add and bulk approval are paused.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.mutedInk,
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
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: AppTheme.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

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
                decoration: BoxDecoration(
                  color: AppTheme.primarySoft,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: AppTheme.primary),
              ),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.mutedInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
