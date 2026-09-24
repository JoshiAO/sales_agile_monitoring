import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:compact_sales_monitoring/services/firebase_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:intl/intl.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

@pragma('vm:entry-point')
class BackgroundLocationService {
  static const int _checkpointMinIntervalMinutes = 1; // Strict 1-minute checkpoints
  static const int _batchUploadIntervalMinutes = 30; // Upload batches every 30 minutes
  static const double _maxCheckpointAccuracyMeters = 250.0;

  static Future<void> initializeService() async {
    if (kIsWeb) return;
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        initialNotificationTitle: '📍 Route Tracker Active',
        initialNotificationContent: 'Live tracking was on after first call, ended after last call.',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  static Future<void> startTracking(String routeId, RoutePoint firstPoint) async {
    if (kIsWeb) return;
    final service = FlutterBackgroundService();
    final prefs = await SharedPreferences.getInstance();
    
    // Unconditionally ensure any leftover end time is wiped when tracking starts/resumes
    await prefs.remove('route_end_time');
    
    final previousRouteId = prefs.getString('active_route_id');
    final previousFirstPointTime = prefs.getString('first_point_time');
    final currentFirstPointTime = firstPoint.timestamp.toIso8601String();
    final todayDateStr = DateFormat('yyyy-MM-dd').format(firstPoint.timestamp);

    final lastCpTimeStr = prefs.getString('last_checkpoint_time');
    bool isNewDay = false;
    if (lastCpTimeStr != null) {
      try {
        final lastCpTime = DateTime.parse(lastCpTimeStr);
        final lastCpDateStr = DateFormat('yyyy-MM-dd').format(lastCpTime);
        if (lastCpDateStr != todayDateStr) {
          isNewDay = true;
        }
      } catch (_) {}
    }

    if (previousRouteId != routeId || previousFirstPointTime != currentFirstPointTime || isNewDay) {
      await prefs.setString('active_route_id', routeId);
      await prefs.setString('first_point_time', currentFirstPointTime);
      
      // Set initial checkpoint base
      await prefs.setString('route_start_time', currentFirstPointTime);
      
      await prefs.setString('last_checkpoint_time', currentFirstPointTime);
      await prefs.setDouble('last_checkpoint_lat', firstPoint.lat);
      await prefs.setDouble('last_checkpoint_lon', firstPoint.lon);
      await prefs.setInt('checkpoint_count', 0);
      await prefs.remove('session_checkpoints_history');

      // Purge any stale local batch checkpoints from prior dates
      await purgeStaleLocalCheckpoints(prefs, todayDateStr);
    }

    await service.startService();
  }

  static Future<void> stopTracking() async {
    if (kIsWeb) return;
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke('stopService');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('route_end_time', DateTime.now().toIso8601String());
    await prefs.remove('active_route_id');
  }

  @pragma('vm:entry-point')
  static void notificationTapBackground(NotificationResponse notificationResponse) {
    if (notificationResponse.actionId == 'manual_checkpoint') {
      FlutterBackgroundService().invoke('manual_checkpoint');
    }
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    WidgetsFlutterBinding.ensureInitialized();
    
    await FirebaseService.initializeApp();
    final firestoreService = FirestoreService();
    final prefs = await SharedPreferences.getInstance();

    final activeRouteId = prefs.getString('active_route_id');
    if (activeRouteId == null) {
      service.stopSelf();
      return;
    }

    // DATE GUARD: Self-terminate if the active route belongs to a previous day.
    // This prevents the background service from accumulating stale checkpoints
    // when a salesman never completed Last Call on a prior session.
    final routeStartStr = prefs.getString('route_start_time');
    if (routeStartStr != null) {
      try {
        final routeStartDate = DateTime.parse(routeStartStr);
        final startDateStr = DateFormat('yyyy-MM-dd').format(routeStartDate);
        final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
        if (startDateStr != todayStr) {
          debugPrint(
            '[BackgroundLocationService] Stale route from $startDateStr detected on $todayStr. Self-terminating.',
          );
          await prefs.remove('active_route_id');
          service.stopSelf();
          return;
        }
      } catch (_) {
        // Unparseable date → corrupted state → stop for safety.
        debugPrint('[BackgroundLocationService] Unparseable route_start_time. Self-terminating.');
        await prefs.remove('active_route_id');
        service.stopSelf();
        return;
      }
    }

    StreamSubscription<geo.Position>? locationSubscription;
    Timer? streamWatchdog;
    Timer? periodicFlushTimer;

    service.on('stopService').listen((event) {
      locationSubscription?.cancel();
      streamWatchdog?.cancel();
      periodicFlushTimer?.cancel();
      WakelockPlus.disable();
      service.stopSelf();
    });
    
    // GUARANTEE CPU DOES NOT SLEEP
    WakelockPlus.enable();

    // INITIALIZE HIGH-PRIORITY ALARMS
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await flutterLocalNotificationsPlugin.initialize(
      settings: initSettings,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    await flutterLocalNotificationsPlugin.show(
      id: 888,
      title: '📍 Route Tracker Active',
      body: 'Live tracking was on after first call, ended after last call.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'compact_sales_tracker_channel',
          'Live Tracking Service',
          ongoing: true,
          importance: Importance.low,
          priority: Priority.low,
          actions: [
            AndroidNotificationAction(
              'manual_checkpoint',
              'Capture Checkpoint',
              showsUserInterface: false,
            ),
          ],
        ),
      ),
    );

    final stream = geo.Geolocator.getPositionStream(
      locationSettings: geo.AndroidSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 0, // Unconditional periodic wakeups; software filtering handles 500m logic
        intervalDuration: const Duration(seconds: 20),
        forceLocationManager: false,
      ),
    );

