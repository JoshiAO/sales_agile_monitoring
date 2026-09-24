# Release v2.2.6 - Connectivity Guards, Stale Session Recovery & Auto-Update Protection

## Executive Summary
Version 2.2.6 introduces pre-call internet connection checks for First and Last Calls, prominent offline watermarking for First Call images, automated recovery from uncompleted prior-day Last Calls, pre-session cache sanitization, and session-aware auto-update protection.

---

## Key Features & Improvements

### 1. Connectivity Check & Retry Dialog (First Call & Last Call)
- **Dual Endpoint Verification (`ConnectivityCheckService`)**: Performs fast HTTP connection checks (`https://httpbin.org/get` with failover to `https://clients3.google.com/generate_204`).
- **Interactive Retry Modal**:
  - Prompts the salesman when offline with a **"Try Again"** button (up to 3 retries).
  - **First Call**: If 3 retries fail, unlocks a **"Proceed Offline"** mode allowing image capture and local storage.
  - **Last Call**: Internet connection is strictly required; Last Call cannot be submitted without an active internet connection.

### 2. Top-Left Red "OFFLINE" Watermark for First Call Images
- **Visual Stamping**: When First Call is captured offline, a red rectangular badge with bold white text `"OFFLINE"` is burned into the top-left corner (`0,0` to `240,48`) of the captured image alongside GPS & timestamp metadata.
- **Local Queuing**: Image and route data are persisted locally (`/call_images/`) and automatically uploaded once connectivity restores.

### 3. Stale Session Recovery (Uncompleted Last Call Guard)
- **App Freeze Fix**: Solves the app freezing/tangling bug caused when a salesman failed to complete Last Call on a previous day.
- **Automated Guard (`_guardAgainstStaleSession`)**: Runs during initialization. If active route tracking belongs to a prior calendar date, it stops the background location service and purges stale session data before loading today's route.
- **Service Self-Termination**: `BackgroundLocationService` checks route start dates and automatically self-terminates if started with a previous day's route.

### 4. First Call Cache Sanitization
- **Pre-Session Cleanup**: When First Call is initiated, previous session checkpoints, image buffers, and cached route states are safely wiped to maintain fresh session state.

### 5. Auto-Update Protection & Post-Update Data Cleanup
- **Session-Aware Deferral (`VersionProvider`)**: Automatically defers app auto-update popups during an active First Call → Last Call session, applying pending updates seamlessly after Last Call completes.
- **Post-Update Data Migration (`_runPostUpdateCleanup` in `main.dart`)**: Clears transient cache, obsolete images, and queued checkpoints upon version upgrade while preserving login credentials and activation tokens.

---

## Technical Changes & Audit
- `lib/services/connectivity_check_service.dart`: Created HTTP ping failover service.
- `lib/services/background_location_service.dart`: Added `cleanupStaleSession()` and date-based service self-termination.
- `lib/screens/salesman/salesman_home_screen.dart`: Integrated connectivity check dialog, offline watermark image stamping, and stale session recovery guard.
- `lib/providers/version_provider.dart`: Added active session status signals to defer app update popups mid-day.
- `lib/main.dart`: Added post-update cleanup migration upon version change.
- `pubspec.yaml`: Bumped version to `2.2.6+18`.
