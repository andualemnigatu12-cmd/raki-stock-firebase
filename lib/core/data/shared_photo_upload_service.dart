import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Optional secure image uploader for the free Supabase Storage backend.
////
//// IMPORTANT: Do not call this from the live capture path until the bucket's
//// Firebase third-party-auth integration and Storage RLS policies are deployed
//// and we have added a durable retry queue for offline captures.
////
//// The Supabase publishable key is not a secret. Firebase ID tokens authenticate
//// uploads; the Supabase policy must verify issuer, audience, UID and folder.
class SharedPhotoUploadService {
  const SharedPhotoUploadService();

  static const String _supabaseBaseUrl = String.fromEnvironment(
    'RAKI_PHOTO_SUPABASE_URL',
  );

  static const String _publishableKey = String.fromEnvironment(
    'RAKI_PHOTO_SUPABASE_PUBLISHABLE_KEY',
  );

  static const String bucket = 'raki-product-photos';

  bool get configured =>
      _supabaseBaseUrl.isNotEmpty && _publishableKey.isNotEmpty;

  /// Uploads a count photo only after the original image has been saved locally.
  /// On success, writes the shared URL onto the original count item.
  /// Callers must wait until the initial count document is safely persisted.
  ///
  /// Failure leaves the original local photograph untouched so it can be
  /// retried later. This method does NOT itself provide the retry queue.
  Future<String> uploadCountPhoto({
    required String branchId,
    required String sessionId,
    required String itemId,
    required String photoPath,
  }) async {
    if (!configured) {
      throw StateError('Shared photo storage has not been configured.');
    }

    final owner = FirebaseAuth.instance.currentUser;
    if (owner == null) {
      throw StateError('Sign in before uploading product photographs.');
    }

    final root = Uri.tryParse(_supabaseBaseUrl);
    if (root == null ||
        root.scheme != 'https' ||
        !root.host.endsWith('.supabase.co') ||
        root.path.isNotEmpty && root.path != '/') {
      throw StateError('Invalid Supabase Storage service URL.');
    }

    final file = File(photoPath);
    if (!await file.exists()) {
      throw StateError('Local photo is missing; cannot upload it.');
    }
    final length = await file.length();
    if (length < 1 || length > 3 * 1024 * 1024) {
      throw StateError('Photo must be between 1 byte and 3 MB.');
    }

    // One immutable object per captured count entry. The random itemId used
    // by Fast Count makes retries safe and avoids overwriting another image.
    final objectPath = [branchId, owner.uid, sessionId, '$itemId.jpg']
        .map(Uri.encodeComponent)
        .join('/');

    final uploadUri = root.replace(
      path: '/storage/v1/object/$bucket/$objectPath',
      query: '',
      fragment: '',
    );
    final publicUri = root.replace(
      path: '/storage/v1/object/public/$bucket/$objectPath',
      query: '',
      fragment: '',
    );

    final idToken = await owner.getIdToken();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client
          .postUrl(uploadUri)
          .timeout(const Duration(seconds: 9));
      request.headers.set('apikey', _publishableKey);
      request.headers.set('Authorization', 'Bearer $idToken');
      request.headers.contentType = ContentType('image', 'jpeg');
      request.headers.set('x-upsert', 'false');
      request.contentLength = length;
      await request.addStream(file.openRead());

      final response = await request
          .close()
          .timeout(const Duration(seconds: 22));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 5));

      // 409 can occur after a successful remote upload followed by an
      // interrupted Firestore acknowledgement; the immutable path is the same.
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.created &&
          response.statusCode != HttpStatus.conflict) {
        throw HttpException(
          'Shared photo upload failed (${response.statusCode}): '
          '${body.length > 160 ? body.substring(0, 160) : body}',
          uri: uploadUri,
        );
      }

      // Only the existing count document's author (or owner) can add this
      // field, under the branch-bound Firestore rules already in use.
      final ref = FirebaseFirestore.instance
          .collection('stock_count_sessions')
          .doc(sessionId)
          .collection('items')
          .doc(itemId);

      await ref.set({
        'photoUrl': publicUri.toString(),
        'photoState': 'shared',
        'photoSyncedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      return publicUri.toString();
    } finally {
      client.close(force: true);
    }
  }
}
