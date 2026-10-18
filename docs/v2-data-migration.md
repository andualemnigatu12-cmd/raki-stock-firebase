# Raki Stock V2 — Migration and data safety contract

Status: implementation plan; NOT production-ready. All existing Firebase records remain untouched.

## Migration phases

1. **Snapshot and audit:** export or snapshot legacy `users`, `branches`, `products`, and `stock_count_sessions` including nested `items`. Check counts and preserve a read-only copy. Do not assume deleting test data is safe; verify owner account/branch stay intact.
2. **Parallel V2 namespace:** introduce `v2_products`, `v2_count_entries`, `v2_stock_movements`, `v2_sales`, `v2_shifts`, `v2_audit_events`. New features operate here first. Do not overwrite legacy `products.stockQty`.
3. **Security:** update Firestore rules for V2, enforce employee write scope, owner price/approval privilege and immutable approved/sales/ledger records. Test with emulator/security rules test cases BEFORE publishing.
4. **Pilot:** create a V2 trial with 20 products, including duplicate/no-barcode products, offline capture, double taps, two devices and a failed network. Reconcile all counts manually.
5. **Cutover:** confirm all pending writes synced and initial stock approved/priced; archive legacy data and switch active app catalog atomically using a version/config flag. Keep rollback, never silently merge uncertain records.

## V2 conceptual schema

`v2_products/{productId}`:
`branchId, name, normalizedName, barcode?, variantLabel?, size?, unit, priceMinor?, currency:'ETB', imageUrl?, status:'pending'|'active'|'rejected', createdAt, approvedAt?, approvedBy?`.
An active product MUST have owner-verified name, selling price >= 0 in integer cents and a stable identity. The database must not grant employees price/approval writes.

`v2_count_entries/{entryId}`:
`branchId, sessionId, productCandidateId?, barcode?, nameCandidate, quantity, unit, localPhotoPath?, imageUrl?, status:'pending'|'reviewed'|'rejected', capturedBy, capturedAt, clientMutationId, syncedAt?`.
Entries are append-only; repeated counts NEVER overwrite historical entries. Corrections are versioned, and every mutation uses a unique idempotency key.

`v2_stock_movements/{movementId}`:
`branchId, productId, kind:'opening_count'|'sale'|'purchase'|'damage'|'return'|'adjustment'|'reversal', qtyDelta, sourceId, actorUid, createdAt, approvalUid?, reason?`.
Each approved count entry produces one idempotent opening-count movement. Repeated entries add quantities. Corrections use compensating deltas, not deletion. The server-side transaction enforces exactly-once application.

`v2_sales/{saleId}`:
`branchId, employeeUid, lines:[{productId, qty, priceMinor}], totalMinor, paymentMethod, paymentReference?, state, createdAt, clientMutationId`.
Checkout must atomically record sale, decrement stock and record movements; clients cannot adjust totals or stock independently. Firestore-only client batch rules may be insufficient; evaluate trusted backend/Cloud Functions cost against free-tier constraints before launch.

`v2_shifts` and `v2_audit_events`: opening float, expected/actual close, discrepancies, actor/time/correction reason. Neither staff nor owner should erase completed financial events; reversals are new events.

## Identity and duplicate matching

Exact barcode+packaging unit -> same product. Same normalized name + matching size/unit -> candidate. OCR/photo is a suggestion, NOT automatic merging for ambiguous matches. Separate units/variants (500 ml vs 1 L, carton vs piece) must never merge. Show the existing product and ask for confirmation before appending count.

## Review and pricing

Employee capture -> PENDING; owner can correct name/variant/unit/barcode, attach an accessible photo, enter verified selling price and approve. No product appears as available for POS until active and approved. Bulk approve WITHOUT price is forbidden.

## Photos & costs

Legacy pictures are local device paths, not cross-device links. Cross-device website review needs secure photo hosting or manual owner photo upload; Firebase Storage may require billing. Do not store image base64 blobs in Firestore, do not pretend a local path can show on desktop. Keep photo state visible as missing/pending.

## Website

`web-owner/` contains a non-destructive, read-only initial dashboard. It intentionally does not approve, edit or delete anything until V2 rules and atomic stock logic exist. Web Firebase app registration/config, Auth authorized domain, and GitHub Pages deployment are separate manual steps.

## Release gate

No real-shop launch until: tested offline recovery, successful sync, duplicate additive counts across sessions, idempotency, enforced price review, multi-user permissions, photo visibility or explicit fallback, sale/stock atomicity, refunds/voids, reconciled closing and verified export/restore. Run 20-product then 100-product pilot.