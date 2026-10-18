# Raki Stock V2 — safe rollout (pilot only)

**Never delete or bulk overwrite existing Firebase records.** User confirmed old records are tests, but they remain untouched for rollback. Current V1 `stock_count_sessions` and `products` stay readable. The new workflow writes a separate `registration_entries` collection until the owner approves an entry.

## Shared data contract
- `registration_entries/{entryId}`: `branchId`, `createdBy`, `quantity` (positive integer), `nameCandidate`, `barcodeCandidate`, `productText`, `localPhotoPath`, `photoState: local_only`, `section`, `status: pending`, `createdAt`. Workers only create pending entries.
- `products/{productId}`: official `name`, `normalizedName`, `barcode`, `sellingPrice > 0`, `stockQty` (nonnegative integer), `branchId`, `active`. Owner-only create/change.
- `inventory_movements/{entryId}`: one immutable movement per approved entry, `type: opening_count`, `productId`, `quantityDelta`, `beforeQty`, `afterQty`, `branchId`, `createdBy`, `capturedBy`, `createdAt`. Each entry can be applied only once.
- A product can have multiple entries; their quantities **add** in one Firestore transaction on approval, never replace the previous quantity.
- Owner reviews official name, unit/size, barcode, quantity and selling price before approval. Web and Flutter call the same Firestore collections.
- Multiple packaging sizes are separate products. Same name with different nonempty barcodes must not auto-merge. When uncertain, stop and require manual identification.

## Release gates
1. Keep V1 APK installed. Do not clear or migrate the existing Firebase data yet.
2. Commit V2 code; do not deploy updated security rules until they are reviewed in Firebase Console.
3. Register a Firebase Web app and configure public web app values for the website. No Firebase Storage billing.
4. Camera photos remain **on the capturing phone only**. The owner website cannot view local files; do not represent them as synced. Shared photos need a separate, approved provider/configuration; **do not store base64 photos in Firestore**.
5. Pilot: 20 products, 5 repeated scans, 2 simultaneous owner approval attempts for one entry, offline capture/reconnect, invalid price, wrong barcode, test rollbacks. Verify `sum(movement.quantityDelta) == product.stockQty` for *new V2 products*. Correct deviations before further counts.
6. Export/backup products, registrations and movements as JSON before any real stock launch and after each counted section. Keep two verified independent copies. No sale/checkout allowed until its own atomic transaction, payment reconciliation, and refunds/voids are tested.
7. Test at 100 then 1,000 unique products. Confirm search, scan and review performance on actual low-end phone.
8. Explicit owner approval needed to switch shop from paper/counter to Raki Stock. Until then it is a parallel pilot.

## Constraints
- Firebase Spark only; no paid Storage assumed.
- Mobile capture should feel fast, using local-first Firestore cache and one camera/OCR pass.
- Firestore transactions used for owner approval require connectivity; employee capture may queue locally.
- A signed Android APK must pass GitHub Action build before installation.
