# Raki Stock owner dashboard — SAFE PREVIEW

This directory is a **read-only owner dashboard prototype**, not a finished POS. It does not publish automatically and does not write to Firestore.

## Before deployment

1. Register a **Web App** (</> icon) in the existing Firebase project `raki-stock-f3ab9`. Copy its public web config into `firebase-config.js`. NEVER add a Firebase service-account private key.
2. Add the final GitHub Pages domain to Firebase Authentication > Settings > Authorized domains.
3. Serve `web-owner/` using GitHub Pages (folder support depends on selected Pages source) or move static files to `docs/` only after confirming deployment approach. Do not enable automatic hosting without checking.
4. Sign in with the existing owner Firebase email/password. The page checks active owner role from `users/{uid}` and reads only same-branch records under existing Firestore rules.

## Current limitations

- No approval, price entry, sales, inventory mutation, exports or employee dashboard here yet.
- Shows at most 200 products and 50 sessions; counts at most 500 items per session, and reads sequentially. Counts are only a preview, not a complete audit.
- Product photos are local paths on Android and cannot be opened from the website.
- The web app config is not a secret; security depends on Firebase Auth and Firestore rules, not hidden JS keys.
- Firestore V2 collections/rules are NOT deployed. Legacy Firestore data remains untouched.

See `../docs/v2-data-migration.md` for migration and launch gates.
