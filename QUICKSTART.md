# Quick Start Guide - Compact Sales Monitoring

Get the app running in 10 minutes!

## Prerequisites (5 minutes)
```bash
# 1. Ensure Flutter is installed
flutter --version  # Should be 3.11.4 or higher

# 2. Install FlutterFire CLI (one-time)
dart pub global activate flutterfire_cli

# 3. Get dependencies
flutter pub get
```

## Firebase Setup (3 minutes)
```bash
# Run FlutterFire configuration
flutterfire configure

# Select:
# ✓ Android
# ✓ iOS  
# ✓ macOS
# ✓ Windows
# Choose your Firebase project: "compact-sales-monitoring"
```

## Run the App (2 minutes)

### Android (Salesman App)
```bash
flutter run -t lib/main.dart
```

### Windows/macOS (Supervisor/SuperUser Apps)
```bash
# Windows
flutter run -d windows -t lib/main.dart

# macOS
flutter run -d macos -t lib/main.dart
```

## Login Credentials
```
Role: Salesman
Email: salesman@demo.com
Password: Demo@123

Role: Supervisor
Email: supervisor@demo.com
Password: Demo@123

Role: SuperUser
Email: superuser@demo.com
Password: Demo@123
```

## First Steps

### 1. Set up Firebase
1. Create project at https://console.firebase.google.com
2. Enable Authentication (Email/Password)
3. Create Firestore Database (Production mode)
4. Set up Storage
5. Add the demo users (see SETUP_CHECKLIST.md)

### 2. Configure API Key
1. Get key from https://openrouteservice.org
2. Update `lib/constants/app_constants.dart`:
   ```dart
   static const String openRouteServiceApiKey = 'YOUR_KEY_HERE';
   ```

### 3. Test the Features
- **Salesman**: Login → Take photos → Check Firestore/Storage
- **Supervisor**: Login → Select date → View routes on map
- **SuperUser**: Login → Manage users → Toggle activation

## Project Structure at a Glance

```
lib/
├── main.dart                          # Entry point
├── app_router.dart                    # Route by role
├── constants/app_constants.dart       # Config
├── models/                            # Data structures
├── services/                          # Firebase, Auth, GPS, Routing
├── providers/                         # State management
├── screens/                           # UI screens by role
└── widgets/                           # Reusable components
```

## Key Files to Know

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry & initialization |
| `lib/app_router.dart` | Role-based routing |
| `lib/services/firebase_service.dart` | Firebase setup |
| `lib/services/auth_service.dart` | Login logic |
| `lib/screens/salesman/salesman_home_screen.dart` | Salesman UI |
| `lib/screens/supervisor/supervisor_dashboard.dart` | Supervisor UI |
| `lib/screens/superuser/superuser_dashboard.dart` | SuperUser UI |
| `lib/constants/app_constants.dart` | API keys & constants |

## Common Tasks

### Update API Key
```dart
// lib/constants/app_constants.dart
static const String openRouteServiceApiKey = 'YOUR_NEW_KEY';
```

### Add New User
Use SuperUser app → "Manage Users" → "+" button

### Test Salesman Route Upload
1. Login as Salesman
2. Click "Take First Photo"
3. Click "Take Last Photo"
4. Check Firebase Console → Storage for images
5. Check Firebase Console → Firestore → routes collection

### View Routes on Supervisor Dashboard
1. Login as Supervisor
2. Routes appear on map automatically
3. Click map pins for details

## Helpful Commands

```bash
# Clean and rebuild
flutter clean && flutter pub get

# Check for issues
flutter analyze

# Format code
dart format lib/

# Run tests (once tests are added)
flutter test

# Build release APK
flutter build apk --release

# Build release iOS
flutter build ios --release
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Firebase not initializing | Run `flutterfire configure` again |
| Camera permission denied | Grant permission in device settings |
| Map not loading | Check internet & Firestore queries |
| Images not uploading | Verify Firebase Storage rules |
| API returns 401 | Check OpenRouteService API key |
| Routes not appearing | Verify Firestore has data for selected date |

## Next Steps

1. **Read Full Documentation**
   - [README.md](README.md) - Project overview
   - [FIREBASE_SETUP.md](FIREBASE_SETUP.md) - Detailed Firebase setup
   - [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Architecture & features

2. **Complete Setup Checklist**
   - [SETUP_CHECKLIST.md](SETUP_CHECKLIST.md) - Step-by-step checklist

3. **Customize the App**
   - Update app icons
   - Change colors in theme
   - Modify Firestore rules
   - Add additional features

4. **Deploy to Production**
   - Replace API keys
   - Update Firebase rules
   - Test thoroughly on real devices
   - Build release versions

## Support

- **Docs**: See README.md, FIREBASE_SETUP.md, IMPLEMENTATION_GUIDE.md
- **Issues**: Check SETUP_CHECKLIST.md troubleshooting section
- **Flutter Help**: https://flutter.dev/docs
- **Firebase Help**: https://firebase.google.com/docs

---

**Ready to code!** 🚀

Happy developing! 💻
