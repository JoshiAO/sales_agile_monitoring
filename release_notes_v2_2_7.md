# Release v2.2.7 - Call Upload Reliability, Next-Day Startup Fix & Free-Tier Batch Sync

## Executive Summary
Version 2.2.7 resolves two critical field issues reported by salesmen:
1. **Next-Day Dark Violet Screen Hang (`#1A1533`)**: Eliminates startup hangs on Day 2+ by synchronizing splash transition gates across `AuthProvider`, `CompanyBrandingProvider`, and `VersionProvider`, adding strict network timeouts on startup checks, fixing post-update `SharedPreferences` key preservation, and adding a self-service **"Repair & Sync App State"** recovery tool.
2. **Missing Call Records & Checkpoints in Firestore**: Replaces premature 3-second upload timeouts with realistic 25s Storage / 12s Firestore timeouts + automatic retry, guarantees verified Firestore writes on Last Call (with a **"Retry Upload"** modal that reuses the already-captured photo without retaking the selfie), prevents silent checkpoint loss before First Call syncs, and optimizes background checkpoint batch uploads to a **20-minute cadence** engineered to stay within 10%–20% of the Firebase Spark Free Tier for 50+ users.

---

## Key Features & Bug Fixes

### 1. Verified Call Upload Pipeline & Realistic Timeouts
- **Realistic Network Timeouts (`StorageService` & `SalesmanHomeScreen`)**: Increased Firebase Storage upload timeout from 3s to **25s** (with task cancellation and 2 automatic attempts) and Firestore route query/write timeouts from 3s to **12s**.
- **Guaranteed Last Call Commit**:
  - Automatically flushes any pending offline First Call (`pending_first_call_v2`) before committing Last Call.
  - Uses idempotent `SetOptions(merge: true)` + `FieldValue.arrayUnion` in `FirestoreService.createRoute` so route documents are safely created or merged even if First Call was still pending.
  - **Retry Without Retaking Photo**: If Last Call upload fails due to weak signal, the UI no longer falsely marks Last Call complete; instead, it keeps the gallery-saved photo and prompts **"Retry Upload"** so the salesman can retry immediately without retaking the selfie.

### 2. Checkpoint Preservation & Firebase Free-Tier Optimized 20-Minute Batching
- **No Silent Checkpoint Drops (`FirestoreService.appendRouteCheckpointsBatch`)**: Removed the early `if (!docSnap.exists) return;` no-op (which previously caused `BackgroundLocationService` to delete local checkpoints when `pending_first_call_v2` had not yet created the route document) and eliminated the extra `docRef.get()` read before every batch update.
- **20-Minute Smart Batch Interval (`BackgroundLocationService`)**:
  - Flushes queued checkpoints every **20 minutes** (~25 writes/user/day, keeping 50–100 salesmen within 7%–14% of Firebase's 20,000 free daily writes).
  - Performs throttled app-resume flushes (`>= 15m` since last flush, or immediately when `pending_first_call_v2` or failed batches are waiting) and guaranteed immediate flush upon Last Call.
  - Added cross-isolate mutex locking (`flush_lock_timestamp_ms`) and fixed the recursive `onStart()` timer multiplication bug in `resetWatchdog()`.

### 3. True HTTP 204 Internet Validator (`ConnectivityCheckService`)
- **Captive Portal & Zero-Balance SIM Detection**: Replaced DNS port-53 lookups (which pass even on zero-load mobile data promos) with a 2-layer check: fast OS interface verification followed by real HTTP `204 No Content` probes (`gstatic.com`, `clients3.google.com`, `cp.cloudflare.com`) with `followRedirects = false`.
- **Unified Pre-Call Check**: Eliminated redundant triple-checks before and after the connectivity dialog.

### 4. Next-Day Dark Violet Screen Fix & Self-Service Repair
- **Splash & Startup Timeout Guards**:
  - Added a 5s timeout to `VersionProvider.checkVersion()` and 6s/12s timeouts to `ActivationService`.
  - Synchronized `versionProvider.isChecking` across `MainAppHome`, `AuthWaveRevealLayer`, and `AppRouter`, backed by a 6.5s splash watchdog timer.
  - Added an `AssetImage('assets/images/JoshiAO.jpg')` fallback when offline cached company logos fail to decode.
- **Safe Post-Update & Stale-Session Cleanup**:
  - Fixed `cleanupAllTransientData()` to preserve actual activation keys (`company_code_activated`, `company_code_activation_lease_key`, `company_branding_*`, `device_uuid`) and removed the unsafe mid-runtime `FirebaseFirestore.instance.clearPersistence()` call.
  - Prior-day unuploaded calls/checkpoints (within 7 days) are flushed to their historical route before cleaning up local session state.
- **Self-Service "Repair & Sync App State"**: Added to `TroubleshootingScreen`, `SalesmanDebugScreen`, and `LaunchValidationLoadingScreen` (after 4s) so salesmen can sync pending data and reset stuck tracking state in one tap without needing IT to clear Android app data.

### 5. Top-Left Red "OFFLINE" Watermark, Live Tracker Timeline & Auto-Refresh Agile Tab
- **Offline Watermark**: Offline First Call photos are stamped with a top-left `"OFFLINE"` badge and synced automatically when connectivity returns.
- **Full Route Timeline in Live Tracker Dashboard (`SalesmanDebugScreen`)**: Displays the complete chronological timeline from **First Call → Checkpoint #1..#N → Last Call** (with First/Last Call coordinates preserved and uploaded/pending status badges).
- **Agile Tab Auto-Refresh**: Switching to the `Agile` tab automatically refreshes First/Last Call completion status.

---

## Technical Changes & Audit
- `lib/services/connectivity_check_service.dart`: Upgraded to HTTP `204 No Content` multi-endpoint validation.
- `lib/services/storage_service.dart`: 25s upload timeout, task cancellation on timeout, and 2-attempt retry.
- `lib/services/firestore_service.dart`: Idempotent `createRoute` with `SetOptions(merge: true)` and single-write `appendRouteCheckpointsBatch` with 12s timeout.
- `lib/services/background_location_service.dart`: 20-minute batch interval, throttled resume flush, cross-isolate flush lock, prior-day route recovery, fixed watchdog reset, `first_point_lat`/`first_point_lon` persistence, and `repairAndSyncAppState()`.
- `lib/screens/salesman/salesman_home_screen.dart`: Verified Last Call commit + Retry Upload modal, 12s Firestore timeouts, mid-day offline route state preservation, Live Tracker preference sync, and dynamic midnight rollover timer.
- `lib/providers/version_provider.dart`, `lib/services/activation_service.dart`, `lib/app_router.dart`, `lib/main.dart`, `lib/screens/launch_validation_loading_screen.dart`: Startup timeout guards and dark-violet screen hang prevention.
- `lib/screens/troubleshooting_screen.dart` & `lib/screens/salesman/salesman_debug_screen.dart`: Added self-service "Repair & Sync App State" button and full First Call → Last Call chronological checkpoint timeline.
- `lib/screens/salesman/salesman_tabs_screen.dart` & `lib/widgets/agile_call_form_card.dart`: Auto-refresh Agile call status on tab switch.
- `pubspec.yaml`: Version `2.2.7+19`.
