# Sales Monitoring App - Implementation Guide

## Project Overview
A multi-platform Flutter application with role-based access control using Firebase:
- **Salesman (Android)**: Capture first/last photo with GPS
- **Supervisor (Desktop)**: View team routes on map
- **SuperUser (Desktop)**: Global view + user management

## Project Structure

```
lib/
├── constants/
│   └── app_constants.dart          # App-wide constants
├── models/
│   ├── user_model.dart             # User data model
│   └── route_model.dart            # Route & RoutePoint models
├── services/
│   ├── firebase_service.dart       # Firebase initialization
│   ├── auth_service.dart           # Authentication logic
│   ├── firestore_service.dart      # Firestore operations
│   ├── storage_service.dart        # Firebase Storage operations
│   ├── routing_service.dart        # OpenRouteService API
│   └── location_service.dart       # GPS location retrieval
├── providers/
│   ├── auth_provider.dart          # Authentication state
│   └── route_provider.dart         # Routes & polylines state
├── screens/
│   ├── login_screen.dart           # Login UI
│   ├── salesman/
│   │   └── salesman_home_screen.dart
│   ├── supervisor/
│   │   └── supervisor_dashboard.dart
│   └── superuser/
│       ├── superuser_dashboard.dart
│       └── user_management_screen.dart
├── widgets/
│   ├── date_selector_widget.dart   # Date picker
│   └── route_detail_modal.dart     # Route details modal
├── app_router.dart                 # Role-based routing
└── main.dart                       # App entry point
```

## Key Features

### 1. Authentication
- Email/password login via Firebase Auth
- Only active users can log in
- Role-based access control (salesman, supervisor, superuser)

### 2. Salesman Features
- Two simple buttons: "Take First Photo" and "Take Last Photo"
- Camera integration using `camera` package
- GPS capture using `geolocator`
- Auto-upload to Firebase Storage
- Metadata saved to Firestore

### 3. Supervisor Features
- Dashboard with OpenStreetMap tiles
- Date filtering for routes
- Fetch team's routes from Firestore
- Road-aware polylines from OpenRouteService API
- Click pins to see:
  - Raw image
  - Salesman details
  - Date/time
  - GPS coordinates
  - Google Maps link

### 4. SuperUser Features
- Global dashboard (all routes)
- User management (add, edit, activate/deactivate)
- Role changes (salesman ↔ supervisor)
- Supervisor reassignment

## Data Model

### Users Collection
```json
{
  "uid": "user-id",
  "email": "user@example.com",
  "role": "salesman|supervisor|superuser",
  "active": true,
  "supervisorId": "supervisor-id|null",
  "profilePic": "storage-url|null",
  "createdAt": timestamp
}
```

### Routes Collection
```json
{
  "routeId": "route-id",
  "salesmanId": "user-id",
  "supervisorId": "user-id",
  "date": "yyyy-MM-dd",
  "first": {
    "lat": 15.485,
    "lon": 120.967,
    "imageUrl": "storage-url",
    "timestamp": datetime
  },
  "last": {
    "lat": 15.495,
    "lon": 120.977,
    "imageUrl": "storage-url",
    "timestamp": datetime
  },
  "distance": 2.3,
  "createdAt": timestamp
}
```

## Firebase Configuration

See `FIREBASE_SETUP.md` for detailed setup instructions.

## Dependencies

Key packages used:
- `firebase_core`: Firebase initialization
- `firebase_auth`: Authentication
- `cloud_firestore`: Database
- `firebase_storage`: Image storage
- `flutter_map`: Map display
- `camera`: Photo capture
- `geolocator`: GPS location
- `provider`: State management
- `dio`: HTTP requests
- `cached_network_image`: Image caching
- `image_picker`: Image selection
- `intl`: Date formatting

## Running the App

### Prerequisites
```bash
flutter pub get
flutterfire configure  # Configure Firebase for platforms
```

### Android (Salesman)
```bash
flutter run -t lib/main.dart
```

### Desktop (Supervisor/SuperUser)
```bash
# Windows
flutter run -d windows -t lib/main.dart

# macOS
flutter run -d macos -t lib/main.dart
```

### iOS (Optional)
```bash
flutter run -d ios -t lib/main.dart
```

## API Integration

### OpenRouteService
Used for road-aware routing between first and last GPS points.
- **Free Tier**: 2,000 requests/day
- **API Key**: https://openrouteservice.org
- **Endpoint**: `https://api.openrouteservice.org/v2/directions/driving-car`

Update in `lib/constants/app_constants.dart`:
```dart
static const String openRouteServiceApiKey = 'YOUR_KEY_HERE';
```

## State Management

### AuthProvider
- Manages login/logout
- Stores current user
- Tracks loading and error states

### RouteProvider
- Fetches routes by date
- Generates polylines
- Caches route data

## Error Handling

- Try-catch blocks in all async operations
- User-friendly error messages in SnackBars
- Logging to console for debugging

## Performance Optimization

- **Image Caching**: CachedNetworkImage for efficient loading
- **Firestore Queries**: Filtered by supervisorId and date
- **Polyline Caching**: RouteProvider caches polylines
- **Lazy Loading**: User details loaded on demand

## Free Tier Optimization

- ✓ Only first/last GPS per salesman per day
- ✓ Images stored in Firebase Storage (5GB free)
- ✓ Firestore: ~50k reads/writes/day free
- ✓ OpenRouteService: 2,000 requests/day free

## Future Enhancements

1. **Cloud Functions**: Set custom claims for better security
2. **Real-time Updates**: Listen to Firestore changes
3. **Notifications**: Push notifications for new routes
4. **Analytics**: Track salesman performance
5. **Export**: Export routes as PDF/CSV
6. **Offline Support**: Cache routes for offline access
7. **Video Recording**: Record route in addition to photos
8. **Profile Pictures**: Allow users to upload profile pictures

## Testing

### Test Accounts
- **Salesman**: salesman@demo.com / Demo@123
- **Supervisor**: supervisor@demo.com / Demo@123
- **SuperUser**: superuser@demo.com / Demo@123

### Test Flow
1. Login as each role
2. Salesman: Test photo capture and upload
3. Supervisor: Test route viewing and modals
4. SuperUser: Test user management and global view

## Support & Troubleshooting

See `FIREBASE_SETUP.md` for common issues and solutions.

## License
This project is provided as-is for demonstration and development purposes.
