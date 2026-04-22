# Sales Agile Monitoring

A comprehensive multi-role Flutter application for field sales monitoring with real-time GPS tracking, photo capture, and route visualization using Firebase and OpenStreetMap.

App branding:
- App name: Sales Agile Monitoring
- Launcher icon source: assets/images/JoshiAO.jpg

## 🚀 Features

### Multi-Platform & Multi-Role Architecture
- **Salesman (Android)**: Field sales representative mobile app
- **Supervisor (Desktop/Web)**: Team management dashboard  
- **Super User (Desktop/Web)**: Global administration & user management

### Key Capabilities

#### Salesman Features
- ✅ Firebase Authentication login
- ✅ Camera-based photo capture (first & last point)
- ✅ GPS coordinates with each photo
- ✅ Automatic upload to Firebase Storage
- ✅ Route metadata saved to Firestore
- ✅ Simple, intuitive UI with status tracking

#### Supervisor Features
- ✅ Interactive OpenStreetMap dashboard
- ✅ Date-based route filtering
- ✅ Road-aware polyline routing (OpenRouteService)
- ✅ Team route visualization
- ✅ Click pins to view detailed modal:
  - Raw captured images
  - Salesman information
  - Timestamp data
  - GPS coordinates with Google Maps links
  - Distance metrics

#### Super User Features
- ✅ Global route dashboard (all supervisors & teams)
- ✅ User activation/deactivation controls
- ✅ User management (create, edit, reassign)
- ✅ Role assignment (salesman ↔ supervisor)
- ✅ Supervisor hierarchy management
- ✅ Complete audit trail capabilities

## 🏗️ Architecture

### Technology Stack
- **Frontend**: Flutter (UI framework)
- **Backend**: Firebase (Auth, Firestore, Storage)
- **Mapping**: flutter_map + OpenStreetMap
- **Routing**: OpenRouteService API
- **State Management**: Provider
- **Location**: Geolocator
- **Camera**: Camera package
- **Storage**: Firebase Cloud Storage

### Project Structure
```
lib/
├── constants/          # App-wide constants and configurations
├── models/            # Data models (User, Route, RoutePoint)
├── services/          # Firebase, Auth, Location, Routing services
├── providers/         # State management (Auth, Routes)
├── screens/           # UI screens (Login, Salesman, Supervisor, SuperUser)
├── widgets/           # Reusable UI components
├── app_router.dart    # Role-based routing logic
└── main.dart          # App entry point
```

## 📱 Screen Layouts

### Login Screen
Simple email/password authentication with error handling and demo credentials display.

### Salesman Home Screen
```
┌─────────────────────────┐
│    Daily Route Tracker  │
│    2026-04-21           │
├─────────────────────────┤
│                         │
│  [First Photo Status]   │
│  [Last Photo Status]    │
│                         │
│  [Take First Photo]     │
│  [Take Last Photo]      │
│                         │
└─────────────────────────┘
```

### Supervisor/SuperUser Dashboard
```
┌──────────────────────────────┐
│ Dashboard     [Manage Users] │
├──────────────────────────────┤
│ [Date Selector Widget]       │
├──────────────────────────────┤
│                              │
│    [OpenStreetMap with]      │
│    [Routes & Pins]           │
│    [Click pin for details]   │
│                              │
└──────────────────────────────┘
```

## 🔐 Security & Permissions

### Firebase Security Rules
- User-level read access (authenticated users only)
- Role-based write permissions
- SuperUser elevated permissions for user management

### Android Permissions
- Camera access (photo capture)
- Location (fine & coarse)
- External storage (image cache)
- Internet (Firebase connectivity)

### iOS Permissions
- Camera usage description
- Location usage description

## 📊 Data Model

### Users Collection
```json
{
  "uid": "user-id-string",
  "email": "user@example.com",
  "role": "salesman|supervisor|superuser",
  "active": true,
  "supervisorId": "supervisor-uid|null",
  "profilePic": "storage-url|null",
  "createdAt": "timestamp"
}
```

### Routes Collection
```json
{
  "routeId": "uuid",
  "salesmanId": "user-id",
  "supervisorId": "user-id",
  "date": "2026-04-21",
  "first": {
    "lat": 15.485,
    "lon": 120.967,
    "imageUrl": "storage-url",
    "timestamp": "datetime"
  },
  "last": {
    "lat": 15.495,
    "lon": 120.977,
    "imageUrl": "storage-url",
    "timestamp": "datetime"
  },
  "distance": 2.3,
  "createdAt": "timestamp"
}
```

