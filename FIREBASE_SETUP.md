# Firebase Configuration Guide

## Prerequisites
- Firebase Project created (https://console.firebase.google.com)
- FlutterFire CLI installed (`dart pub global activate flutterfire_cli`)
- Admin access to Flutter project files

## Step 1: Create Firebase Project
1. Go to Firebase Console
2. Click "Create a new project"
3. Name it "compact-sales-monitoring"
4. Enable Google Analytics (optional but recommended)

## Step 2: Configure FlutterFire
Run in the project root:
```bash
flutterfire configure
```
Select:
- Android ✓
- iOS ✓
- macOS ✓
- Web (optional)
- Windows ✓

This will automatically update your Firebase configuration files.

## Step 3: Enable Firebase Services

### Authentication
1. Go to Firebase Console → Authentication
2. Click "Get Started"
3. Enable "Email/Password" provider
4. (Optional) Add other providers (Google, Facebook, etc.)

### Firestore Database
1. Go to Firestore Database
2. Click "Create database"
3. Start in **Production mode**
4. Select a region close to your users (e.g., us-central1)

### Firebase Storage
1. Go to Storage
2. Click "Get started"
3. Update storage rules when prompted (see step 4)

### Realtime Database (Optional)
Not needed for this project but useful for real-time features.

## Step 4: Set Up Firestore Rules

Update your Firestore security rules:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users collection - only accessible by authenticated users
    match /users/{userId} {
      allow read: if request.auth.uid != null;
      allow create: if request.auth.uid != null && request.resource.data.email == request.auth.token.email;
      allow update: if request.auth.uid != null && 
                      (request.auth.uid == userId || 
                       request.auth.token.role == 'superuser');
      allow delete: if request.auth.uid != null && request.auth.token.role == 'superuser';
    }

    // Routes collection
    match /routes/{routeId} {
      allow read: if request.auth.uid != null;
      allow create: if request.auth.uid != null;
      allow update: if request.auth.uid != null;
      allow delete: if request.auth.uid != null && request.auth.token.role == 'superuser';
    }
  }
}
```

Note: Firestore doesn't support custom claims directly in security rules. For production, implement Cloud Functions to set custom claims.

## Step 5: Set Up Storage Rules

```
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /profile_pictures/{allPaths=**} {
      allow read: if request.auth.uid != null;
      allow write: if request.auth.uid != null;
    }
    match /route_images/{allPaths=**} {
      allow read: if request.auth.uid != null;
      allow write: if request.auth.uid != null;
    }
  }
}
```

## Step 6: Android Configuration

Update `android/app/build.gradle`:
```gradle
android {
    compileSdkVersion 34
    
    defaultConfig {
        minSdkVersion 23
        targetSdkVersion 34
    }
}

dependencies {
    // Firebase is added by FlutterFire, but ensure modern versions
    implementation platform('com.google.firebase:firebase-bom:32.7.0')
}
```

Update `android/gradle.properties`:
```properties
org.gradle.jvmargs=-Xmx4096m
android.useAndroidX=true
android.enableJetifier=true
```

## Step 7: iOS Configuration

Update `ios/Podfile`:
Ensure platform is iOS 12 or higher:
```ruby
platform :ios, '12.0'
```

Run:
```bash
cd ios
pod deintegrate
pod install
cd ..
```

## Step 8: macOS/Windows Configuration

For desktop platforms, FlutterFire configure handles most setup automatically.

## Step 9: Update OpenRouteService API Key

1. Create account at https://openrouteservice.org
2. Get your free API key (2,000 requests/day)
3. Update `lib/constants/app_constants.dart`:
```dart
static const String openRouteServiceApiKey = 'YOUR_ORS_API_KEY_HERE';
```

## Step 10: Create Demo Users

In Firebase Console → Authentication → Users:
1. Add user: `salesman@demo.com` (password: Demo@123)
2. Add user: `supervisor@demo.com` (password: Demo@123)
3. Add user: `superuser@demo.com` (password: Demo@123)

In Firestore → users collection, add documents:

**User 1 (Salesman):**
```json
{
  "email": "salesman@demo.com",
  "role": "salesman",
  "active": true,
  "supervisorId": "supervisor-uid-here",
  "profilePic": null
}
```

**User 2 (Supervisor):**
```json
{
  "email": "supervisor@demo.com",
  "role": "supervisor",
  "active": true,
  "supervisorId": null,
  "profilePic": null
}
```

**User 3 (SuperUser):**
```json
{
  "email": "superuser@demo.com",
  "role": "superuser",
  "active": true,
  "supervisorId": null,
  "profilePic": null
}
```

## Step 11: Permissions Configuration

### Android Permissions (android/app/src/main/AndroidManifest.xml):
```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

### iOS Permissions (ios/Runner/Info.plist):
```xml
<key>NSCameraUsageDescription</key>
<string>We need camera access to capture photos of your route</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>We need your location to tag your photos</string>
```

## Testing the Setup

### Run on Android:
```bash
flutter run -t lib/main.dart --device-id <device-id>
```

### Run on Desktop (Windows/macOS):
```bash
flutter run -t lib/main.dart -d windows
flutter run -t lib/main.dart -d macos
```

### Run on iOS (after setup):
```bash
flutter run -t lib/main.dart -d ios
```

## Troubleshooting

### Firebase not initializing:
- Ensure `flutterfire configure` completed successfully
- Check internet connection
- Verify Firebase project is active

### Camera not working:
- On Android: Check app permissions in Settings
- On iOS: Check Info.plist permissions

### Location not working:
- On Android: Check location permissions in Settings
- Test with real device (emulator may have issues)

### Images not uploading:
- Check Firebase Storage rules
- Verify internet connection
- Check Storage quota

## Production Deployment Checklist

- [ ] Replace demo API keys with production keys
- [ ] Update Firebase rules for production
- [ ] Set up custom claims using Cloud Functions
- [ ] Enable rate limiting and DDoS protection
- [ ] Configure Firebase security for production
- [ ] Set up backup and recovery procedures
- [ ] Test all three roles thoroughly
- [ ] Enable Firebase Analytics
- [ ] Set up error monitoring (Firebase Crashlytics)