    int processLocationCount = 0;

    // Declare as late so getBestAvailablePosition and resetWatchdog can reference it
    // before the body is assigned below.
    late Future<void> Function(geo.Position, [bool isManual]) processLocation;

    // Helper: get best available position. Falls back to last-known on timeout.
    // KEY FIX FOR INDOOR GPS: high-accuracy GPS times out indoors, but
    // last-known position (from Wi-Fi/Cell towers) returns instantly.
    Future<geo.Position?> getBestAvailablePosition() async {
      try {
        return await geo.Geolocator.getCurrentPosition(
          desiredAccuracy: geo.LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {
        debugPrint('[BackgroundLocationService] GPS timeout. Falling back to last known position...');
        try {
          return await geo.Geolocator.getLastKnownPosition();
        } catch (_) {
          return null;
        }
      }
    }

    void resetWatchdog() {
      streamWatchdog?.cancel();
      streamWatchdog = Timer(const Duration(minutes: 2), () async {
        debugPrint('[BackgroundLocationService] GPS stream silent for 2 mins. Forcing restart...');
        final pos = await getBestAvailablePosition();
        if (pos != null) {
          await processLocation(pos);
        } else {
          onStart(service); // Re-initialize the service loop if no position at all
        }
      });
    }

    // Assign body now — all helpers above are already in scope.
    processLocation = (geo.Position position, [bool isManual = false]) async {
      resetWatchdog();
      processLocationCount++;

      // Reduce SharedPreferences disk reads
      if (processLocationCount == 1 || processLocationCount % 5 == 0) {
        await prefs.reload();
      }
      final routeId = prefs.getString('active_route_id');
      if (routeId == null) {
        service.stopSelf();
        return;
      }

      final now = DateTime.now();

      final lastTimeStr = prefs.getString('last_checkpoint_time');

      final lastTime = lastTimeStr != null ? DateTime.parse(lastTimeStr) : null;

      final timeSinceLast = lastTime == null
          ? Duration(minutes: _checkpointMinIntervalMinutes)
          : now.difference(lastTime);

      final timeThresholdMet = timeSinceLast.inSeconds >= 60;

      // Strict 1-minute interval requirement unless triggered manually
      if (!timeThresholdMet && !isManual) return;

      // If we are capturing based ONLY on distance, we demand high accuracy to prevent fake jumps.
      // However, if the 30-minute timer triggered OR the user manually requested a checkpoint, 
      // we accept whatever location we can get (even low-accuracy Cell/Wi-Fi positions).
      if (!timeThresholdMet && !isManual && position.accuracy > _maxCheckpointAccuracyMeters) {
        return;
      }

      // Update base
      await prefs.setString('last_checkpoint_time', now.toIso8601String());
      await prefs.setDouble('last_checkpoint_lat', position.latitude);
      await prefs.setDouble('last_checkpoint_lon', position.longitude);

      final currentCount = prefs.getInt('checkpoint_count') ?? 0;
      await prefs.setInt('checkpoint_count', currentCount + 1);

      int? batteryLevel;
      bool? isMobileDataOn;
      bool? isWifiOn;
      
      try {
        batteryLevel = await Battery().batteryLevel;
      } catch (_) {}
      
      try {
        final connectivityResult = await Connectivity().checkConnectivity();
        isMobileDataOn = connectivityResult.contains(ConnectivityResult.mobile);
        isWifiOn = connectivityResult.contains(ConnectivityResult.wifi);
      } catch (_) {}

      final checkpoint = RouteCheckpoint(
        lat: position.latitude,
        lon: position.longitude,
        timestamp: now,
        batteryLevel: batteryLevel,
        isMobileDataOn: isMobileDataOn,
        isWifiOn: isWifiOn,
      );

      // OFFLINE FIRST: Accumulate locally, do not upload directly here.
      await _persistToLocalBatch(prefs, routeId, checkpoint);

      // Upload if 30 minutes have passed since last flush, OR if it's a manual checkpoint.
      final lastFlushStr = prefs.getString('last_flush_time');
      final lastFlush = lastFlushStr != null ? DateTime.parse(lastFlushStr) : null;
      if (isManual || lastFlush == null || now.difference(lastFlush).inMinutes >= _batchUploadIntervalMinutes) {
        await flushPendingBatch(prefs, firestoreService);
      }
    };

    // 1. Process locations when the user moves (stream-based)

    void subscribeToLocation() {
      locationSubscription?.cancel();
      locationSubscription = stream.listen(
        (pos) => processLocation(pos),
        onError: (Object e) {
          debugPrint('[BackgroundLocationService] Stream error: $e');
          Future.delayed(const Duration(seconds: 10), subscribeToLocation);
        },
        onDone: () {
          debugPrint('[BackgroundLocationService] Stream done. Re-subscribing...');
          Future.delayed(const Duration(seconds: 5), subscribeToLocation);
        },
      );
    }

    subscribeToLocation();
    resetWatchdog();

    // 1.5. Initial 3-minute check to guarantee an early checkpoint
    Timer(const Duration(minutes: 3), () async {
      final pos = await getBestAvailablePosition();
      if (pos != null) await processLocation(pos);
    });

    // 2. Force a location check every 1 minute for stationary users.
    // getBestAvailablePosition() will NOT fail indoors — it falls back to last known.
    periodicFlushTimer?.cancel();
    periodicFlushTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
      await prefs.reload();
      if (prefs.getString('active_route_id') == null) {
        timer.cancel();
        return;
      }
      final pos = await getBestAvailablePosition();
      if (pos != null) await processLocation(pos);

      // Flush any accumulated batch if the 30 min timer is up
      final lastFlushStr = prefs.getString('last_flush_time');
      final lastFlush = lastFlushStr != null ? DateTime.parse(lastFlushStr) : null;
      if (lastFlush == null || DateTime.now().difference(lastFlush).inMinutes >= _batchUploadIntervalMinutes) {
        await flushPendingBatch(prefs, firestoreService);
      }
    });

