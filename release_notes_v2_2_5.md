# Release v2.2.5 - Stale Checkpoint Date Guard & Dismissible Logout Rejection

## Executive Summary
Version 2.2.5 addresses a critical data isolation issue where un-submitted location checkpoints from a previous day leaked into the current day's route, creating 100km V-shaped map distortion lines. It also improves the logout approval workflow by allowing salesmen to dismiss rejected logout status banners directly.

---

## 1. Issue: Stale Offline Checkpoint Leakage & Route Distortion

### Problem Statement
When a salesman ended their workday without tapping "Last Call", any pending offline checkpoints remained buffered in the phone's local storage (`SharedPreferences`). The following morning, upon taking "First Call", the mobile app flushed the offline queue. Because the queue contained un-submitted checkpoints from yesterday (e.g., 50km away in Alfonso Castañeda), these points were appended to today's route document (`date = 2026-09-04`). When sorted by timestamp time on the web dashboard, yesterday's location was inserted into today's sequence, producing massive V-shaped straight/road lines across mountain regions.

### Solution (4-Layer Defense Architecture)
1. **Mobile App Queue Purging (`BackgroundLocationService` & `SalesmanHomeScreen`)**:
   - Implemented `purgeStaleLocalCheckpoints()` to automatically delete offline-queued checkpoints from prior calendar dates before batch flushing.
   - Tagged queued items with `routeDate` and reset tracking window bases on new day start.
2. **Backend / Firestore Guard (`FirestoreService`)**:
   - In `appendRouteCheckpointsBatch()`, verified the target route document's `date` property (`YYYY-MM-DD`). Mismatching checkpoint dates are filtered before Firestore writes.
3. **Web Dashboard Model Sanitization (`SalesRoute`)**:
   - In `SalesRoute.fromMap()` and `sortedCheckpoints`, filtered out any checkpoint whose `timestamp` date does not match the route's target `date` string.
4. **Map Teleport Spike Filter (`RouteProvider`)**:
   - Added `_filterTeleportSpikes()` to automatically strip isolated V-shaped jumps (>25km away and back) from map polyline rendering.

---

## 2. Issue: Persistent Logout Rejection Message

### Problem Statement
When a superuser rejected a salesman's logout request, Firestore saved `logoutRequestStatus: 'rejected'`. Because this status persisted indefinitely in Firestore without a clearance mechanism, the red `Logout: Rejected` status pill remained stuck permanently on the top-left of the salesman's screen across app reloads.

### Solution
- **Dismissible Status Pill**: Updated the `Logout: Rejected` status pill with an interactive **✕** close button (`Logout: Rejected (Tap to Dismiss)`). Tapping it calls `FirestoreService.clearLogoutApproval()` to immediately remove the rejection status from Firestore and UI.
- **Actionable SnackBar**: Added an explicit **"Dismiss"** action to the rejection SnackBar notification.

---

## Technical Changes & Audit
- `lib/services/background_location_service.dart`: Added stale checkpoint purging, route date tags, and fixed type casting for telemetry fields.
- `lib/services/firestore_service.dart`: Added route date verification in batch append operations.
- `lib/models/route_model.dart`: Filtered mismatching checkpoint dates.
- `lib/providers/route_provider.dart`: Added `_filterTeleportSpikes()` in OSRM polyline generation.
- `lib/screens/salesman/salesman_tabs_screen.dart`: Interactive dismissible logout rejection pill and SnackBar action.
- `pubspec.yaml`: Bumped version to `2.2.5+17`.

---

### Deployment
- **Web Dashboard**: Published to [https://sales-agile-monitoring.web.app](https://sales-agile-monitoring.web.app)
