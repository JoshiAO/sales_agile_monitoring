# Setup Checklist

Use this checklist to set up the current version of Compact Sales Monitoring.

## 1. Local Environment

- [ ] Install Flutter SDK
- [ ] Confirm Flutter works with `flutter doctor -v`
- [ ] Install FlutterFire CLI with `dart pub global activate flutterfire_cli`
- [ ] Run `flutter pub get`

## 2. Firebase Project

- [ ] Create or choose a Firebase project
- [ ] Enable Email/Password authentication
- [ ] Create Cloud Firestore in production mode
- [ ] Create Firebase Storage

## 3. FlutterFire Configuration

- [ ] Run `flutterfire configure`
- [ ] Select the platforms you plan to use
- [ ] Confirm `lib/firebase_options.dart` exists
- [ ] Confirm Android Firebase config exists at `android/app/google-services.json`

## 4. Deploy Rules

- [ ] Deploy Firestore rules with `firebase deploy --only firestore:rules`
- [ ] Deploy Storage rules with `firebase deploy --only storage`

## 5. Optional Functions Support

- [ ] Open the `functions/` folder
- [ ] Run `npm install`
- [ ] Deploy functions with `firebase deploy --only functions`

## 6. Firestore Collections

Confirm the app can use these collections:

- [ ] `users`
- [ ] `routes`
- [ ] `agile_targets`
- [ ] `agile_submissions`

## 7. Seed Minimum Users

- [ ] Create one superuser account
- [ ] Create one supervisor account
- [ ] Create one salesman account
- [ ] Assign the salesman to the supervisor in Firestore
- [ ] Ensure each Firestore user document includes role and active status

## 8. Test Salesman Flow

- [ ] Sign in as salesman
- [ ] Capture a first call
- [ ] Capture a last call
- [ ] Verify route data is stored in `routes`
- [ ] Open Agile tab and submit daily actuals
- [ ] Verify the submission is stored in `agile_submissions`

## 9. Test Supervisor Flow

- [ ] Sign in as supervisor
- [ ] Check Home tab assigned-salesman summaries
- [ ] Check Map tab route visibility for the selected date
- [ ] Open route details from the map or preview flow
- [ ] Open Agile tab and save daily targets
- [ ] Verify targets are stored in `agile_targets`

## 10. Test Superuser Flow

- [ ] Sign in as superuser
- [ ] Review Home tab supervisor summaries
- [ ] Review Map tab global route data
- [ ] Test archive action
- [ ] Review Agile rollup summaries
- [ ] Create or edit a user from user management

## 11. Final Validation

- [ ] Run `flutter analyze`
- [ ] Build an APK with `flutter build apk`
- [ ] Confirm README and setup docs match your Firebase project details

## Quick Commands

```bash
flutter pub get
flutterfire configure
firebase deploy --only firestore:rules
firebase deploy --only storage
firebase deploy --only functions
flutter analyze
flutter build apk
```

## Related Docs

- README.md
- QUICKSTART.md
- FIREBASE_SETUP.md
- PROJECT_SUMMARY.md
- ARCHITECTURE.md
