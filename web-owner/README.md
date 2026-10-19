# Raki Stock owner website — connected SAFE PREVIEW

**Status:** Firebase Web App configuration is wired into `firebase-config.js`, and `firebase.json` defines Firebase Hosting. The website is NOT yet deployed. This is a read-only review/catalog preview; it is not yet the production owner control panel.

## Firebase project

- Firebase project: `raki-stock-f3ab9`
- Web app: Raki Stock Owner Web
- Hosting destination (after first successful deploy): `https://raki-stock-f3ab9.web.app` (verify actual URL in Firebase Hosting)
- Firebase Authentication: sign in using existing **active owner** credentials.
- Firestore: reads legacy test `products`, `stock_count_sessions` and nested `items`; it does not write to the database.
- `firebase-config.js` is PUBLIC web configuration, not a secret. The active security boundary remains Auth + Firestore rules.

## Deploy only website (Firebase Spark plan)

1. In Firebase Console > Build > Hosting, complete free Hosting setup. Use **Firebase Hosting**, not Firebase **App Hosting** (which may require Blaze billing).
2. Install Firebase CLI locally if needed: `npm install -g firebase-tools`.
3. Sign in: `firebase login`.
4. In repository root deploy *only Hosting*: `firebase deploy --only hosting --project raki-stock-f3ab9`.
5. Open the exact URL shown by Firebase and test with owner credentials. Add the hosting domain to Authentication > Settings > Authorized domains if the sign-in flow requires it.
6. Do not run `firebase deploy` without `--only hosting`: Firestore/security rules must go through a separate reviewed change process.

## Preview limitations and protections

- No product approval, selling price entry, sales, stock changes, exports, or destructive controls yet.
- Product images are stored only on the Flutter phone. The web preview can display photo availability but **cannot fetch these images from another device**. Shared hosting must be designed separately without obliging a paid Firebase Storage plan.
- Product list is limited to 200 and session list to 50 (up to 500 count entries per session); counts are illustrative, not complete audits.
- The Firestore nested items query requires each count item to have `branchId`. Older test records missing this field will not appear.
- We have not yet created or deployed the V2 collections or new Firestore rules. No existing test data was deleted.
- Before handling real products, implement idempotent count movements, duplicate confirmation, owner-only price approval, cash reconciliation, secure sales, and reliable backup/restore and test these end to end.

See [V2 migration and data-safety contract](../docs/v2-data-migration.md).
