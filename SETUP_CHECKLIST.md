# Setup Checklist - Compact Sales Monitoring

This checklist will guide you through the complete setup process. Follow each step carefully.

## Phase 1: Project Setup ✓

- [ ] Clone the repository
- [ ] Run `flutter pub get`
- [ ] Verify Flutter version is 3.11.4 or higher (`flutter --version`)
- [ ] Verify Dart version is 3.11.4 or higher (`dart --version`)
- [ ] Install FlutterFire CLI: `dart pub global activate flutterfire_cli`

## Phase 2: Firebase Project Creation

### 2.1 Create Firebase Project
- [ ] Go to https://console.firebase.google.com
- [ ] Click "Create a project"
- [ ] Project Name: `compact-sales-monitoring`
- [ ] Enable Google Analytics (recommended)
- [ ] Accept Firebase Terms
- [ ] Create project

### 2.2 Configure FlutterFire
- [ ] Run: `flutterfire configure`
- [ ] Select all platforms:
  - [ ] Android
  - [ ] iOS
  - [ ] macOS
  - [ ] Windows
- [ ] Choose Firebase project: `compact-sales-monitoring`
- [ ] Wait for configuration to complete
- [ ] Verify:
  - [ ] `android/build.gradle` updated
  - [ ] `ios/firebase.json` created
  - [ ] `macos/firebase.json` created
  - [ ] `windows/firebase.json` created

## Phase 3: Firebase Services Configuration

### 3.1 Authentication
- [ ] Go to Firebase Console → Authentication
- [ ] Click "Get Started"
- [ ] Enable "Email/Password" provider
- [ ] (Optional) Add Google Sign-In provider
- [ ] Add test users:
  - [ ] `salesman@demo.com` / `Demo@123`
  - [ ] `supervisor@demo.com` / `Demo@123`
  - [ ] `superuser@demo.com` / `Demo@123`

### 3.2 Firestore Database
- [ ] Go to Firestore Database
- [ ] Click "Create database"
- [ ] Select "Production mode"
- [ ] Choose region (e.g., `us-central1`)
- [ ] Create database
- [ ] Update Firestore Rules (see FIREBASE_SETUP.md)

### 3.3 Firebase Storage
- [ ] Go to Storage
- [ ] Click "Get started"
- [ ] Update Storage Rules (see FIREBASE_SETUP.md)

## Phase 4: Configuration Files

### 4.1 Update Constants
- [ ] Get OpenRouteService API key from https://openrouteservice.org
- [ ] Update `lib/constants/app_constants.dart`:
  ```dart
  static const String openRouteServiceApiKey = 'YOUR_API_KEY_HERE';
  ```

### 4.2 Android Configuration
- [ ] Update `android/app/build.gradle`:
  ```gradle
  android {
      compileSdkVersion 34
      defaultConfig {
          minSdkVersion 23
          targetSdkVersion 34
      }
  }
  ```
- [ ] Update `android/gradle.properties`:
  ```properties
  org.gradle.jvmargs=-Xmx4096m
  android.useAndroidX=true
  android.enableJetifier=true
  ```
- [ ] Verify `android/app/src/main/AndroidManifest.xml` has permissions

### 4.3 iOS Configuration
- [ ] Update `ios/Podfile` (platform should be iOS 12+)
- [ ] Run:
  ```bash
  cd ios
  pod deintegrate
  pod install
  cd ..
  ```
- [ ] Verify `ios/Runner/Info.plist` has permission descriptions

## Phase 5: Create Firestore Data

### 5.1 Create Users Collection
Navigate to Firestore → Create collection "users"

**Document: salesman@demo.com**
```json
{
  "email": "salesman@demo.com",
  "role": "salesman",
  "active": true,
  "supervisorId": "[SUPERVISOR_UID_FROM_NEXT_STEP]",
  "profilePic": null
}
```

**Document: supervisor@demo.com**
```json
{
  "email": "supervisor@demo.com",
  "role": "supervisor",
  "active": true,
  "supervisorId": null,
  "profilePic": null
}
```

