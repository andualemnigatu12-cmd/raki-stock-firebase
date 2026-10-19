# Raki Stock — shared product photograph implementation

**Status 2026-10-19:** Website now supports reading secure-format `photoUrl` fields with a "Phone only" fallback. Flutter uploader is staged in `feature/secure-shared-product-photos`, **not active or released**. No user photos have been uploaded by this change.

## Why separate storage?

Firebase Storage requires Blaze billing, whereas the owner explicitly requires Spark (no billing). A Supabase Free Storage project provides 1 GB shared file storage and limited monthly bandwidth. For 1,000 products, compress each original JPEG to ideally 100–300 KB without losing readable packaging, so the initial count uses about 100–300 MB plus thumbnails; actual storage must be measured. A free project may pause after inactivity. Track quotas and exports.

## Planned flow

1. Flutter count takes a photo and writes the local file first.
2. Create a durable, idempotent `pending_photo_uploads` queue on the phone. **Do not delete the local file before uploading.**
3. Try upload with Firebase user ID token to the separate Supabase Storage service with the provider's publishable key (not service-role key).
4. Supabase validates Firebase JWT and RLS `INSERT` policy, branch/UID folder, content type and maximum file size.
5. Store `photoUrl` only after upload success, without changing quantities/price/approval.
6. Website renders `photoUrl` for both pending items and approved catalog products. Missing photo stays clearly marked as phone-only/missing.
7. Retry queue on app restart, network reconnection and manual 'Retry photo sync'; show uploaded/queued/failed counts.
8. Owner never approves a product solely from OCR. Confirm name, size, barcode and price; treat image as evidence.

## Required external setup (not yet completed)

- Create Supabase **Free** project.
- In Supabase Authentication settings add **Firebase Auth third-party provider**, project id `raki-stock-f3ab9`.
- Create **public** bucket `raki-product-photos`. Public means anyone possessing an object URL can view it. Uploads remain gated by RLS and Firebase signed-in identity. If privacy requires private images later, replace public bucket + URLs with authenticated signed URLs.
- Restrict bucket to `image/jpeg` with max 3 MB/object.
- Add RLS **INSERT-only** policy: JWT must be a verified Firebase token for `raki-stock-f3ab9`, token `sub` must equal the second folder (UID) of object name, first folder must equal `raki-bale-robe`, and bucket id must match. Do not allow public anonymous uploads, UPDATE, DELETE or overwrite. Supabase's Firebase third-party provider may map tokens without the `role` claim to `anon`; if using that mode, write the RLS policy to strictly require signed token issuer/audience/sub — NEVER allow an unauthenticated request merely because it uses the anon role.
- Add Supabase project URL and **publishable** API key as public Flutter build parameters `RAKI_PHOTO_SUPABASE_URL` and `RAKI_PHOTO_SUPABASE_PUBLISHABLE_KEY`. Never put a Supabase service_role key or Google service account JSON in Flutter.
- Wire count upload queue, Firestore URL updates, and owner website fallback after integration tests.

## Invariants

- Public shareable product images are a conscious tradeoff on a free no-server plan; uploads always require verified Firebase user token.
- Capture speed must not wait for network upload. Worker can capture next item immediately.
- Product `stockQty` and sales amounts must not be touched by photo sync.
- On failure: status is queued/failed, local photo retained, no false "synced" state.
- Deduplicate by immutable entry ID and object path; remote HTTP 409 is treated as a retry, never blindly overwrite.
- No cutover to live shop records until test images show on *another* device with the correct owner account.
