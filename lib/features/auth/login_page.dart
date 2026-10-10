import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Could not sign in.');
    } catch (_) {
      setState(() => _error = 'Could not sign in.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createFirstOwner() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
      final uid = credential.user!.uid;
      final db = FirebaseFirestore.instance;
      const branchId = 'raki-bale-robe';
      final batch = db.batch();
      batch.set(db.collection('branches').doc(branchId), {
        'name': 'Raki Shop',
        'location': 'Bale Robe',
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batch.set(db.collection('users').doc(uid), {
        'email': _email.text.trim().toLowerCase(),
        'role': 'owner',
        'branchId': branchId,
        'displayName': 'Owner',
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Could not create owner account.');
    } catch (_) {
      setState(() => _error = 'Could not create owner account.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'R',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text('Raki Stock', style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 6),
                      const Text('Fast, offline-first stock counting for the shop.'),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Email'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        onSubmitted: (_) => _signIn(),
                        decoration: const InputDecoration(labelText: 'Password'),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _busy ? null : _signIn,
                        child: Text(_busy ? 'PLEASE WAIT…' : 'SIGN IN'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: _busy ? null : _createFirstOwner,
                        child: const Text('Create first owner account'),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Use the owner button only once on a brand-new Firebase project.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: AppTheme.mutedInk),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
