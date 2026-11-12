import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/services/checkpoint_queue_service.dart';
import 'package:compact_sales_monitoring/services/connectivity_check_service.dart';
import 'package:compact_sales_monitoring/services/firebase_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';

@pragma('vm:entry-point')
class BackgroundLocationService {
  static const int _checkpointMinIntervalMinutes = 1; // Strict 1-minute local checkpoints
  static const int _batchUploadIntervalMinutes = 20; // Free-tier optimized: upload batch every 20 minutes
  static const int _resumeFlushMinIntervalMinutes = 15; // Minimum elapsed time before an app-resume triggers a flush
  static const double _maxCheckpointAccuracyMeters = 250.0;

  static const String _batchPrefsKey = 'batched_checkpoints_v2';
  static const String _flushLockKey = 'flush_lock_timestamp_ms';
  static const String _lastFlushFailedKey = 'last_flush_failed';

  // In-isolate mutex to prevent overlapping flushes in the same Dart isolate.
  static bool _isFlushing = false;

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
        initialNotificationContent:
            'Live tracking was on after first call, ended after last call.',
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

    if (previousRouteId != routeId ||
        previousFirstPointTime != currentFirstPointTime ||
        isNewDay) {
      await prefs.setString('active_route_id', routeId);
      await prefs.setString('first_point_time', currentFirstPointTime);
      await prefs.setDouble('first_point_lat', firstPoint.lat);
      await prefs.setDouble('first_point_lon', firstPoint.lon);
      await prefs.remove('last_point_time');
      await prefs.remove('last_point_lat');
      await prefs.remove('last_point_lon');

      // Set initial checkpoint base
      await prefs.setString('route_start_time', currentFirstPointTime);

      await prefs.setString('last_checkpoint_time', currentFirstPointTime);
      await prefs.setDouble('last_checkpoint_lat', firstPoint.lat);
      await prefs.setDouble('last_checkpoint_lon', firstPoint.lon);
      await prefs.setInt('checkpoint_count', 0);
      await prefs.remove('session_checkpoints_history');

      // Purge any corrupted or expired (>7d) local batch checkpoints
      await purgeStaleLocalCheckpoints(prefs, todayDateStr);
    } else {
      // Ensure First Call coordinates are always persisted for Live Tracker Dashboard
      await prefs.setDouble('first_point_lat', firstPoint.lat);
      await prefs.setDouble('first_point_lon', firstPoint.lon);
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
  static void notificationTapBackground(
    NotificationResponse notificationResponse,
  ) {
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
    // First attempt to flush any pending batch for that prior-day route so data
    // is not lost before stopping the service.
    final routeStartStr = prefs.getString('route_start_time');
    if (routeStartStr != null) {
      try {
        final routeStartDate = DateTime.parse(routeStartStr);
        final startDateStr = DateFormat('yyyy-MM-dd').format(routeStartDate);
        final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
        if (startDateStr != todayStr) {
          debugPrint(
            '[BackgroundLocationService] Stale route from $startDateStr detected on $todayStr. Flushing & self-terminating.',
          );
          await flushPendingBatch(prefs, firestoreService);
          await prefs.remove('active_route_id');
          service.stopSelf();
          return;
        }
      } catch (_) {
        debugPrint(
          '[BackgroundLocationService] Unparseable route_start_time. Self-terminating.',
        );
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
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 20),
        forceLocationManager: false,
      ),
    );

    int processLocationCount = 0;
    int periodicTickCount = 0;

    late Future<void> Function(geo.Position, [bool isManual]) processLocation;
    late void Function() subscribeToLocation;

    Future<geo.Position?> getBestAvailablePosition() async {
      try {
        return await geo.Geolocator.getCurrentPosition(
          desiredAccuracy: geo.LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {
        debugPrint(
          '[BackgroundLocationService] GPS timeout. Falling back to last known position...',
        );
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
        debugPrint(
          '[BackgroundLocationService] GPS stream silent for 2 mins. Re-subscribing stream...',
        );
        final pos = await getBestAvailablePosition();
        if (pos != null) {
          await processLocation(pos);
        } else {
          // Cleanly re-subscribe the GPS stream without calling onStart() recursively
          subscribeToLocation();
          resetWatchdog();
        }
      });
    }

    processLocation = (geo.Position position, [bool isManual = false]) async {
      resetWatchdog();
      processLocationCount++;

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
          ? const Duration(minutes: _checkpointMinIntervalMinutes)
          : now.difference(lastTime);

      final timeThresholdMet = timeSinceLast.inSeconds >= 60;

      // Strict 1-minute interval requirement unless triggered manually
      if (!timeThresholdMet && !isManual) return;

      if (!timeThresholdMet &&
          !isManual &&
          position.accuracy > _maxCheckpointAccuracyMeters) {
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

      // OFFLINE FIRST: Accumulate locally every 1 minute (0 Firebase writes).
      await _persistToLocalBatch(prefs, routeId, checkpoint);

      // Upload only on manual trigger or when the 20-minute batch window is reached.
      final lastFlushStr = prefs.getString('last_flush_time');
      final lastFlush = lastFlushStr != null ? DateTime.parse(lastFlushStr) : null;
      if (isManual ||
          lastFlush == null ||
          now.difference(lastFlush).inMinutes >= _batchUploadIntervalMinutes) {
        await flushPendingBatch(prefs, firestoreService);
      }
    };

    subscribeToLocation = () {
      locationSubscription?.cancel();
      locationSubscription = stream.listen(
        (pos) => processLocation(pos),
        onError: (Object e) {
          debugPrint('[BackgroundLocationService] Stream error: $e');
          Future.delayed(const Duration(seconds: 10), subscribeToLocation);
        },
        onDone: () {
          debugPrint(
            '[BackgroundLocationService] Stream done. Re-subscribing...',
          );
          Future.delayed(const Duration(seconds: 5), subscribeToLocation);
        },
      );
    };

    subscribeToLocation();
    resetWatchdog();

    // 1.5. Initial 3-minute check to guarantee an early checkpoint
    Timer(const Duration(minutes: 3), () async {
      final pos = await getBestAvailablePosition();
      if (pos != null) await processLocation(pos);
    });

    // 2. Force a location check every 1 minute for stationary users & handle
    //    20-minute batch uploads + connectivity-gated retries.
    periodicFlushTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
      periodicTickCount++;
      await prefs.reload();
      if (prefs.getString('active_route_id') == null) {
        timer.cancel();
        return;
      }

      // Date rollover safety check inside periodic loop
      final startStr = prefs.getString('route_start_time');
      if (startStr != null) {
        try {
          final startDay = DateFormat('yyyy-MM-dd').format(DateTime.parse(startStr));
          final todayDay = DateFormat('yyyy-MM-dd').format(DateTime.now());
          if (startDay != todayDay) {
            await flushPendingBatch(prefs, firestoreService);
            await prefs.remove('active_route_id');
            timer.cancel();
            service.stopSelf();
            return;
          }
        } catch (_) {}
      }

      final pos = await getBestAvailablePosition();
      if (pos != null) await processLocation(pos);

      final now = DateTime.now();
      final lastFlushStr = prefs.getString('last_flush_time');
      final lastFlush = lastFlushStr != null ? DateTime.parse(lastFlushStr) : null;
      final isBatchDue =
          lastFlush == null ||
          now.difference(lastFlush).inMinutes >= _batchUploadIntervalMinutes;

      final hasPendingFirstCall =
          (prefs.getString('pending_first_call_v2') ?? '').isNotEmpty;
      final lastFlushFailed = prefs.getBool(_lastFlushFailedKey) ?? false;

      if (isBatchDue) {
        await flushPendingBatch(prefs, firestoreService);
      } else if (hasPendingFirstCall && periodicTickCount % 3 == 0) {
        // Pending First Call waiting: check free HTTP 204 every 3 mins before
        // attempting upload (costs at most 1 Firestore write once online).
        if (await ConnectivityCheckService.hasInternetConnection()) {
          await flushPendingBatch(prefs, firestoreService);
        }
      } else if (lastFlushFailed && periodicTickCount % 5 == 0) {
        // Previous 20-min batch missed its window while offline: check free
        // HTTP 204 every 5 mins and flush once when back online.
        if (await ConnectivityCheckService.hasInternetConnection()) {
          await flushPendingBatch(prefs, firestoreService);
        }
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

  /// Purges corrupted checkpoints or checkpoints older than 7 days, or whose
  /// timestamp date does not match their own recorded `routeDate`.
  ///
  /// Prior-day checkpoints from recent days (<= 7 days) that still need to be
  /// uploaded to their own historical `routeId` are preserved until
  /// [flushPendingBatch] uploads them.
  static Future<void> purgeStaleLocalCheckpoints([
    SharedPreferences? providedPrefs,
    String? targetDate,
  ]) async {
    final prefs = providedPrefs ?? await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getStringList(_batchPrefsKey) ?? [];
    if (raw.isEmpty) return;

    final now = DateTime.now();
    final todayStr = targetDate ?? DateFormat('yyyy-MM-dd').format(now);
    final validRaw = <String>[];

    for (final entryStr in raw) {
      try {
        final map = jsonDecode(entryStr) as Map<String, dynamic>;
        final tsMs = map['timestamp'] as int?;
        final routeId = map['routeId'] as String?;
        if (tsMs == null || routeId == null || routeId.isEmpty) continue;

        final cpDate = DateTime.fromMillisecondsSinceEpoch(tsMs);
        final cpDateStr = DateFormat('yyyy-MM-dd').format(cpDate);
        final storedRouteDate = (map['routeDate'] as String?) ?? cpDateStr;

        // 1. Discard if the checkpoint's timestamp date doesn't match its own route's date.
        if (cpDateStr != storedRouteDate) {
          debugPrint(
            '[BackgroundLocationService] Purging mismatched checkpoint ($cpDateStr != routeDate $storedRouteDate)',
          );
          continue;
        }

        // 2. Discard if older than 7 days so failed queues never grow unbounded.
        if (now.difference(cpDate).inDays > 7) {
          debugPrint(
            '[BackgroundLocationService] Purging expired checkpoint from $cpDateStr (>7 days old, today: $todayStr)',
          );
          continue;
        }

        validRaw.add(entryStr);
      } catch (_) {}
    }

    if (validRaw.length != raw.length) {
      await prefs.setStringList(_batchPrefsKey, validRaw);
      await prefs.setInt('batch_pending_count', validRaw.length);
    }
  }

  static Future<void> _persistToLocalBatch(
    SharedPreferences prefs,
    String routeId,
    RouteCheckpoint cp,
  ) async {
    await prefs.reload();
    final raw = prefs.getStringList(_batchPrefsKey) ?? [];

    // Tag with the active route's start date when available so midnight edge
    // cases never mismatch the route document's date.
    String routeDateStr = DateFormat('yyyy-MM-dd').format(cp.timestamp);
    final routeStartStr = prefs.getString('route_start_time');
    if (routeStartStr != null) {
      try {
        routeDateStr = DateFormat('yyyy-MM-dd').format(DateTime.parse(routeStartStr));
      } catch (_) {}
    }

    final jsonMap = <String, dynamic>{
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
      final primaryPath = map['localImagePath'] as String?;
      final fallbackPath = map['stampedLocalImagePath'] as String?;

      File? imageFile;
      if (primaryPath != null && File(primaryPath).existsSync()) {
        imageFile = File(primaryPath);
      } else if (fallbackPath != null && File(fallbackPath).existsSync()) {
        imageFile = File(fallbackPath);
      }

      if (imageFile == null) {
        debugPrint(
          '[BackgroundLocationService] Pending first call image file missing; clearing corrupted entry.',
        );
        await prefs.remove('pending_first_call_v2');
        return false;
      }

      final salesmanId = map['salesmanId'] as String;
      final timestamp = map['timestamp'] as String;

      // Upload image (unless we already cached an uploaded URL on a partial retry)
      String imageUrl = (map['uploadedImageUrl'] as String?) ?? '';
      if (imageUrl.isEmpty) {
        imageUrl = await storage.uploadRouteImage(
          imageFile,
          salesmanId,
          timestamp,
        );
        // Save the uploaded URL in pending_first_call_v2 so if Firestore write
        // fails next, we never re-upload the image to Storage on retry.
        map['uploadedImageUrl'] = imageUrl;
        await prefs.setString('pending_first_call_v2', jsonEncode(map));
      }

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

      await fs
          .createRoute(
            salesmanId: salesmanId,
            supervisorId: supervisorId,
            date: date,
            first: routePoint,
            last: routePoint,
            hasFirstCall: true,
            hasLastCall: false,
            companyId: companyId,
            customRouteId: routeId,
          )
          .timeout(const Duration(seconds: 12));

      await prefs.remove('pending_first_call_v2');
      debugPrint(
        '[BackgroundLocationService] Successfully flushed pending_first_call_v2 for route $routeId ($date).',
      );
      return true;
    } catch (e) {
      debugPrint(
        '[BackgroundLocationService] Failed to flush pending first call: $e',
      );
      return false;
    }
  }

  /// Throttled flush for UI lifecycle resumes (`didChangeAppLifecycleState`).
  ///
  /// Avoids burning Firebase Free Tier writes every time the salesman unlocks
  /// their screen. Only flushes on resume if:
  ///   - `pending_first_call_v2` is waiting to upload, OR
  ///   - The last scheduled flush failed (`last_flush_failed == true`), OR
  ///   - There are prior-day checkpoints waiting to upload, OR
  ///   - At least [_resumeFlushMinIntervalMinutes] (15m) have elapsed since `last_flush_time`.
  static Future<void> flushPendingBatchIfDue([
    SharedPreferences? providedPrefs,
    FirestoreService? providedFs,
  ]) async {
    final prefs = providedPrefs ?? await SharedPreferences.getInstance();
    await prefs.reload();

    final hasPendingFirstCall =
        (prefs.getString('pending_first_call_v2') ?? '').isNotEmpty;
    if (hasPendingFirstCall) {
      await flushPendingBatch(prefs, providedFs);
      return;
    }

    final raw = prefs.getStringList(_batchPrefsKey) ?? [];
    if (raw.isEmpty) return;

    final lastFlushFailed = prefs.getBool(_lastFlushFailedKey) ?? false;
    if (lastFlushFailed) {
      await flushPendingBatch(prefs, providedFs);
      return;
    }

    // Check if any queued checkpoint belongs to a previous day
    final todayDateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    for (final entryStr in raw) {
      try {
        final map = jsonDecode(entryStr) as Map<String, dynamic>;
        final routeDate = map['routeDate'] as String?;
        if (routeDate != null && routeDate != todayDateStr) {
          await flushPendingBatch(prefs, providedFs);
          return;
        }
      } catch (_) {}
    }

    final lastFlushStr = prefs.getString('last_flush_time');
    if (lastFlushStr == null) {
      await flushPendingBatch(prefs, providedFs);
      return;
    }

    try {
      final lastFlush = DateTime.parse(lastFlushStr);
      if (DateTime.now().difference(lastFlush).inMinutes >=
          _resumeFlushMinIntervalMinutes) {
        await flushPendingBatch(prefs, providedFs);
      }
    } catch (_) {
      await flushPendingBatch(prefs, providedFs);
    }
  }

  /// Flushes any pending First Call and all queued checkpoints (grouped by
  /// their own `routeId` and `routeDate`) to Firestore.
  ///
  /// Uses an in-isolate mutex (`_isFlushing`) plus a short cross-isolate
  /// timestamp lock (`_flushLockKey`) and atomic read-modify-write removal so
  /// checkpoints added while the network call is in flight are never lost.
  static Future<void> flushPendingBatch([
    SharedPreferences? providedPrefs,
    FirestoreService? providedFs,
  ]) async {
    if (_isFlushing) return;
    _isFlushing = true;

    try {
      final prefs = providedPrefs ?? await SharedPreferences.getInstance();
      final fs = providedFs ?? FirestoreService();

      await prefs.reload();

      // Cross-isolate lock (expires after 25s in case an isolate was killed mid-flush)
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lockMs = prefs.getInt(_flushLockKey) ?? 0;
      if (nowMs - lockMs < 25000) {
        debugPrint(
          '[BackgroundLocationService] Another isolate is currently flushing; skipping duplicate flush.',
        );
        return;
      }
      await prefs.setInt(_flushLockKey, nowMs);

      try {
        await purgeStaleLocalCheckpoints(prefs);

        // 1. Always flush pending First Call first so the route document exists
        //    in Firestore before we append checkpoints to it.
        final hadPendingFirstCall =
            (prefs.getString('pending_first_call_v2') ?? '').isNotEmpty;
        bool firstCallFlushed = true;
        if (hadPendingFirstCall) {
          firstCallFlushed = await flushPendingFirstCall(prefs, fs);
        }

        await prefs.reload();
        final raw = prefs.getStringList(_batchPrefsKey) ?? [];
        if (raw.isEmpty) {
          await prefs.setBool(_lastFlushFailedKey, !firstCallFlushed);
          return;
        }

        final Map<String, List<RouteCheckpoint>> checkpointsByRoute = {};
        final Map<String, String> routeDateByRoute = {};
        final Map<String, Set<int>> uploadedTimestampsByRoute = {};

        for (final entryStr in raw) {
          try {
            final map = jsonDecode(entryStr) as Map<String, dynamic>;
            final tsMs = map['timestamp'] as int;
            final ts = DateTime.fromMillisecondsSinceEpoch(tsMs);
            final cpDateStr = DateFormat('yyyy-MM-dd').format(ts);
            final routeDate = (map['routeDate'] as String?) ?? cpDateStr;

            // Discard if checkpoint timestamp date doesn't match its own routeDate
            if (cpDateStr != routeDate) {
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
            routeDateByRoute[routeId] = routeDate;
            uploadedTimestampsByRoute.putIfAbsent(routeId, () => <int>{}).add(tsMs);
          } catch (_) {}
        }

        final Set<String> succeededRouteIds = <String>{};
        bool anyRouteFailed = !firstCallFlushed;

        for (final entry in checkpointsByRoute.entries) {
          final routeId = entry.key;
          final expectedDate = routeDateByRoute[routeId];
          try {
            await fs.appendRouteCheckpointsBatch(
              routeId,
              entry.value,
              expectedRouteDate: expectedDate,
            );
            succeededRouteIds.add(routeId);
          } catch (e) {
            anyRouteFailed = true;
            debugPrint(
              '[BackgroundLocationService] Batch flush failed for route $routeId: $e',
            );
          }
        }

        // Atomic read-modify-write: reload prefs so any new checkpoint added by
        // the GPS stream while the network request was in flight is preserved!
        if (succeededRouteIds.isNotEmpty) {
          await prefs.reload();
          final latestRaw = prefs.getStringList(_batchPrefsKey) ?? [];
          final remainingRaw = <String>[];

          for (final entryStr in latestRaw) {
            try {
              final map = jsonDecode(entryStr) as Map<String, dynamic>;
              final rId = map['routeId'] as String?;
              final tsMs = map['timestamp'] as int?;
              if (rId != null &&
                  tsMs != null &&
                  succeededRouteIds.contains(rId) &&
                  (uploadedTimestampsByRoute[rId]?.contains(tsMs) ?? false)) {
                // This exact checkpoint was uploaded — remove it from queue.
                continue;
              }
              remainingRaw.add(entryStr);
            } catch (_) {
              // Drop malformed JSON entries
            }
          }

          if (remainingRaw.isEmpty) {
            await prefs.remove(_batchPrefsKey);
            await prefs.setInt('batch_pending_count', 0);
          } else {
            await prefs.setStringList(_batchPrefsKey, remainingRaw);
            await prefs.setInt('batch_pending_count', remainingRaw.length);
          }

          await prefs.setString(
            'last_flush_time',
            DateTime.now().toIso8601String(),
          );
        }

        await prefs.setBool(_lastFlushFailedKey, anyRouteFailed);
      } finally {
        await prefs.remove(_flushLockKey);
      }
    } finally {
      _isFlushing = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Session & Data Cleanup + Self-Service Repair
  // ─────────────────────────────────────────────────────────────────────────

  /// Cleans transient tracking keys from a previous or stale session AFTER
  /// attempting to flush any unuploaded calls/checkpoints from that session.
  ///
  /// Never touches: auth, activation, company branding, or migration flags.
  static Future<void> cleanupStaleSession(String todayDate) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // First attempt to flush any pending prior-day First Call and checkpoints
    // to their own historical route document if the device has internet.
    try {
      await flushPendingBatch(prefs);
    } catch (_) {}

    await prefs.reload();

    // If pending_first_call_v2 still exists from a prior date and is older than
    // 7 days (or corrupted), remove it; if it's from yesterday and offline,
    // keep it only if it's valid so it can still sync when online, OR clear
    // active tracking keys so today's route starts clean.
    final rawPending = prefs.getString('pending_first_call_v2');
    if (rawPending != null && rawPending.isNotEmpty) {
      try {
        final map = jsonDecode(rawPending) as Map<String, dynamic>;
        final pendingDate = map['date'] as String?;
        if (pendingDate == null) {
          await prefs.remove('pending_first_call_v2');
        } else if (pendingDate != todayDate) {
          final parsedDate = DateTime.tryParse(pendingDate);
          if (parsedDate == null ||
              DateTime.now().difference(parsedDate).inDays > 7) {
            await prefs.remove('pending_first_call_v2');
          }
        }
      } catch (_) {
        await prefs.remove('pending_first_call_v2');
      }
    }

    final rawActiveFirstCache = prefs.getString('active_first_call_cache_v1');
    if (rawActiveFirstCache != null && rawActiveFirstCache.isNotEmpty) {
      try {
        final cacheMap = jsonDecode(rawActiveFirstCache) as Map<String, dynamic>;
        if (cacheMap['date'] != todayDate) {
          await prefs.remove('active_first_call_cache_v1');
        }
      } catch (_) {
        await prefs.remove('active_first_call_cache_v1');
      }
    }

    // Clear active session tracking state keys so today starts fresh.
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
      'first_point_lat',
      'first_point_lon',
      'last_point_time',
      'last_point_lat',
      'last_point_lon',
      'last_flush_time',
      _lastFlushFailedKey,
      _flushLockKey,
    ];
    for (final key in trackingKeys) {
      await prefs.remove(key);
    }

    // Purge expired (>7d) or mismatched checkpoints while keeping valid
    // unuploaded batches for retry.
    await purgeStaleLocalCheckpoints(prefs, todayDate);
    final remaining = prefs.getStringList(_batchPrefsKey) ?? [];
    await prefs.setInt('batch_pending_count', remaining.length);

    // Clean up old cached image files (> 7 days) from app-private storage.
    await _cleanupOldCallImages();

    debugPrint(
      '[BackgroundLocationService] cleanupStaleSession complete for $todayDate.',
    );
  }

  /// Clears transient app data (tracking state, old image cache) WITHOUT
  /// touching auth credentials, company activation state, or branding cache.
  ///
  /// Called once automatically after each app version upgrade via
  /// `_runPostUpdateCleanup()` in `main.dart`.
  static Future<void> cleanupAllTransientData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // First attempt to flush any pending data before cleaning up on update.
    try {
      await flushPendingBatch(prefs).timeout(const Duration(seconds: 8));
    } catch (_) {}

    await prefs.reload();

    // Keys to ALWAYS preserve — never delete these.
    // Includes actual ActivationService, AuthProvider, CompanyBrandingProvider,
    // and TelemetryService keys.
    const preserveKeys = <String>{
      'cached_app_user',
      'company_code_activated',
      'company_code_activation_lease_key',
      'company_code_activation_checked_at_ms',
      'company_branding_last',
      'device_uuid',
      'is_activated',
      'activation_code',
      'activation_device_id',
      'has_migrated_v216',
      'has_migrated_v219',
      'last_app_version',
      // Also preserve any unuploaded call/checkpoint queues across updates
      'pending_first_call_v2',
      'active_first_call_cache_v1',
      _batchPrefsKey,
      'batch_pending_count',
    };

    final allKeys = prefs.getKeys().toList();
    int removedCount = 0;
    for (final key in allKeys) {
      if (preserveKeys.contains(key)) continue;
      if (key.startsWith('flutter.')) continue;
      if (key.startsWith('company_branding_')) continue;
      await prefs.remove(key);
      removedCount++;
    }
    debugPrint(
      '[BackgroundLocationService] cleanupAllTransientData: cleared $removedCount transient prefs keys.',
    );

    // Clean old call images (> 7 days) instead of wiping today's active images.
    await _cleanupOldCallImages(retentionDays: 7);

    debugPrint('[BackgroundLocationService] cleanupAllTransientData complete.');
  }

  /// Self-service "Repair & Sync App State" action that replaces the manual
  /// Android "Clear Data & Cache" workaround.
  ///
  /// 1. Checks internet connectivity.
  /// 2. If online, flushes `pending_first_call_v2`, `batched_checkpoints_v2`,
  ///    and legacy `pending_checkpoints_v1` to Firestore.
  /// 3. Stops any stuck background service instance.
  /// 4. Resets corrupted local tracking locks/state while strictly preserving
  ///    Firebase Auth (`cached_app_user`) and Company Activation keys.
  static Future<Map<String, dynamic>> repairAndSyncAppState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Release any stuck flush lock first.
    await prefs.remove(_flushLockKey);
    _isFlushing = false;

    final isOnline = await ConnectivityCheckService.hasInternetConnection();
    bool flushedFirstCall = false;

    if (isOnline) {
      final hadPendingFirst =
          (prefs.getString('pending_first_call_v2') ?? '').isNotEmpty;
      await flushPendingBatch(prefs);
      await prefs.reload();
      if (hadPendingFirst &&
          (prefs.getString('pending_first_call_v2') ?? '').isEmpty) {
        flushedFirstCall = true;
      }

      try {
        final fs = FirestoreService();
        await CheckpointQueueService().flush(fs.appendRouteCheckpoint);
      } catch (_) {}
    }

    try {
      await stopTracking();
    } catch (_) {}

    final todayDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
    await cleanupStaleSession(todayDate);
    await prefs.reload();

    final remainingBatch = (prefs.getStringList(_batchPrefsKey) ?? []).length;
    final hasRemainingFirstCall =
        (prefs.getString('pending_first_call_v2') ?? '').isNotEmpty;

    return <String, dynamic>{
      'online': isOnline,
      'flushedFirstCall': flushedFirstCall,
      'remainingCheckpoints': remainingBatch,
      'hasPendingFirstCall': hasRemainingFirstCall,
    };
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
        debugPrint(
          '[BackgroundLocationService] _cleanupOldCallImages: deleted $deleted file(s) older than ${retentionDays}d.',
        );
      }
    } catch (e) {
      debugPrint(
        '[BackgroundLocationService] _cleanupOldCallImages error (non-fatal): $e',
      );
    }
  }
}
