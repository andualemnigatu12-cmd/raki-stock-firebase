# Raki Stock Owner Web — V2 pilot

This is an actual Firebase client, not a design mock-up. It uses Firebase Auth, Firestore, the `registration_entries` queue, `products`, and the immutable `inventory_movements` audit collection.

## Deployment setup (do not use for real stock yet)
1. In Firebase Console for project `raki-stock-f3ab9`, register a **Web app**. Copy its **Web API key**, **Project ID** and **Web App ID** from SDK setup. This is app configuration, **not** an admin secret.
2. Under Firebase Authentication > Settings > Authorized domains, add the exact GitHub Pages host for the site.
3. In GitHub > repository Settings > Pages, publish from `main` / `(root)`. Open the `owner-web/` subfolder on the Pages site.
4. The initial setup form stores the public Firebase web configuration in this browser only; no keys, passwords, service accounts, or keystores are committed to GitHub.
5. Sign in using the existing Firebase Auth owner credentials. The website reads `users/{uid}` and refuses profiles without `role: owner`, `active: true`, and `branchId`.
6. **Before** creating new V2 entries, deploy the matching updated `firestore.rules` from GitHub to Firebase Console. Existing deployed rules likely do not recognize `registration_entries` or `inventory_movements`.
7. Pilot an entry from website and Flutter, approve it with a positive ETB price, then verify the `products` quantity and exactly one `inventory_movements/{entryId}`.
8. Export JSON and verify two backups before counting real products.

## Known limitations / launch blockers
- **No shared photo hosting:** Flutter stores photos only on the capture phone. The website displays a truthful local-only warning, not an image. A privacy-appropriate external file service is required to share photographs without Firebase Storage billing. Never put full-resolution photos/base64 in Firestore.
- **No production POS yet:** Employees cannot check out carts, accept payments, process refunds, or close cash shifts in this V2 pilot.
- **No production data migration executed:** V1 test records are untouched. V2 uses prefixed product IDs to prevent accidental overwrite. The owner must manually confirm any eventual migration.
- **Limited collection windows:** UI currently listens to the first 2,000 branch registrations/products. Build paginated indexing before larger inventories or long-running production deployment.
- **No server-enforced invariant against a compromised owner account:** owner access is trusted; monitor owner sessions and use MFA when available. Employee writes are limited by Firestore rules.
- Firestore transaction approval requires internet. Worker capture may queue locally; verify pending writes have reached Firebase before trusting counts.
- **Do not expose this as a live shop system** until rules, repeated-item accumulation, offline/restart recovery, Android build, and reconciliation tests pass.

## Product review invariant
A product registration does not change `stockQty` until owner approval. Approval must specify an official product name/size, positive price, and positive counted quantity. The client uses an online Firestore transaction to check `status=pending`, to create one movement keyed by entry ID, to increase the existing product stock, and finally to mark the entry approved. Repeated attempts on an approved entry do not add stock again.

See [rollout plan](../docs/v2-rollout.md).
