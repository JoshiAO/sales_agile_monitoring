# Architecture & Data Flow Guide

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                          Flutter App                            │
├─────────────────────────────────────────────────────────────────┤
│  UI Layer                                                        │
│  ├─ LoginScreen (shared)                                        │
│  ├─ SalesmanHomeScreen (Android)                                │
│  ├─ SupervisorDashboard (Desktop)                               │
│  └─ SuperUserDashboard (Desktop)                                │
├─────────────────────────────────────────────────────────────────┤
│  State Management (Provider)                                     │
│  ├─ AuthProvider (login, user, logout)                          │
│  └─ RouteProvider (routes, polylines)                           │
├─────────────────────────────────────────────────────────────────┤
│  Services Layer                                                  │
│  ├─ FirebaseService (init)                                      │
│  ├─ AuthService (Firebase Auth)                                 │
│  ├─ FirestoreService (database CRUD)                            │
│  ├─ StorageService (image uploads)                              │
│  ├─ LocationService (GPS)                                       │
│  └─ RoutingService (OpenRouteService API)                       │
├─────────────────────────────────────────────────────────────────┤
│  Data Models                                                     │
│  ├─ AppUser (uid, email, role, active, supervisorId)            │
│  ├─ SalesRoute (routeId, salesmanId, supervisorId, date)        │
│  └─ RoutePoint (lat, lon, imageUrl, timestamp)                  │
└─────────────────────────────────────────────────────────────────┘
        ↕         ↕          ↕           ↕
    ┌────────────────────────────────────────┐
    │      External Services/APIs            │
    ├────────────────────────────────────────┤
    │ Firebase (Auth, Firestore, Storage)    │
    │ OpenRouteService (Routing API)         │
    │ OpenStreetMap (Tiles)                  │
    │ Google Maps (Links)                    │
    └────────────────────────────────────────┘
```

## Data Flow Diagrams

### 1. Salesman Photo Capture Flow

```
User (Salesman) Takes Photo
        ↓
Image Picker (Camera)
        ↓
LocationService.getCurrentLocation()
        ↓
StorageService.uploadRouteImage()
        ↓
Firebase Storage ✓
        ↓
Create/Update SalesRoute in Firestore
        ↓
Route metadata saved with imageUrl
        ↓
UI updates with status ✓
```

### 2. Supervisor Route Viewing Flow

```
Supervisor Logs In
        ↓
AuthProvider.login()
        ↓
Firebase Auth ✓
        ↓
Load user from Firestore ✓
        ↓
Check: active == true ✓
        ↓
Navigate to SupervisorDashboard
        ↓
Select Date (date selector widget)
        ↓
RouteProvider.fetchRoutesByDate(supervisorId, date)
        ↓
Query Firestore routes collection ✓
        ↓
For each route: RoutingService.getRoute(first, last)
        ↓
OpenRouteService API ✓
        ↓
Generate polylines
        ↓
Render map with polylines & pins
        ↓
User clicks pin
        ↓
Fetch salesman details from Firestore ✓
        ↓
Show RouteDetailModal
        ↓
User sees images, GPS, timestamp, Google Maps link
```

### 3. User Management Flow (SuperUser)

```
SuperUser Logs In
        ↓
Navigate to UserManagementScreen
        ↓
Fetch all users from Firestore ✓
        ↓
Display users in list
        ↓
Click edit → Show dialog with options:
    ├─ Change role (salesman ↔ supervisor)
    ├─ Reassign supervisor
    └─ Toggle active status
        ↓
Update Firestore users collection ✓
        ↓
UI updates
```

## Authentication Flow

```
┌─────────────────┐
│   LoginScreen   │
└────────┬────────┘
         │ Email & Password
         ↓
┌──────────────────────┐
│  AuthProvider.login()│
└────────┬─────────────┘
         │
         ↓
┌──────────────────────────────────┐
│  AuthService.loginWithEmail()    │
└────────┬─────────────────────────┘
         │
         ↓
┌────────────────────────────────────┐
│  Firebase Auth.signInWithEmail()   │
└────────┬────────────────────────────┘
         │ Auth successful?
    ┌────┴────┐
    │Yes      │No
    ↓         ↓ Return error
┌──────────────────────────────────────┐
│ Fetch user doc from Firestore       │
│ (/users/{uid})                      │
└────────┬─────────────────────────────┘
         │
         ↓
┌──────────────────────────────┐
│ Check: active == true        │
└────────┬─────────────────────┘
    ┌────┴────┐
    │Yes      │No
    ↓         ↓ Sign out & error
┌──────────────────┐
│ Update AuthState │
└────────┬─────────┘
         │
         ↓
┌─────────────────────────────────┐
│ AppRouter selects screen by role│
└─────────────────────────────────┘
```

## Role-Based Access Control (RBAC)

```
┌──────────────────────────────────────────────────────────────────┐
│                      AppRouter Decision Tree                      │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  User Authenticated?                                              │
│  ├─ NO  → LoginScreen                                            │
│  └─ YES → Check User Role                                        │
│           ├─ SALESMAN      → SalesmanHomeScreen                  │
│           ├─ SUPERVISOR    → SupervisorDashboard                 │
│           └─ SUPERUSER     → SuperUserDashboard                  │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘

