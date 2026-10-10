# Raki Stock Firebase

Clean restart of the Raki Shop inventory application.

## Product direction

- Flutter Android app
- Firebase Authentication
- Cloud Firestore with offline persistence
- Firebase Storage for product photos
- Photo-first Fast Count workflow
- On-device OCR first, cloud OCR fallback later
- Owner and employee roles
- Clean modern inventory dashboard UI

## Core count flow

Login -> Dashboard -> Start/Continue Count -> Take product photo -> Detect name -> Enter quantity -> Save & Next -> Review -> Finish.

Counting must never be blocked by slow internet or OCR. Unknown products are kept with a temporary STK code and photo for later review.
