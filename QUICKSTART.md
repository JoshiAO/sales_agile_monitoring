# Quick Start

This guide gets Compact Sales Monitoring running with the current role-based app structure.

## What You Get

- Salesman app with Calls and Agile tabs
- Supervisor app with Home, Map, and Agile tabs
- Superuser app with Home, Map, Agile, archive, and user management

## Prerequisites

- Flutter SDK installed
- A Firebase project
- FlutterFire CLI installed
- At least one Android device or emulator for Salesman testing
- Windows, macOS, or web target for Supervisor and Superuser testing

## Install Dependencies

```bash
flutter pub get
```

## Configure Firebase

```bash
flutterfire configure
```

Make sure these generated files exist after configuration:

- lib/firebase_options.dart
- android/app/google-services.json
- platform Firebase config files created by FlutterFire

## Deploy Rules

If you use the included Firebase rules, deploy them from the project root:

```bash
firebase deploy --only firestore:rules
firebase deploy --only storage
```

## Optional: Functions For Credential Updates

The superuser user-management flow includes support for updating auth credentials through Cloud Functions.

Deploy functions when needed:

```bash
cd functions
npm install
cd ..
firebase deploy --only functions
```

## Run The App

### Android

```bash
flutter run -d android
```

### Windows

```bash
flutter run -d windows
```

### Build APK

```bash
flutter build apk
```

## Role Flows

### Salesman

- Calls tab: capture first and last call photos with GPS details
- Agile tab: submit total calls, productive calls, and STT actual

### Supervisor

- Home: see assigned salesmen summaries
- Map: inspect routes by date
- Agile: set daily targets and compare actual submissions

### Superuser

- Home: supervisor team summary view
- Map: global route monitoring and archive action
- Agile: supervisor-level Agile rollups
- User Management: create, edit, activate, deactivate, and delete users

## Required Firestore Collections

- users
- routes
- agile_targets
- agile_submissions

## Suggested Test Accounts

- salesman@demo.com
- supervisor@demo.com
- superuser@demo.com

## Recommended First Test

1. Sign in as a salesman and complete first/last call capture.
2. Submit an Agile entry for the same day.
3. Sign in as a supervisor and verify Home, Map, and Agile data.
4. Sign in as a superuser and verify global summaries and user management.

## Useful Commands

```bash
flutter analyze
flutter test
flutter build apk
```

## More Docs

- README.md
- FIREBASE_SETUP.md
- SETUP_CHECKLIST.md
- PROJECT_SUMMARY.md
- ARCHITECTURE.md