    service.on('manual_checkpoint').listen((_) async {
      debugPrint('[BackgroundLocationService] Manual checkpoint triggered!');
      final pos = await getBestAvailablePosition();
      if (pos != null) {
        await processLocation(pos, true);
      }
      await flushPendingBatch(prefs, firestoreService);
    });
  }
  
  static const String _batchPrefsKey = 'batched_checkpoints_v2';

  static Future<void> purgeStaleLocalCheckpoints([
    SharedPreferences? providedPrefs,
    String? targetDate,
  ]) async {
    final prefs = providedPrefs ?? await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getStringList(_batchPrefsKey) ?? [];
    if (raw.isEmpty) return;

    final todayStr = targetDate ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
    final validRaw = <String>[];

    for (final entryStr in raw) {
      try {
        final map = jsonDecode(entryStr) as Map<String, dynamic>;
        final tsMs = map['timestamp'] as int?;
        if (tsMs != null) {
          final cpDate = DateTime.fromMillisecondsSinceEpoch(tsMs);
          final cpDateStr = DateFormat('yyyy-MM-dd').format(cpDate);
          if (cpDateStr == todayStr) {
            validRaw.add(entryStr);
          } else {
            debugPrint(
              '[BackgroundLocationService] Purging stale offline checkpoint from $cpDateStr (target today: $todayStr)',
            );
          }
        }
      } catch (_) {}
    }

    if (validRaw.length != raw.length) {
      await prefs.setStringList(_batchPrefsKey, validRaw);
      await prefs.setInt('batch_pending_count', validRaw.length);
    }
  }

  static Future<void> _persistToLocalBatch(SharedPreferences prefs, String routeId, RouteCheckpoint cp) async {
    final raw = prefs.getStringList(_batchPrefsKey) ?? [];
    final routeDateStr = DateFormat('yyyy-MM-dd').format(cp.timestamp);
    final jsonMap = {
      'routeId': routeId,
      'routeDate': routeDateStr,
      'lat': cp.lat,
      'lon': cp.lon,
      'timestamp': cp.timestamp.millisecondsSinceEpoch,
    };
    if (cp.batteryLevel != null) jsonMap['batteryLevel'] = cp.batteryLevel!;
    if (cp.isMobileDataOn != null) jsonMap['isMobileDataOn'] = cp.isMobileDataOn!;
    if (cp.isWifiOn != null) jsonMap['isWifiOn'] = cp.isWifiOn!;

    final jsonStr = jsonEncode(jsonMap);
    raw.add(jsonStr);
    await prefs.setStringList(_batchPrefsKey, raw);
    await prefs.setInt('batch_pending_count', raw.length);
    
    final history = prefs.getStringList('session_checkpoints_history') ?? [];
    history.add(jsonStr);
    await prefs.setStringList('session_checkpoints_history', history);
  }

  static Future<bool> flushPendingFirstCall([
    SharedPreferences? providedPrefs,
    FirestoreService? providedFs,
    StorageService? providedStorage,
  ]) async {
    final prefs = providedPrefs ?? await SharedPreferences.getInstance();
    await prefs.reload();
    final rawJson = prefs.getString('pending_first_call_v2');
    if (rawJson == null || rawJson.isEmpty) return false;

    final fs = providedFs ?? FirestoreService();
    final storage = providedStorage ?? StorageService();

    try {
      final map = jsonDecode(rawJson) as Map<String, dynamic>;
      final localPath = map['localImagePath'] as String?;
      if (localPath == null || !File(localPath).existsSync()) {
        await prefs.remove('pending_first_call_v2');
        return false;
      }

      final salesmanId = map['salesmanId'] as String;
      final timestamp = map['timestamp'] as String;
      final imageFile = File(localPath);

      final imageUrl = await storage.uploadRouteImage(
        imageFile,
        salesmanId,
        timestamp,
      );

      final locationTime = DateTime.fromMillisecondsSinceEpoch(
        map['locationTime'] as int,
      );

      final routePoint = RoutePoint(
        lat: (map['lat'] as num).toDouble(),
        lon: (map['lon'] as num).toDouble(),
        imageUrl: imageUrl,
        timestamp: locationTime,
        productName: map['productName'] as String?,
        modelName: map['modelName'] as String?,
        serialNumber: map['serialNumber'] as String?,
        uuid: map['uuid'] as String?,
        batteryLevel: map['batteryLevel'] as int?,
        appVersion: map['appVersion'] as String?,
        mobileDataUsage: (map['mobileDataUsage'] as List<dynamic>?)
            ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
            .toList(),
        wifiDataUsage: (map['wifiDataUsage'] as List<dynamic>?)
            ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
            .toList(),
      );

      final routeId = map['routeId'] as String;
      final supervisorId = map['supervisorId'] as String;
      final date = map['date'] as String;
      final companyId = map['companyId'] as String?;

      await fs.createRoute(
        salesmanId: salesmanId,
        supervisorId: supervisorId,
        date: date,
        first: routePoint,
        last: routePoint,
        hasFirstCall: true,
        hasLastCall: false,
        companyId: companyId,
        customRouteId: routeId,
      );

      await prefs.remove('pending_first_call_v2');
      return true;
    } catch (e) {
      debugPrint('[BackgroundLocationService] Failed to flush pending first call: $e');
      return false;
    }
  }

  static Future<void> flushPendingBatch([SharedPreferences? providedPrefs, FirestoreService? providedFs]) async {
    final prefs = providedPrefs ?? await SharedPreferences.getInstance();
    final fs = providedFs ?? FirestoreService();
    
    await prefs.reload();
    await purgeStaleLocalCheckpoints(prefs);
    await flushPendingFirstCall(prefs, fs);

    final raw = prefs.getStringList(_batchPrefsKey) ?? [];
    if (raw.isEmpty) return;

    final Map<String, List<RouteCheckpoint>> checkpointsByRoute = {};
    final Map<String, List<String>> rawStringsByRoute = {};
    final List<String> remainingRaw = [];
    final todayDateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    for (final entryStr in raw) {
      try {
        final map = jsonDecode(entryStr) as Map<String, dynamic>;
        final ts = DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int);
        final cpDateStr = DateFormat('yyyy-MM-dd').format(ts);

        // Extra safeguard: discard mismatching dates from batch flush
        if (cpDateStr != todayDateStr) {
          debugPrint('[BackgroundLocationService] Discarding stale checkpoint during flush: $cpDateStr (today: $todayDateStr)');
          continue;
        }

        final routeId = map['routeId'] as String;
        final cp = RouteCheckpoint(
          lat: (map['lat'] as num).toDouble(),
          lon: (map['lon'] as num).toDouble(),
          timestamp: ts,
          batteryLevel: map['batteryLevel'] as int?,
          isMobileDataOn: map['isMobileDataOn'] as bool?,
          isWifiOn: map['isWifiOn'] as bool?,
        );
        checkpointsByRoute.putIfAbsent(routeId, () => []).add(cp);
        rawStringsByRoute.putIfAbsent(routeId, () => []).add(entryStr);
      } catch (_) {}
    }

    bool flushOccurred = false;
    for (final entry in checkpointsByRoute.entries) {
      final routeId = entry.key;
      try {
        await fs.appendRouteCheckpointsBatch(routeId, entry.value);
        flushOccurred = true;
      } catch (e) {
        debugPrint('[BackgroundLocationService] Batch flush failed for route $routeId: $e');
        // Only keep the checkpoints for routes that failed to upload
        remainingRaw.addAll(rawStringsByRoute[routeId]!);
      }
    }

    // Only update SharedPreferences if something actually succeeded or changed
    if (remainingRaw.length != raw.length) {
      if (remainingRaw.isEmpty) {
        await prefs.remove(_batchPrefsKey);
        await prefs.setInt('batch_pending_count', 0);
      } else {
        await prefs.setStringList(_batchPrefsKey, remainingRaw);
        await prefs.setInt('batch_pending_count', remainingRaw.length);
      }
    }

    if (flushOccurred) {
      await prefs.setString('last_flush_time', DateTime.now().toIso8601String());
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Session & Data Cleanup
  // ─────────────────────────────────────────────────────────────────────────

  /// Cleans all transient tracking keys from a previous or stale session.
  ///
  /// Called at:
  ///   - The start of every First Call (new session begins)
  ///   - Date mismatch detected in _loadTodayRoute()
  ///   - Midnight rollover
  ///   - Stale session detected on app launch
  ///
  /// Never touches: auth, activation, or migration flags.
  static Future<void> cleanupStaleSession(String todayDate) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Discard pending_first_call_v2 if it belongs to a different date.
    final rawPending = prefs.getString('pending_first_call_v2');
    if (rawPending != null && rawPending.isNotEmpty) {
      try {
        final map = jsonDecode(rawPending) as Map<String, dynamic>;
        if (map['date'] != todayDate) {
          debugPrint('[BackgroundLocationService] Removing stale pending_first_call_v2 (date: ${map['date']} ≠ $todayDate)');
          await prefs.remove('pending_first_call_v2');
        }
      } catch (_) {
        // Corrupted JSON → remove unconditionally.
        debugPrint('[BackgroundLocationService] Removing corrupted pending_first_call_v2.');
        await prefs.remove('pending_first_call_v2');
      }
    }

    // Clear all tracking state keys.
    const trackingKeys = [
      'active_route_id',
      'last_checkpoint_time',
      'last_checkpoint_lat',
      'last_checkpoint_lon',
      'checkpoint_count',
      'session_checkpoints_history',
      'route_start_time',
      'route_end_time',
      'first_point_time',
      'last_flush_time',
    ];
    for (final key in trackingKeys) {
      await prefs.remove(key);
    }

    // Purge stale batched checkpoints (keeps only today's entries).
    await purgeStaleLocalCheckpoints(prefs, todayDate);

    // Reset batch counter.
    await prefs.setInt('batch_pending_count', 0);

    // Purge legacy checkpoint queue.
    await prefs.remove('pending_checkpoints_v1');

    // Clean up old cached image files (> 7 days) from app-private storage.
    await _cleanupOldCallImages();

    debugPrint('[BackgroundLocationService] cleanupStaleSession complete for $todayDate.');
  }

  /// Clears ALL transient app data (checkpoints, tracking state, local image
  /// cache, and Firestore offline persistence) WITHOUT touching auth
  /// credentials or activation state.
  ///
  /// Called once automatically after each app version upgrade via
  /// _runPostUpdateCleanup() in main.dart.
  static Future<void> cleanupAllTransientData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Keys to ALWAYS preserve — never delete these.
    const preserveKeys = <String>{
      'cached_app_user',
      'is_activated',
      'activation_code',
      'activation_device_id',
      'has_migrated_v216',
      'has_migrated_v219',
      'last_app_version',
    };

    final allKeys = prefs.getKeys().toList();
    for (final key in allKeys) {
      if (preserveKeys.contains(key)) continue;
      // Preserve any Flutter framework internal keys.
      if (key.startsWith('flutter.')) continue;
      await prefs.remove(key);
    }
    debugPrint('[BackgroundLocationService] cleanupAllTransientData: cleared ${allKeys.length - preserveKeys.length} prefs keys.');

    // Delete the entire app-private call_images cache directory.
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final callImagesDir = Directory('${appDir.path}/call_images');
      if (await callImagesDir.exists()) {
        await callImagesDir.delete(recursive: true);
        debugPrint('[BackgroundLocationService] cleanupAllTransientData: deleted call_images cache.');
      }
    } catch (e) {
      debugPrint('[BackgroundLocationService] cleanupAllTransientData: failed to delete call_images: $e');
    }

    // Clear Firestore offline cache to prevent stale-document errors after update.
    // Must be called before any Firestore reads in this session.
    try {
      await FirebaseFirestore.instance.clearPersistence();
      debugPrint('[BackgroundLocationService] cleanupAllTransientData: Firestore persistence cleared.');
    } catch (e) {
      debugPrint('[BackgroundLocationService] cleanupAllTransientData: Firestore clearPersistence failed (non-fatal): $e');
    }

    debugPrint('[BackgroundLocationService] cleanupAllTransientData complete.');
  }

  /// Deletes call image files older than [retentionDays] from the app-private
  /// `call_images/` cache. Gallery copies and Firebase Storage are never touched.
  static Future<void> _cleanupOldCallImages({int retentionDays = 7}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final callImagesDir = Directory('${appDir.path}/call_images');
      if (!await callImagesDir.exists()) return;

      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      int deleted = 0;

      await for (final entity in callImagesDir.list()) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(cutoff)) {
              await entity.delete();
              deleted++;
            }
          } catch (_) {}
        }
      }

      if (deleted > 0) {
        debugPrint('[BackgroundLocationService] _cleanupOldCallImages: deleted $deleted file(s) older than ${retentionDays}d.');
      }
    } catch (e) {
      debugPrint('[BackgroundLocationService] _cleanupOldCallImages error (non-fatal): $e');
    }
  }
}
