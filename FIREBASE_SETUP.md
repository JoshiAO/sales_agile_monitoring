# Firebase Setup

This project uses Firebase Authentication, Cloud Firestore, Firebase Storage, and optional Cloud Functions.

## Services Used

- Firebase Authentication
- Cloud Firestore
- Firebase Storage
- Cloud Functions for Firebase

## 1. Configure FlutterFire

Run from the project root:

```bash
flutterfire configure
```

Recommended platforms:

- Android
- Windows
- macOS
- iOS if you plan to support it
- Web if you plan to test the web target

## 2. Enable Authentication

In Firebase Console:

1. Open Authentication.
2. Enable Email/Password sign-in.
3. Create your initial users or prepare to seed them later.

## 3. Create Firestore Database

1. Open Firestore Database.
2. Create the database in production mode.
3. Choose a region close to your users.

## 4. Deploy Firestore Rules

The repository already contains current rules for:

- role-based user access
- route visibility
- Agile target permissions
- Agile submission permissions

Deploy them with:

```bash
firebase deploy --only firestore:rules
```

## 5. Create Firebase Storage

1. Open Storage.
2. Create the default bucket.
3. Deploy storage rules:

```bash
firebase deploy --only storage
```

## 6. Collections Used By The App

### users

Stores app users, roles, active state, and supervisor assignment.

Suggested fields:

```json
{
  "uid": "user-id",
  "email": "user@example.com",
  "name": "User Name",
  "role": "salesman",
  "active": true,
  "supervisorId": "supervisor-uid-or-null",
  "profilePic": null,
  "createdAt": "timestamp"
}
```

### routes

Stores first call, last call, checkpoints, cached polyline, and route review fields.

### agile_targets

Stores supervisor-set targets per day and salesman.

Suggested fields:

```json
{
  "supervisorId": "supervisor-uid",
  "salesmanId": "salesman-uid",
  "date": "2026-04-23",
  "productiveCallsTarget": 10,
  "sttTarget": 5000,
  "updatedAt": "timestamp"
}
```

### agile_submissions

Stores salesman actual values and submission state.

Suggested fields:

```json
{
  "supervisorId": "supervisor-uid",
  "salesmanId": "salesman-uid",
  "date": "2026-04-23",
  "totalCalls": 18,
  "productiveCalls": 11,
  "sttActual": 6200,
  "lastCallCompleted": true,
  "submitted": true,
  "submittedAt": "timestamp"
}
```

## 7. Seed Users

You can create users manually in Firebase Authentication and mirror them in Firestore, or use the repository scripts under scripts/ if they match your environment.

Minimum roles needed:

- one superuser
- one supervisor
- one salesman assigned to that supervisor

## 8. Optional Cloud Functions

The functions project includes superuser credential update support.

Install and deploy:

```bash
cd functions
npm install
cd ..
firebase deploy --only functions
```

## 9. Android Notes

Confirm Android has the required permissions for:

- camera
- fine/coarse location
- internet
- photo or storage access as needed by the device version

## 10. Verify End-To-End

1. Salesman logs in and submits a route.
2. Salesman submits Agile actuals.
3. Supervisor sees the route, team summaries, and Agile values.
4. Superuser sees global summaries and can manage accounts.

## Common Commands

```bash
flutterfire configure
firebase deploy --only firestore:rules
firebase deploy --only storage
firebase deploy --only functions
flutter analyze
```

## Related Files

- firestore.rules
- storage.rules
- functions/index.js
- lib/services/firestore_service.dart
- lib/models/agile_model.dart