**Document: superuser@demo.com**
```json
{
  "email": "superuser@demo.com",
  "role": "superuser",
  "active": true,
  "supervisorId": null,
  "profilePic": null
}
```

- [ ] Update salesman's `supervisorId` with supervisor's UID
- [ ] Create empty "routes" collection (will be populated later)

## Phase 6: Testing & Deployment

### 6.1 Build & Test

#### Android (Salesman)
- [ ] Connect Android device or start emulator
- [ ] Run: `flutter run -t lib/main.dart`
- [ ] Test login with: `salesman@demo.com` / `Demo@123`
- [ ] Test photo capture
- [ ] Verify images upload to Firebase Storage
- [ ] Check Firestore for route metadata

#### Desktop Windows (Supervisor/SuperUser)
- [ ] Run: `flutter run -d windows -t lib/main.dart`
- [ ] Test Supervisor login: `supervisor@demo.com` / `Demo@123`
- [ ] Verify map loads
- [ ] Test SuperUser login: `superuser@demo.com` / `Demo@123`
- [ ] Test user management

#### macOS (Optional)
- [ ] Run: `flutter run -d macos -t lib/main.dart`
- [ ] Repeat desktop tests

### 6.2 Create Sample Data
- [ ] Use Salesman app to create a route (take first & last photo)
- [ ] Verify in Firestore: routes collection populated
- [ ] Verify in Firebase Storage: images stored

### 6.3 Test All Features
- [ ] Salesman: Login → Capture photos → View status
- [ ] Supervisor: Login → Select date → View map → Click pins → See modal
- [ ] SuperUser: Login → View all routes → Manage users → Activate/deactivate

## Phase 7: Production Preparation

- [ ] [ ] Replace demo API keys with production keys
- [ ] [ ] Update Firebase security rules for production
- [ ] [ ] Enable Firebase monitoring (Analytics, Crashlytics)
- [ ] [ ] Set up error logging
- [ ] [ ] Test on real devices (not emulator)
- [ ] [ ] Review and optimize performance
- [ ] [ ] Set up backup strategy
- [ ] [ ] Update app icons and splash screens
- [ ] [ ] Create release build for Android: `flutter build apk --release`
- [ ] [ ] Create release build for iOS: `flutter build ios --release`
- [ ] [ ] Test release builds thoroughly

## Phase 8: Monitoring & Maintenance

- [ ] Set up Firebase Console alerts
- [ ] Monitor API quota usage (OpenRouteService)
- [ ] Monitor Firestore usage
- [ ] Monitor Firebase Storage usage
- [ ] Review error logs regularly
- [ ] Plan for scaling if needed

## Troubleshooting Checklist

If you encounter issues, check:

- [ ] Firebase project is active and accessible
- [ ] FlutterFire configuration files are present
- [ ] API keys are correct and active
- [ ] Firestore rules allow your operations
- [ ] Android SDK version meets minimum requirements (SDK 23)
- [ ] iOS version meets minimum requirements (iOS 12)
- [ ] Internet connectivity is working
- [ ] Permissions are granted on test device
- [ ] Emulator/device has enough storage
- [ ] No conflicting package versions in pubspec.yaml

## Quick Reference Commands

```bash
# Check Flutter status
flutter doctor -v

# Get dependencies
flutter pub get

# Configure Firebase
flutterfire configure

# Run on Android
flutter run -t lib/main.dart

# Run on Windows
flutter run -d windows -t lib/main.dart

# Run on macOS
flutter run -d macos -t lib/main.dart

# Build APK for Android
flutter build apk --release

# Build iOS
flutter build ios --release

# Clean build
flutter clean && flutter pub get

# Analyze code
flutter analyze

# Format code
dart format lib/
```

## Support Resources

- [README.md](README.md) - Project overview
- [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Detailed implementation
- [FIREBASE_SETUP.md](FIREBASE_SETUP.md) - Firebase configuration
- [Flutter Documentation](https://flutter.dev/docs)
- [Firebase Documentation](https://firebase.google.com/docs)

---

**Estimated Setup Time**: 30-45 minutes  
**Last Updated**: April 2026
