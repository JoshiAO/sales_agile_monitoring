import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:compact_sales_monitoring/services/firebase_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/checkpoint_queue_service.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:intl/intl.dart';

@pragma('vm:entry-point')
class BackgroundLocationService {
  static const double _checkpointMinDistanceMeters = 500.0;
  static const int _checkpointMinIntervalMinutes = 30;
  static const double _maxCheckpointAccuracyMeters = 250.0; // Increased to 250m to avoid dropping locations when phone is in pocket/car

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
    final previousRouteId = prefs.getString('active_route_id');
    final previousFirstPointTime = prefs.getString('first_point_time');
    final currentFirstPointTime = firstPoint.timestamp.toIso8601String();

    if (previousRouteId != routeId || previousFirstPointTime != currentFirstPointTime) {
      await prefs.setString('active_route_id', routeId);
      await prefs.setString('first_point_time', currentFirstPointTime);
      
      // Set initial checkpoint base
      await prefs.setString('route_start_time', DateTime.now().toIso8601String());
      await prefs.setString('last_checkpoint_time', currentFirstPointTime);
      await prefs.setDouble('last_checkpoint_lat', firstPoint.lat);
      await prefs.setDouble('last_checkpoint_lon', firstPoint.lon);
      await prefs.setInt('checkpoint_count', 0);
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

    service.on('stopService').listen((event) {
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
    Timer? streamWatchdog;
    Timer? periodicFlushTimer;

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
      final prevLat = prefs.getDouble('last_checkpoint_lat');
      final prevLon = prefs.getDouble('last_checkpoint_lon');

      final lastTime = lastTimeStr != null ? DateTime.parse(lastTimeStr) : null;

      final timeSinceLast = lastTime == null
          ? Duration(minutes: _checkpointMinIntervalMinutes)
          : now.difference(lastTime);

      double distanceSinceLast = 0.0;
      if (prevLat != null && prevLon != null) {
        distanceSinceLast = geo.Geolocator.distanceBetween(
          prevLat,
          prevLon,
          position.latitude,
          position.longitude,
        );
      }

      final timeThresholdMet = timeSinceLast.inMinutes >= _checkpointMinIntervalMinutes;
      final distanceThresholdMet =
          prevLat != null &&
          prevLon != null &&
          distanceSinceLast >= _checkpointMinDistanceMeters;

      if (!timeThresholdMet && !distanceThresholdMet && !isManual) return;

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

      final checkpoint = RouteCheckpoint(
        lat: position.latitude,
        lon: position.longitude,
        timestamp: now,
      );

      // OFFLINE FIRST: Accumulate locally, do not upload directly here.
      await _persistToLocalBatch(prefs, routeId, checkpoint);

      // RACE CONDITION FIX: immediately flush after a time-based checkpoint
      // so it doesn't sit in the batch until the next 30-min timer fires.
      final lastFlushStr = prefs.getString('last_flush_time');
      final lastFlush = lastFlushStr != null ? DateTime.parse(lastFlushStr) : null;
      if (lastFlush == null || now.difference(lastFlush).inMinutes >= _checkpointMinIntervalMinutes) {
        await flushPendingBatch(prefs, firestoreService);
      }
    };

    // 1. Process locations when the user moves (stream-based)
    StreamSubscription<geo.Position>? locationSubscription;

    void subscribeToLocation() {
      locationSubscription?.cancel();
      locationSubscription = stream.listen(
        (pos) => processLocation(pos),
        onError: (e) {
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

    // 2. Force a location check every 30 minutes for stationary users.
    // getBestAvailablePosition() will NOT fail indoors — it falls back to last known.
    periodicFlushTimer?.cancel();
    periodicFlushTimer = Timer.periodic(const Duration(minutes: 30), (timer) async {
      await prefs.reload();
      if (prefs.getString('active_route_id') == null) {
        timer.cancel();
        return;
      }
      final pos = await getBestAvailablePosition();
      if (pos != null) await processLocation(pos);

      // Flush any accumulated batch regardless of position result
      await flushPendingBatch(prefs, firestoreService);
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
  
  static Future<void> _persistToLocalBatch(SharedPreferences prefs, String routeId, RouteCheckpoint cp) async {
    final raw = prefs.getStringList(_batchPrefsKey) ?? [];
    raw.add(jsonEncode({
      'routeId': routeId,
      'lat': cp.lat,
      'lon': cp.lon,
      'timestamp': cp.timestamp.millisecondsSinceEpoch,
    }));
    await prefs.setStringList(_batchPrefsKey, raw);
    await prefs.setInt('batch_pending_count', raw.length);
  }

  static Future<void> flushPendingBatch([SharedPreferences? providedPrefs, FirestoreService? providedFs]) async {
    final prefs = providedPrefs ?? await SharedPreferences.getInstance();
    final fs = providedFs ?? FirestoreService();
    
    await prefs.reload();
    final raw = prefs.getStringList(_batchPrefsKey) ?? [];
    if (raw.isEmpty) return;

    final Map<String, List<RouteCheckpoint>> checkpointsByRoute = {};
    final Map<String, List<String>> rawStringsByRoute = {};
    final List<String> remainingRaw = [];

    for (final entryStr in raw) {
      try {
        final map = jsonDecode(entryStr) as Map<String, dynamic>;
        final routeId = map['routeId'] as String;
        final cp = RouteCheckpoint(
          lat: (map['lat'] as num).toDouble(),
          lon: (map['lon'] as num).toDouble(),
          timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
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
}