Firestore Security Rules
├─ Read:  IF authenticated                                          │
├─ Create: IF authenticated AND (self-create OR role==superuser)   │
├─ Update: IF authenticated AND (self-update OR role==superuser)   │
└─ Delete: IF role==superuser                                       │
```

## Database Schema

### Users Collection (`/users/{uid}`)
```
uid (document ID)
├─ email: string
├─ role: enum (salesman|supervisor|superuser)
├─ active: boolean
├─ supervisorId: string|null
├─ profilePic: string|null
└─ createdAt: timestamp
```

### Routes Collection (`/routes/{routeId}`)
```
routeId (document ID)
├─ salesmanId: string (foreign key to users)
├─ supervisorId: string (foreign key to users)
├─ date: string (yyyy-MM-dd)
├─ first:
│  ├─ lat: number
│  ├─ lon: number
│  ├─ imageUrl: string
│  └─ timestamp: datetime
├─ last:
│  ├─ lat: number
│  ├─ lon: number
│  ├─ imageUrl: string
│  └─ timestamp: datetime
├─ distance: number
└─ createdAt: timestamp
```

## Storage Structure

```
Firebase Storage Buckets
└─ gs://bucket-name/
   ├─ profile_pictures/
   │  └─ {userId}.jpg
   └─ route_images/
      └─ {salesmanId}/
         └─ {timestamp}.jpg
```

## State Management Flow

### AuthProvider State
```
Class: AuthProvider extends ChangeNotifier
├─ _currentUser: AppUser?
├─ _isLoading: bool
├─ _error: String?
├─
├─ Methods:
│  ├─ login(email, password) → validates & updates state
│  ├─ logout() → clears state
│  ├─ checkCurrentUser() → restores session
│  └─ clearError() → clears error message
└─
└─ Listeners: Widgets call notifyListeners() when changed
```

### RouteProvider State
```
Class: RouteProvider extends ChangeNotifier
├─ _routes: List<SalesRoute>
├─ _routePolylines: Map<routeId, List<LatLng>>
├─ _isLoading: bool
├─ _error: String?
├─
├─ Methods:
│  ├─ fetchRoutesByDate(supervisorId, date) → queries Firestore
│  ├─ fetchAllRoutesByDate(date) → global query
│  ├─ _generatePolylines() → calls OpenRouteService
│  └─ clear() → resets state
└─
└─ Listeners: Dashboard widgets rebuild when state changes
```

## API Integration Points

### 1. Firebase Authentication API
```
Method: FirebaseAuth.signInWithEmailAndPassword()
Request:
  - email: string
  - password: string
Response:
  - UserCredential (user + auth token)
Error Handling:
  - FirebaseAuthException caught & displayed
```

### 2. Firestore API
```
Methods Used:
  - collection('name').doc('id').get() → read
  - collection('name').doc('id').set() → create
  - collection('name').doc('id').update() → update
  - collection('name').where() → query
Error Handling:
  - FirebaseException caught & displayed
```

### 3. Firebase Storage API
```
Method: ref().putFile(file)
Request:
  - File to upload
  - Path: 'folder/filename'
Response:
  - Download URL
  - Upload task with progress
Error Handling:
  - FirebaseException caught
```

### 4. OpenRouteService API
```
Endpoint: /v2/directions/driving-car
Method: GET
Parameters:
  - api_key: string
  - start: "lon,lat"
  - end: "lon,lat"
Response:
  - GeoJSON with coordinates array
  - Features array containing geometry
Error Handling:
  - Returns empty list fallback
  - Logs error for debugging
```

## Key Design Patterns Used

### 1. Singleton Pattern
- FirebaseService
- AuthService
- FirestoreService
- StorageService
- LocationService
- RoutingService

### 2. Repository Pattern
- FirestoreService acts as data access layer
- Abstracts Firestore operations

### 3. Provider Pattern
- AuthProvider manages auth state
- RouteProvider manages route data
- Widgets rebuild on state changes

### 4. Factory Pattern
- AppRouter determines which screen to show based on role

### 5. Error Handling Pattern
- Try-catch in all async operations
- User-friendly error messages in SnackBars
- Console logging for debugging

## Performance Optimization Strategies

### 1. Image Optimization
- CachedNetworkImage caches downloaded images
- maxWidth/maxHeight for camera capture
- Quality: 85% for JPEG compression

### 2. Query Optimization
- Firestore queries filtered by supervisorId and date
- Lazy loading of salesman details
- Polyline caching in RouteProvider

### 3. Rate Limiting
- OpenRouteService: 2,000 requests/day (free tier)
- Firestore: 50k operations/day (free tier)
- Firebase Storage: 5GB/month (free tier)

### 4. Memory Management
- Proper cleanup in dispose()
- MapController.dispose()
- Provider auto-cleanup

## Security Considerations

### 1. Authentication
- Email/password via Firebase Auth
- Only active users allowed
- Automatic sign-out on error

### 2. Authorization
- Role-based access control (RBAC)
- Firestore rules check user role
- SuperUser elevated permissions

### 3. Data Privacy
- User location data stored encrypted
- Images in Firebase Storage
- User PII in Firestore

### 4. API Security
- OpenRouteService API key in constants
- HTTPS for all API calls
- Firebase security rules enforced

## Scaling Considerations

### Current Free Tier Limits
- Firebase Auth: Unlimited
- Firestore: 50k read/write/day
- Storage: 5GB/month
- OpenRouteService: 2,000 requests/day

### Optimization for Scale
1. Implement Cloud Functions for batch operations
2. Use Firestore indexes for complex queries
3. Implement caching strategy
4. Consider Realtime Database for live updates
5. Use CDN for images
6. Implement rate limiting

## Future Enhancement Points

1. **Real-time Updates**
   - Listen to Firestore changes
   - Live route tracking
   - Real-time notifications

2. **Advanced Features**
   - Geofencing
   - Route history & analytics
   - Performance metrics
   - Export functionality

3. **Scalability**
   - Cloud Functions
   - Firestore sharding
   - Data archival strategy

4. **User Experience**
   - Offline support
   - Background sync
   - Progressive loading
   - Animations & transitions

---

**Last Updated**: April 2026