## ⚙️ Configuration

### Firebase Setup
See [FIREBASE_SETUP.md](FIREBASE_SETUP.md) for detailed setup instructions including:
- Project creation
- Authentication configuration
- Firestore rules
- Storage configuration
- API key setup

### OpenRouteService API
1. Create account: https://openrouteservice.org
2. Get API key (2,000 free requests/day)
3. Update `lib/constants/app_constants.dart`:
```dart
static const String openRouteServiceApiKey = 'YOUR_API_KEY_HERE';
```

## 🚀 Getting Started

### Prerequisites
```bash
flutter --version  # Ensure Flutter 3.11+
dart pub global activate flutterfire_cli
```

### Installation
```bash
# Clone the repository
git clone <repository-url>
cd compact_sales_monitoring

# Install dependencies
flutter pub get

# Configure Firebase
flutterfire configure
```

### Running the App

#### Android (Salesman)
```bash
flutter run -t lib/main.dart
```

#### Desktop (Supervisor/SuperUser)
```bash
# Windows
flutter run -d windows -t lib/main.dart

# macOS
flutter run -d macos -t lib/main.dart
```

#### iOS (Optional)
```bash
flutter run -d ios -t lib/main.dart
```

## 🧪 Testing

### Test Accounts
```
Email: salesman@demo.com
Password: Demo@123
Role: Salesman

Email: supervisor@demo.com
Password: Demo@123
Role: Supervisor

Email: superuser@demo.com
Password: Demo@123
Role: SuperUser
```

### Test Scenarios
1. **Salesman Flow**: Login → Capture photos → Verify Firestore upload
2. **Supervisor Flow**: Login → Select date → View routes on map → Click pins
3. **SuperUser Flow**: Login → View all routes → Manage users → Toggle activation

## 📈 Performance Optimization

### Data Optimization
- **Single entry per day**: Only first/last GPS/photo logged per salesman per day
- **Lazy loading**: User details loaded on-demand
- **Image caching**: CachedNetworkImage for efficient loading
- **Polyline caching**: RouteProvider caches road-aware polylines

### Free Tier Usage
- Firebase Storage: 5GB free ✓
- Firestore: 50k reads/writes/day ✓
- OpenRouteService: 2,000 requests/day ✓

## 🔄 State Management

### AuthProvider
- Manages authentication state
- Tracks current user and role
- Handles login/logout operations

### RouteProvider
- Fetches and caches routes
- Generates polylines on-demand
- Handles date-based filtering

## 🐛 Troubleshooting

### Common Issues
- **Firebase initialization fails**: Run `flutterfire configure`
- **Camera permission denied**: Check Android/iOS settings
- **No routes displayed**: Verify Firestore has data and date matches
- **Images not loading**: Check Firebase Storage rules and connectivity

See [FIREBASE_SETUP.md](FIREBASE_SETUP.md) for detailed troubleshooting.

## 📖 Documentation

- [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Detailed implementation guide
- [FIREBASE_SETUP.md](FIREBASE_SETUP.md) - Firebase configuration steps

## 🚀 Future Enhancements

- [ ] Cloud Functions for custom claims
- [ ] Real-time Firestore listeners
- [ ] Push notifications
- [ ] Performance analytics dashboard
- [ ] Export routes (PDF/CSV)
- [ ] Offline mode with sync
- [ ] Video recording capability
- [ ] Profile picture uploads
- [ ] Advanced filtering & search
- [ ] Geofencing for automatic check-in/out

## 🛡️ Production Deployment

Before deploying to production:
- [ ] Replace demo API keys
- [ ] Update Firebase security rules
- [ ] Set up Cloud Functions for custom claims
- [ ] Enable Firebase monitoring
- [ ] Configure backup strategies
- [ ] Test all three user roles thoroughly
- [ ] Implement analytics tracking
- [ ] Set up error monitoring (Crashlytics)

## 📝 License

This project is provided as-is for demonstration and development purposes.

## 🤝 Support

For issues, questions, or contributions, please refer to the documentation files or contact the development team.

---

**Last Updated**: April 2026  
**Flutter Version**: 3.11.4+  
**Dart Version**: 3.11.4+

