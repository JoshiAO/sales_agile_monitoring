import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:geolocator/geolocator.dart' show Position;
import 'package:intl/intl.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr/qr.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/providers/version_provider.dart';
import 'package:compact_sales_monitoring/screens/salesman/salesman_debug_screen.dart';
import 'package:compact_sales_monitoring/screens/salesman/camera_screen.dart';
import 'package:compact_sales_monitoring/services/checkpoint_queue_service.dart';
import 'package:compact_sales_monitoring/services/location_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/telemetry_service.dart';
import 'package:compact_sales_monitoring/services/background_location_service.dart';
import 'package:compact_sales_monitoring/services/connectivity_check_service.dart';
import 'package:compact_sales_monitoring/screens/troubleshooting_screen.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

class SalesmanHomeScreen extends StatefulWidget {
  const SalesmanHomeScreen({super.key});

  @override
  State<SalesmanHomeScreen> createState() => _SalesmanHomeScreenState();
}

class _SalesmanHomeScreenState extends State<SalesmanHomeScreen>
    with WidgetsBindingObserver {
  static const double _maxCheckpointAccuracyMeters = 80.0;
  static const int _maxUploadBytes = 300 * 1024;

  final LocationService _locationService = LocationService();
  final StorageService _storageService = StorageService();
  final FirestoreService _firestoreService = FirestoreService();
  final CheckpointQueueService _checkpointQueue = CheckpointQueueService();

  RoutePoint? _firstPoint;
  RoutePoint? _lastPoint;
  String? _todayRouteId;
  bool _firstRetakeRequested = false;
  bool _firstRetakeApproved = false;
  bool _lastRetakeRequested = false;
  bool _lastRetakeApproved = false;
  String? _firstLocalImagePath;
  String? _lastLocalImagePath;
  bool _isUploading = false;
  bool _isConnectivityChecking = false;
  String? _loadedForDate;
  StreamSubscription<geo.Position>? _locationSubscription;
  Timer? _midnightRolloverTimer;
  DateTime? _lastCheckpointTime;
  double? _lastCheckpointLat;
  double? _lastCheckpointLon;

  String get _todayDate => DateFormat('yyyy-MM-dd').format(DateTime.now());

  void _scheduleMidnightRollover() {
    _midnightRolloverTimer?.cancel();

    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    final delay = nextMidnight.difference(now);

    _midnightRolloverTimer = Timer(delay, () async {
      if (!mounted) return;

      // 1. Flush any pending offline call/checkpoints from the day that just
      //    ended to their own historical route document BEFORE stopping/cleaning.
      await BackgroundLocationService.flushPendingBatch().catchError((_) {});
      await _checkpointQueue
          .flush(_firestoreService.appendRouteCheckpoint)
          .catchError((_) {});
      // 2. Stop the background service for the previous day's session.
      await BackgroundLocationService.stopTracking().catchError((_) {});
      // 3. Clean up stale session state before loading the new day.
      await BackgroundLocationService.cleanupStaleSession(_todayDate).catchError((_) {});

      if (!mounted) return;
      _resetRouteState();
      _loadTodayRoute();
      _scheduleMidnightRollover();
    });
  }

  String _googleMapsLink(double lat, double lon) {
    return 'https://www.google.com/maps/search/?api=1&query=$lat,$lon';
  }

  Future<void> _handleLogoutTapped() async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;
    if (user == null) {
      return;
    }

    final latestUser = await _firestoreService.getUser(user.uid);
    if (!mounted) return;

    if (latestUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to validate logout access.')),
      );
      return;
    }

    if (latestUser.logoutRequestApproved) {
      await _firestoreService.clearLogoutApproval(uid: latestUser.uid);
      if (!mounted) return;
      await authProvider.logout();
      return;
    }

    if (latestUser.logoutRequestPending) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Logout Request Pending'),
          content: const Text(
            'Your logout request is still pending. Please wait for superuser approval.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Request Logout Approval'),
        content: const Text(
          'Do you want to send a logout request to superuser?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await _firestoreService.requestLogoutApproval(uid: user.uid);
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Logout request sent. Wait for superuser response.',
                    ),
                  ),
                );
              } catch (error) {
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to send request: $error')),
                );
              }
            },
            child: const Text('Send Request'),
          ),
        ],
      ),
    );
  }

  void _showAlertsModal() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (modalContext) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) =>
            SalesmanAlertsModalContent(scrollController: scrollController),
      ),
    );
  }

  Future<_StampedImageResult> _createStampedCallImage({
    required File sourceFile,
    required String salesmanName,
    required Position position,
    required DateTime capturedAt,
    bool isOffline = false,
  }) async {
    final bytes = await sourceFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return _StampedImageResult(localFile: sourceFile, uploadFile: sourceFile);
    }

    final baseImage = img.bakeOrientation(decoded);
    final output = img.Image.from(baseImage);

    // Place all details in a bottom-right rectangular panel.
    final panelPadding = max(12, (output.width * 0.015).toInt());
    final panelWidth = max(450, (output.width * 0.45).toInt());
    final panelHeight = 165;
    final panelX = output.width - panelWidth - panelPadding;
    final panelY = output.height - panelHeight - panelPadding;

    // Outer soft shadow block
    img.fillRect(
      output,
      x1: panelX - 2,
      y1: panelY - 2,
      x2: panelX + panelWidth + 2,
      y2: panelY + panelHeight + 2,
      color: img.ColorRgba8(0, 0, 0, 120),
    );

    img.fillRect(
      output,
      x1: panelX,
      y1: panelY,
      x2: panelX + panelWidth,
      y2: panelY + panelHeight,
      color: img.ColorRgba8(18, 20, 24, 205),
    );

    // White border for clearer legibility against any background.
    img.drawRect(
      output,
      x1: panelX,
      y1: panelY,
      x2: panelX + panelWidth,
      y2: panelY + panelHeight,
      color: img.ColorRgba8(255, 255, 255, 210),
    );

    final mapsUrl = _googleMapsLink(position.latitude, position.longitude);
    const innerPadding = 12;
    
    // Draw Title Centered
    final titleStr = 'CALL DETAILS';
    final titleX = panelX + (panelWidth ~/ 2) - 75; // Approx centering for arial24
    final titleY = panelY + innerPadding;
    img.drawString(
      output,
      titleStr,
      font: img.arial24,
      x: titleX,
      y: titleY,
      color: img.ColorRgb8(255, 255, 255),
    );

    final contentStartY = titleY + 32;

    // Build QR Code
    final qrSize = 100;
    final qrImage = img.Image(width: qrSize, height: qrSize);
    img.fill(qrImage, color: img.ColorRgb8(255, 255, 255));

    final qr = QrCode.fromData(
      data: mapsUrl,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImageData = QrImage(qr);
    final moduleCount = qrImageData.moduleCount;
    final block = qrSize / moduleCount;

    for (var y = 0; y < moduleCount; y++) {
      for (var x = 0; x < moduleCount; x++) {
        if (!qrImageData.isDark(y, x)) continue;
        final x1 = (x * block).floor();
        final y1 = (y * block).floor();
        final x2 = ((x + 1) * block).ceil() - 1;
        final y2 = ((y + 1) * block).ceil() - 1;
        img.fillRect(
          qrImage,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
    }

    // Place QR Code on the Left
    final qrX = panelX + innerPadding + 4;
    final qrY = contentStartY;

    img.fillRect(
      output,
      x1: qrX - 4,
      y1: qrY - 4,
      x2: qrX + qrSize + 4,
      y2: qrY + qrSize + 4,
      color: img.ColorRgb8(255, 255, 255),
    );
    img.compositeImage(output, qrImage, dstX: qrX, dstY: qrY);

    // OFFLINE banner — horizontal red rectangle in the top-left corner.
    // Drawn after all other elements so it is always visible on any background.
    if (isOffline) {
      const offlineBannerPadH = 16;
      const offlineBannerPadV = 10;
      const offlineBannerW = 162;
      const offlineBannerH = 24 + (offlineBannerPadV * 2);
      const offlineBannerX = 12;
      const offlineBannerY = 12;

      // Semi-transparent red background.
      img.fillRect(
        output,
        x1: offlineBannerX,
        y1: offlineBannerY,
        x2: offlineBannerX + offlineBannerW,
        y2: offlineBannerY + offlineBannerH,
        color: img.ColorRgba8(220, 38, 38, 230),
      );
      // White border for contrast on any background.
      img.drawRect(
        output,
        x1: offlineBannerX,
        y1: offlineBannerY,
        x2: offlineBannerX + offlineBannerW,
        y2: offlineBannerY + offlineBannerH,
        color: img.ColorRgba8(255, 255, 255, 210),
      );
      // "OFFLINE" text in white.
      img.drawString(
        output,
        'OFFLINE',
        font: img.arial24,
        x: offlineBannerX + offlineBannerPadH,
        y: offlineBannerY + offlineBannerPadV,
        color: img.ColorRgb8(255, 255, 255),
      );
    }

    // Place Text Details on the Right
    final textX = qrX + qrSize + 16;
    var textY = contentStartY + 4;

    final lines = <String>[
      'Salesman: $salesmanName',
      'Long-Lat: ${position.longitude.toStringAsFixed(6)}, ${position.latitude.toStringAsFixed(6)}',
      'Date: ${DateFormat('yyyy-MM-dd').format(capturedAt)}',
      'Time: ${DateFormat('hh:mm a').format(capturedAt)}',
    ];

    for (final line in lines) {
      img.drawString(
        output,
        line,
        font: img.arial14,
        x: textX,
        y: textY,
        color: img.ColorRgb8(255, 255, 255),
      );
      textY += 24;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final localDir = Directory('${appDir.path}/call_images');
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    final fileBase = 'call_${capturedAt.millisecondsSinceEpoch}';
    final localPath = '${localDir.path}/$fileBase.jpg';
    final uploadPath = '${localDir.path}/${fileBase}_compressed.jpg';

    final localFile = File(localPath);
    await localFile.writeAsBytes(img.encodeJpg(output, quality: 88));

    var uploadImage = output;
    if (uploadImage.width >= uploadImage.height && uploadImage.width > 1080) {
      uploadImage = img.copyResize(uploadImage, width: 1080);
    } else if (uploadImage.height > 1080) {
      uploadImage = img.copyResize(uploadImage, height: 1080);
    }

    final uploadFile = File(uploadPath);
    await _writeCompressedUpload(
      uploadImage: uploadImage,
      outputFile: uploadFile,
      maxBytes: _maxUploadBytes,
    );

    return _StampedImageResult(localFile: localFile, uploadFile: uploadFile);
  }

  Future<void> _writeCompressedUpload({
    required img.Image uploadImage,
    required File outputFile,
    required int maxBytes,
  }) async {
    var workingImage = uploadImage;
    var quality = 78;
    List<int> encoded = img.encodeJpg(workingImage, quality: quality);

    while (encoded.length > maxBytes && quality > 40) {
      quality -= 8;
      encoded = img.encodeJpg(workingImage, quality: quality);
    }

    while (encoded.length > maxBytes && workingImage.width > 720) {
      final nextWidth = max(720, (workingImage.width * 0.85).round());
      workingImage = img.copyResize(workingImage, width: nextWidth);
      encoded = img.encodeJpg(workingImage, quality: quality);

      while (encoded.length > maxBytes && quality > 32) {
        quality -= 4;
        encoded = img.encodeJpg(workingImage, quality: quality);
      }
    }

    await outputFile.writeAsBytes(encoded, flush: true);
  }

  Future<String?> _saveStampedImageToGallery({
    required File stampedFile,
    required DateTime capturedAt,
    required bool isFirst,
  }) async {
    try {
      if (Platform.isIOS) {
        final status = await Permission.photosAddOnly.request();
        if (!status.isGranted && !status.isLimited) {
          return 'Photo library permission was not granted.';
        }
      }

      final fileName =
          'call_${isFirst ? 'first' : 'last'}_${DateFormat('yyyyMMdd_HHmmss').format(capturedAt)}.jpg';

      final result = await SaverGallery.saveFile(
        filePath: stampedFile.path,
        fileName: fileName,
        androidRelativePath: 'Pictures/CompactSalesMonitoring/Calls',
        skipIfExists: false,
      );

      return result.isSuccess
          ? null
          : (result.errorMessage ?? 'Failed to save image to gallery.');
    } catch (e) {
      return 'Gallery save failed: $e';
    }
  }

  Future<String?> _resolveLocalImagePath(DateTime timestamp) async {
    final appDir = await getApplicationDocumentsDirectory();
    final localPath =
        '${appDir.path}/call_images/call_${timestamp.millisecondsSinceEpoch}.jpg';
    final file = File(localPath);
    return file.existsSync() ? localPath : null;
  }

  void _previewCallImage({required bool isFirst, required RoutePoint point}) {
    final localPath = isFirst ? _firstLocalImagePath : _lastLocalImagePath;
    final imageProvider = (localPath != null && File(localPath).existsSync())
        ? FileImage(File(localPath)) as ImageProvider
        : NetworkImage(point.imageUrl);

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(
                      isFirst ? 'First Call Image' : 'Last Call Image',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Image(image: imageProvider, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// Detects a stale/orphaned session left by a previous day where the
  /// salesman never completed Last Call. If the stored route_start_time
  /// is from a different date, we stop the background service and clean
  /// up before loading today's route — preventing app freeze.
  Future<void> _guardAgainstStaleSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final activeRouteId = prefs.getString('active_route_id');
      final routeStartStr = prefs.getString('route_start_time');

      if (activeRouteId != null && routeStartStr != null) {
        final routeStartDate = DateTime.parse(routeStartStr);
        final startDateStr = DateFormat('yyyy-MM-dd').format(routeStartDate);
        if (startDateStr != _todayDate) {
          debugPrint(
            '[SalesmanHomeScreen] Stale session detected (started $startDateStr, today is $_todayDate). Flushing & cleaning up...',
          );
          await BackgroundLocationService.flushPendingBatch();
          await BackgroundLocationService.stopTracking();
          await BackgroundLocationService.cleanupStaleSession(_todayDate);
        }
      } else if (activeRouteId != null && routeStartStr == null) {
        // active_route_id exists but no start time — corrupted state.
        debugPrint('[SalesmanHomeScreen] Corrupted session state detected. Flushing & cleaning up...');
        await BackgroundLocationService.flushPendingBatch();
        await BackgroundLocationService.stopTracking();
        await BackgroundLocationService.cleanupStaleSession(_todayDate);
      }
    } catch (e) {
      debugPrint('[SalesmanHomeScreen] _guardAgainstStaleSession error (non-fatal): $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleMidnightRollover();
    // Guard first — detect and clean stale sessions before loading today's route.
    _guardAgainstStaleSession().then((_) {
      BackgroundLocationService.flushPendingBatchIfDue().catchError((_) {});
      _checkpointQueue
          .flush(_firestoreService.appendRouteCheckpoint)
          .catchError((_) {});
      _loadTodayRoute();
    }).catchError((Object e) {
      debugPrint('[SalesmanHomeScreen] initState guard error: $e');
      BackgroundLocationService.flushPendingBatchIfDue().catchError((_) {});
      _loadTodayRoute();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Throttled flush on resume: only writes to Firestore if pending_first_call_v2
      // is waiting, a previous flush failed, prior-day points exist, or >=15m elapsed.
      BackgroundLocationService.flushPendingBatchIfDue().catchError((_) {});
      _checkpointQueue
          .flush(_firestoreService.appendRouteCheckpoint)
          .catchError((_) {});

      if (_loadedForDate != null && _loadedForDate != _todayDate) {
        _loadTodayRoute();
      }

      _checkAndRestartBackgroundService();
    }
  }

  Future<void> _checkAndRestartBackgroundService() async {
    if (!kIsWeb && _todayRouteId != null && _firstPoint != null && _lastPoint == null) {
      final service = FlutterBackgroundService();
      if (!(await service.isRunning())) {
        debugPrint('[SalesmanHomeScreen] Background service was killed. Restarting...');
        await BackgroundLocationService.startTracking(_todayRouteId!, _firstPoint!);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnightRolloverTimer?.cancel();
    _locationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _syncCheckpointTracking() async {
    final shouldTrack =
        _todayRouteId != null && _firstPoint != null && _lastPoint == null;

    if (!shouldTrack) {
      await BackgroundLocationService.stopTracking();
      _lastCheckpointTime = null;
      _lastCheckpointLat = null;
      _lastCheckpointLon = null;
      return;
    }

    // Start checkpoint timing/distance window from first call.
    if (_firstPoint != null && _lastCheckpointTime == null) {
      _lastCheckpointTime = _firstPoint!.timestamp;
      _lastCheckpointLat = _firstPoint!.lat;
      _lastCheckpointLon = _firstPoint!.lon;
    }

    if (!kIsWeb) {
      await Permission.locationAlways.request();
    }
    
    // Check battery optimization
    if (!kIsWeb && Platform.isAndroid) {
      final isExempt = await Permission.ignoreBatteryOptimizations.isGranted;
      if (!isExempt) {
        if (mounted) {
          final shouldRequest = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Background Tracking'),
              content: const Text(
                'To accurately track your route between calls, this app needs to run in the background. '
                'Please allow "Unrestricted" battery usage for this app when prompted.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Skip'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Continue'),
                ),
              ],
            ),
          );
          if (shouldRequest == true) {
            await Permission.ignoreBatteryOptimizations.request();
          }
        }
      }
    }

    // Start tracking in background service
    await BackgroundLocationService.startTracking(_todayRouteId!, _firstPoint!);
  }



  static const String _activeFirstCallCacheKey = 'active_first_call_cache_v1';

  Future<void> _saveActiveFirstCallCache({
    required String routeId,
    required RoutePoint firstPoint,
    String? localImagePath,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _activeFirstCallCacheKey,
        jsonEncode({
          'routeId': routeId,
          'date': _todayDate,
          'firstPoint': firstPoint.toMap(),
          'localImagePath': localImagePath,
        }),
      );
    } catch (e) {
      debugPrint('[SalesmanHomeScreen] Failed to save active first call cache: $e');
    }
  }

  Future<void> _clearActiveFirstCallCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeFirstCallCacheKey);
    } catch (_) {}
  }

  Future<void> _loadTodayRoute() async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;

    if (user != null) {
      List<SalesRoute> routes = [];
      bool onlineQuerySucceeded = false;
      try {
        routes = await _firestoreService.getRoutesBySalesman(
          user.uid,
          _todayDate,
        ).timeout(const Duration(seconds: 12));
        onlineQuerySucceeded = true;
      } catch (e) {
        debugPrint('[SalesmanHomeScreen] Unable to load online route (offline): $e');
      }

      if (routes.isNotEmpty) {
        final route = routes[0];
        final firstLocalPath = route.hasFirstCall
            ? await _resolveLocalImagePath(route.first.timestamp)
            : null;
        final lastLocalPath = route.hasLastCall
            ? await _resolveLocalImagePath(route.last.timestamp)
            : null;
        if (route.hasFirstCall && !route.hasLastCall) {
          await _saveActiveFirstCallCache(
            routeId: route.routeId,
            firstPoint: route.first,
            localImagePath: firstLocalPath,
          );
        } else if (route.hasLastCall) {
          await _clearActiveFirstCallCache();
        }
        if (!mounted) return;
        setState(() {
          _todayRouteId = route.routeId;
          _firstPoint = route.hasFirstCall ? route.first : null;
          _lastPoint = route.hasLastCall ? route.last : null;
          _firstLocalImagePath = firstLocalPath;
          _lastLocalImagePath = lastLocalPath;
          _firstRetakeRequested = route.firstRetakeRequested;
          _firstRetakeApproved = route.firstRetakeApproved;
          _lastRetakeRequested = route.lastRetakeRequested;
          _lastRetakeApproved = route.lastRetakeApproved;
        });
        _syncCheckpointTracking();
        if (mounted) {
          context.read<VersionProvider>().setSessionActive(
            route.hasFirstCall && !route.hasLastCall,
          );
        }
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();

        final rawPending = prefs.getString('pending_first_call_v2');
        if (rawPending != null && rawPending.isNotEmpty) {
          try {
            final pendingMap = jsonDecode(rawPending) as Map<String, dynamic>;
            final pendingDate = pendingMap['date'] as String?;
            if (pendingDate != null && pendingDate != _todayDate) {
              // Prior-day pending first call — attempt to flush it and its
              // checkpoints to their historical route before cleaning up.
              debugPrint(
                '[SalesmanHomeScreen] _loadTodayRoute: prior-day pending_first_call_v2 from $pendingDate. Flushing before cleanup.',
              );
              await BackgroundLocationService.flushPendingBatch();
              await BackgroundLocationService.stopTracking();
              await BackgroundLocationService.cleanupStaleSession(_todayDate);
              await _clearActiveFirstCallCache();
              _resetRouteState();
              _loadedForDate = _todayDate;
              return;
            }

            await BackgroundLocationService.purgeStaleLocalCheckpoints(prefs, _todayDate);

            final pendingRouteId = pendingMap['routeId'] as String;
            final pendingLocalPath =
                pendingMap['stampedLocalImagePath'] as String? ??
                pendingMap['localImagePath'] as String?;
            final locationTime = DateTime.fromMillisecondsSinceEpoch(
              pendingMap['locationTime'] as int,
            );

            final routePoint = RoutePoint(
              lat: (pendingMap['lat'] as num).toDouble(),
              lon: (pendingMap['lon'] as num).toDouble(),
              imageUrl: (pendingMap['uploadedImageUrl'] as String?) ?? '',
              timestamp: locationTime,
            );

            if (!mounted) return;
            setState(() {
              _todayRouteId = pendingRouteId;
              _firstPoint = routePoint;
              _lastPoint = null;
              _firstLocalImagePath = pendingLocalPath;
              _firstRetakeRequested = false;
              _firstRetakeApproved = false;
              _lastRetakeRequested = false;
              _lastRetakeApproved = false;
              _lastCheckpointTime = routePoint.timestamp;
              _lastCheckpointLat = routePoint.lat;
              _lastCheckpointLon = routePoint.lon;
            });
            _syncCheckpointTracking();
            if (mounted) {
              context.read<VersionProvider>().setSessionActive(true);
            }
          } catch (_) {
            // Corrupted pending data — clean up and reset.
            debugPrint('[SalesmanHomeScreen] _loadTodayRoute: corrupted pending_first_call_v2. Resetting.');
            await BackgroundLocationService.cleanupStaleSession(_todayDate);
            await _clearActiveFirstCallCache();
            _resetRouteState();
          }
        } else {
          // No pending offline first call in SharedPreferences.
          // If the online query failed (e.g. network timeout mid-day), preserve
          // any active today session rather than wiping it and stopping tracking.
          if (!onlineQuerySucceeded) {
            if (_todayRouteId != null &&
                _loadedForDate == _todayDate &&
                _firstPoint != null) {
              debugPrint(
                '[SalesmanHomeScreen] _loadTodayRoute: offline query failed mid-day; preserving in-memory session $_todayRouteId.',
              );
              _syncCheckpointTracking();
              return;
            }

            final rawCachedFirst = prefs.getString(_activeFirstCallCacheKey);
            if (rawCachedFirst != null && rawCachedFirst.isNotEmpty) {
              try {
                final cacheMap = jsonDecode(rawCachedFirst) as Map<String, dynamic>;
                if (cacheMap['date'] == _todayDate) {
                  final cachedRouteId = cacheMap['routeId'] as String;
                  final cachedPoint = RoutePoint.fromMap(
                    Map<String, dynamic>.from(cacheMap['firstPoint'] as Map),
                  );
                  final cachedLocalPath = cacheMap['localImagePath'] as String?;
                  debugPrint(
                    '[SalesmanHomeScreen] _loadTodayRoute: offline query failed; restored today session $cachedRouteId from local cache.',
                  );
                  if (!mounted) return;
                  setState(() {
                    _todayRouteId = cachedRouteId;
                    _firstPoint = cachedPoint;
                    _lastPoint = null;
                    _firstLocalImagePath = cachedLocalPath;
                  });
                  _syncCheckpointTracking();
                  if (mounted) {
                    context.read<VersionProvider>().setSessionActive(true);
                  }
                  _loadedForDate = _todayDate;
                  return;
                }
              } catch (e) {
                debugPrint('[SalesmanHomeScreen] Failed to restore active first call cache: $e');
              }
            }
          }

          await BackgroundLocationService.purgeStaleLocalCheckpoints(prefs, _todayDate);
          await _clearActiveFirstCallCache();
          await BackgroundLocationService.stopTracking();
          _resetRouteState();
          if (mounted) {
            context.read<VersionProvider>().setSessionActive(false);
          }
        }
      }
    }
    _loadedForDate = _todayDate;
  }

  void _resetRouteState() {
    setState(() {
      _todayRouteId = null;
      _firstPoint = null;
      _lastPoint = null;
      _firstRetakeRequested = false;
      _firstRetakeApproved = false;
      _lastRetakeRequested = false;
      _lastRetakeApproved = false;
      _firstLocalImagePath = null;
      _lastLocalImagePath = null;
    });
    _syncCheckpointTracking();
  }

  Future<void> _requestRetake(bool isFirst) async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;
    if (user == null) return;

    if (_todayRouteId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Retake can only be requested after calls are submitted.',
          ),
        ),
      );
      return;
    }

    if (isFirst && _lastPoint != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'First call retake is not allowed once last call is taken.',
          ),
        ),
      );
      return;
    }

    if (isFirst && _firstRetakeRequested || !isFirst && _lastRetakeRequested) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${isFirst ? 'First' : 'Last'} call retake request is already pending.',
          ),
        ),
      );
      return;
    }

    if (isFirst && _firstRetakeApproved || !isFirst && _lastRetakeApproved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${isFirst ? 'First' : 'Last'} call retake already approved. You can retake now.',
          ),
        ),
      );
      return;
    }

    await _firestoreService.requestCallRetake(
      routeId: _todayRouteId!,
      isFirst: isFirst,
      requestedBy: user.uid,
    );

    setState(() {
      if (isFirst) {
        _firstRetakeRequested = true;
        _firstRetakeApproved = false;
      } else {
        _lastRetakeRequested = true;
        _lastRetakeApproved = false;
      }
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${isFirst ? 'First' : 'Last'} call retake request submitted.',
        ),
      ),
    );
  }

  /// Performs a single real internet connectivity check before proceeding with
  /// camera capture, showing a retry dialog if offline.
  /// Returns `(allowed: true, isOffline: false)` when online,
  /// `(allowed: true, isOffline: true)` when user chooses "Continue Offline" (First Call only),
  /// or `(allowed: false, isOffline: false)` when cancelled.
  Future<({bool allowed, bool isOffline})> _showConnectivityCheckDialog({
    required bool isFirst,
  }) async {
    int retryCount = 0;
    const maxRetries = 3;

    // Perform the single initial check before showing any dialog.
    if (mounted) setState(() => _isConnectivityChecking = true);
    final connected = await ConnectivityCheckService.hasInternetConnection();
    if (mounted) setState(() => _isConnectivityChecking = false);

    if (connected) {
      return (allowed: true, isOffline: false);
    }
    if (!mounted) {
      return (allowed: false, isOffline: false);
    }

    bool isRetryingInDialog = false;

    // Not connected — show dialog.
    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (sbContext, setDialogState) {
            final exhausted = retryCount >= maxRetries;

            return AlertDialog(
              icon: const Icon(Icons.wifi_off, color: Colors.red, size: 40),
              title: const Text('No Internet Connection'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isFirst
                        ? 'A working internet connection is needed to upload your call data. Please check your Wi-Fi or mobile data balance.'
                        : 'An active internet connection is required to record your Last Call on the server. Please check your signal or mobile data and try again.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    retryCount == 0
                        ? 'Initial connection test failed.'
                        : (exhausted
                            ? 'All $maxRetries retry attempts failed.'
                            : 'Retry $retryCount of $maxRetries failed.'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isRetryingInDialog
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                // "Continue Offline" — First Call only, appears after exhausting retries.
                if (isFirst && exhausted)
                  TextButton(
                    onPressed: isRetryingInDialog
                        ? null
                        : () => Navigator.pop(dialogContext, null), // null = offline
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange.shade700,
                    ),
                    child: const Text('Continue Offline'),
                  ),
                FilledButton.icon(
                  icon: isRetryingInDialog
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(isRetryingInDialog ? 'Checking...' : 'Try Again'),
                  onPressed: isRetryingInDialog
                      ? null
                      : () async {
                          setDialogState(() {
                            isRetryingInDialog = true;
                          });
                          final ok =
                              await ConnectivityCheckService.hasInternetConnection();
                          if (ok) {
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext, true);
                            }
                            return;
                          }
                          if (dialogContext.mounted) {
                            setDialogState(() {
                              retryCount++;
                              isRetryingInDialog = false;
                            });
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );

    // result == true  → connected after retry
    // result == null  → continue offline (first call only)
    // result == false → user cancelled
    if (result == true) {
      return (allowed: true, isOffline: false);
    }
    if (result == null && isFirst) {
      return (allowed: true, isOffline: true);
    }
    return (allowed: false, isOffline: false);
  }

  /// Shows a modal dialog when uploading a Last Call (or First Call Retake) fails,
  /// allowing the salesman to retry the server upload using the already-captured
  /// and gallery-saved photo without retaking the selfie.
  Future<bool> _promptUploadRetryDialog({
    required String title,
    required String message,
  }) async {
    if (!mounted) return false;
    final retry = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.cloud_off, color: Colors.orange, size: 40),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.cloud_upload, size: 18),
              label: const Text('Retry Upload'),
              onPressed: () => Navigator.pop(dialogContext, true),
            ),
          ],
        );
      },
    );
    return retry == true;
  }

  Future<void> _takePhoto(bool isFirst) async {
    try {
      if (isFirst && _firstPoint != null && !_firstRetakeApproved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('First call is already uploaded for today.'),
          ),
        );
        return;
      }

      if (!isFirst && _lastPoint != null && !_lastRetakeApproved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Last call is already uploaded for today.'),
          ),
        );
        return;
      }

      if (!isFirst && _firstPoint == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please take the first call first.')),
        );
        return;
      }

      // ── Stale session guard & single unified connectivity check ───────────
      if (isFirst && _firstPoint == null) {
        // Ensure any prior-day orphaned session is flushed and cleaned up first.
        await _guardAgainstStaleSession();
      }

      final connectivity = await _showConnectivityCheckDialog(isFirst: isFirst);
      if (!connectivity.allowed) return;
      final bool isOfflineCapture = connectivity.isOffline;
      // ─────────────────────────────────────────────────────────────────────

      if (!mounted) return;

      final capturedImagePath = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => CameraScreen(isFirstCall: isFirst)),
      );

      if (capturedImagePath == null || capturedImagePath.isEmpty) return;

      final position = await _locationService.getCurrentLocation();
      if (position == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to get location')));
        return;
      }

      if (position.accuracy > _maxCheckpointAccuracyMeters) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Location accuracy is low (${position.accuracy.toStringAsFixed(0)}m). Move to an open area and try again.',
            ),
          ),
        );
        return;
      }

      if (!mounted) return;
      await _uploadImage(
        File(capturedImagePath),
        position,
        isFirst,
        isOfflineCapture: isOfflineCapture,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _uploadImage(
    File imageFile,
    Position position,
    bool isFirst, {
    bool isOfflineCapture = false,
  }) async {
    setState(() => _isUploading = true);

    try {
      final authProvider = context.read<AuthProvider>();
      final user = authProvider.currentUser;

      if (user == null) return;

      // Use capturedAt consistently across the stamped image overlay, gallery
      // filename, and Firestore RoutePoint.timestamp so _resolveLocalImagePath
      // always matches the saved gallery image.
      final capturedAt = DateTime.now();
      final timestamp = capturedAt.toIso8601String();
      final salesmanName = user.email.split('@').first;

      var stampedResult = await _createStampedCallImage(
        sourceFile: imageFile,
        salesmanName: salesmanName,
        position: position,
        capturedAt: capturedAt,
        isOffline: isOfflineCapture,
      );

      final gallerySaveError = await _saveStampedImageToGallery(
        stampedFile: stampedResult.localFile,
        capturedAt: capturedAt,
        isFirst: isFirst,
      );

      // Fetch Device Telemetry and Data Usage once per capture
      final telemetry = await TelemetryService.getDeviceTelemetry();
      final dataUsage = await TelemetryService.getDataUsage();

      final mobileDataEntries = (dataUsage['mobile'] as List<dynamic>?)
          ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
          .toList();
      final wifiDataEntries = (dataUsage['wifi'] as List<dynamic>?)
          ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
          .toList();

      RoutePoint buildRoutePoint(String uploadedUrl) {
        return RoutePoint(
          lat: position.latitude,
          lon: position.longitude,
          imageUrl: uploadedUrl,
          timestamp: capturedAt,
          productName: telemetry['productName'] as String?,
          modelName: telemetry['modelName'] as String?,
          serialNumber: telemetry['serialNumber'] as String?,
          uuid: telemetry['uuid'] as String?,
          batteryLevel: telemetry['batteryLevel'] as int?,
          appVersion: telemetry['appVersion'] as String?,
          mobileDataUsage: mobileDataEntries,
          wifiDataUsage: wifiDataEntries,
        );
      }

      Map<String, dynamic> buildPendingCallData({
        required String routeId,
        required _StampedImageResult stamped,
        String? uploadedImageUrl,
      }) {
        return {
          'routeId': routeId,
          'salesmanId': user.uid,
          'supervisorId': user.supervisorId ?? '',
          'companyId': user.companyId,
          'date': _todayDate,
          'localImagePath': stamped.uploadFile.path,
          'stampedLocalImagePath': stamped.localFile.path,
          if (uploadedImageUrl != null && uploadedImageUrl.isNotEmpty)
            'uploadedImageUrl': uploadedImageUrl,
          'timestamp': timestamp,
          'locationTime': capturedAt.millisecondsSinceEpoch,
          'lat': position.latitude,
          'lon': position.longitude,
          'productName': telemetry['productName'],
          'modelName': telemetry['modelName'],
          'serialNumber': telemetry['serialNumber'],
          'uuid': telemetry['uuid'],
          'batteryLevel': telemetry['batteryLevel'],
          'appVersion': telemetry['appVersion'],
          'mobileDataUsage': mobileDataEntries?.map((e) => e.toMap()).toList(),
          'wifiDataUsage': wifiDataEntries?.map((e) => e.toMap()).toList(),
        };
      }

      String imageUrl = '';

      if (isFirst) {
        final bool isRetakeAttempt = _firstRetakeApproved && _todayRouteId != null;

        if (isOfflineCapture && !isRetakeAttempt) {
          // User explicitly chose "Continue Offline" for a new First Call.
          final generatedRouteId = const Uuid().v4();
          final pendingCallData = buildPendingCallData(
            routeId: generatedRouteId,
            stamped: stampedResult,
          );
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('pending_first_call_v2', jsonEncode(pendingCallData));
          final routePoint = buildRoutePoint('');
          await _saveActiveFirstCallCache(
            routeId: generatedRouteId,
            firstPoint: routePoint,
            localImagePath: stampedResult.localFile.path,
          );

          if (!mounted) return;
          setState(() {
            _todayRouteId = generatedRouteId;
            _firstPoint = routePoint;
            _lastPoint = null;
            _firstLocalImagePath = stampedResult.localFile.path;
            _firstRetakeRequested = false;
            _firstRetakeApproved = false;
            _lastRetakeRequested = false;
            _lastRetakeApproved = false;
            _lastCheckpointTime = routePoint.timestamp;
            _lastCheckpointLat = routePoint.lat;
            _lastCheckpointLon = routePoint.lon;
          });
          _syncCheckpointTracking();

          final versionProvider = context.read<VersionProvider>();
          versionProvider.setSessionActive(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('First call saved offline. Live tracking started.'),
            ),
          );
          return;
        }

        // Online First Call (or First Call Retake)
        while (true) {
          try {
            if (imageUrl.isEmpty) {
              // StorageService.uploadImage handles a 25s timeout with 2 attempts.
              imageUrl = await _storageService.uploadRouteImage(
                stampedResult.uploadFile,
                user.uid,
                timestamp,
              );
            }

            final routePoint = buildRoutePoint(imageUrl);
            final existingRoutes = await _firestoreService
                .getRoutesBySalesman(user.uid, _todayDate)
                .timeout(const Duration(seconds: 12));

            String committedRouteId;
            if (existingRoutes.isEmpty) {
              committedRouteId = const Uuid().v4();
              await _firestoreService
                  .createRoute(
                    salesmanId: user.uid,
                    supervisorId: user.supervisorId ?? '',
                    date: _todayDate,
                    first: routePoint,
                    last: routePoint,
                    hasFirstCall: true,
                    hasLastCall: false,
                    companyId: user.companyId,
                    customRouteId: committedRouteId,
                  )
                  .timeout(const Duration(seconds: 12));
            } else {
              committedRouteId = existingRoutes.first.routeId;
              await _firestoreService
                  .updateRoute(committedRouteId, {
                    'first': routePoint.toMap(),
                    'hasFirstCall': true,
                    'firstRetakeRequested': false,
                    'firstRetakeApproved': false,
                  })
                  .timeout(const Duration(seconds: 12));
            }

            await _saveActiveFirstCallCache(
              routeId: committedRouteId,
              firstPoint: routePoint,
              localImagePath: stampedResult.localFile.path,
            );

            if (!mounted) return;
            setState(() {
              _todayRouteId = committedRouteId;
              _firstPoint = routePoint;
              if (existingRoutes.isEmpty) _lastPoint = null;
              _firstLocalImagePath = stampedResult.localFile.path;
              _firstRetakeRequested = false;
              _firstRetakeApproved = false;
              if (existingRoutes.isEmpty) {
                _lastRetakeRequested = false;
                _lastRetakeApproved = false;
              }
              _lastCheckpointTime = routePoint.timestamp;
              _lastCheckpointLat = routePoint.lat;
              _lastCheckpointLon = routePoint.lon;
            });
            _syncCheckpointTracking();

            final versionProvider = context.read<VersionProvider>();
            versionProvider.setSessionActive(true);
            if (versionProvider.updateDeferred && existingRoutes.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'App update available — will apply after your session ends.',
                  ),
                  duration: Duration(seconds: 4),
                ),
              );
            }

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  existingRoutes.isEmpty
                      ? (gallerySaveError == null
                          ? 'First call saved and copied to gallery. Now take the last call.'
                          : 'First call saved. Gallery copy failed.')
                      : (gallerySaveError == null
                          ? 'First call updated and copied to gallery.'
                          : 'First call updated. Gallery copy failed.'),
                ),
              ),
            );
            return;
          } catch (e) {
            debugPrint('[SalesmanHomeScreen] Online First Call upload failed: $e');
            if (isRetakeAttempt) {
              final retry = await _promptUploadRetryDialog(
                title: 'First Call Retake Upload Failed',
                message:
                    'Your photo is saved to your gallery, but updating the First Call on the server failed.\n\nPlease check your internet connection and tap "Retry Upload".',
              );
              if (retry) continue;
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'First Call retake was not uploaded yet. Please retry when your signal stabilizes.',
                  ),
                ),
              );
              return;
            }

            // New First Call failed mid-upload — fall back to offline First Call
            // queue so the salesman can start their route immediately and
            // BackgroundLocationService will flush it automatically.
            if (!isOfflineCapture) {
              try {
                stampedResult = await _createStampedCallImage(
                  sourceFile: imageFile,
                  salesmanName: salesmanName,
                  position: position,
                  capturedAt: capturedAt,
                  isOffline: true,
                );
              } catch (_) {}
            }
            final generatedRouteId = const Uuid().v4();
            final pendingCallData = buildPendingCallData(
              routeId: generatedRouteId,
              stamped: stampedResult,
              uploadedImageUrl: imageUrl,
            );
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('pending_first_call_v2', jsonEncode(pendingCallData));
            final routePoint = buildRoutePoint(imageUrl);
            await _saveActiveFirstCallCache(
              routeId: generatedRouteId,
              firstPoint: routePoint,
              localImagePath: stampedResult.localFile.path,
            );

            if (!mounted) return;
            setState(() {
              _todayRouteId = generatedRouteId;
              _firstPoint = routePoint;
              _lastPoint = null;
              _firstLocalImagePath = stampedResult.localFile.path;
              _firstRetakeRequested = false;
              _firstRetakeApproved = false;
              _lastRetakeRequested = false;
              _lastRetakeApproved = false;
              _lastCheckpointTime = routePoint.timestamp;
              _lastCheckpointLat = routePoint.lat;
              _lastCheckpointLon = routePoint.lon;
            });
            _syncCheckpointTracking();

            context.read<VersionProvider>().setSessionActive(true);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Connection slow — First Call queued offline and will sync automatically. Live tracking started.',
                ),
              ),
            );
            return;
          }
        }
      } else {
        // ── LAST CALL (or Last Call Retake) ──────────────────────────────────
        if (_firstPoint == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please take the first call first')),
          );
          return;
        }

        while (true) {
          try {
            // 1. Ensure any pending offline First Call is flushed to Firestore first.
            await BackgroundLocationService.flushPendingFirstCall();
            final prefs = await SharedPreferences.getInstance();
            await prefs.reload();
            final rawPendingFirst = prefs.getString('pending_first_call_v2');
            if (rawPendingFirst != null && rawPendingFirst.isNotEmpty) {
              Map<String, dynamic>? pendingMap;
              try {
                pendingMap = jsonDecode(rawPendingFirst) as Map<String, dynamic>;
              } catch (_) {}
              if (pendingMap != null && pendingMap['date'] == _todayDate) {
                throw Exception(
                  'Pending First Call has not finished uploading yet.',
                );
              }
            }

            // 2. Upload Last Call stamped image to Firebase Storage (25s timeout, 2 attempts).
            // Reuses imageUrl if a previous attempt already uploaded the file to Storage.
            if (imageUrl.isEmpty) {
              imageUrl = await _storageService.uploadRouteImage(
                stampedResult.uploadFile,
                user.uid,
                timestamp,
              );
            }

            final routePoint = buildRoutePoint(imageUrl);

            // 3. Query today's route in Firestore (12s timeout) and commit Last Call.
            final existingRoutes = await _firestoreService
                .getRoutesBySalesman(user.uid, _todayDate)
                .timeout(const Duration(seconds: 12));

            String committedRouteId;
            final bool isRetakeUpdate =
                existingRoutes.isNotEmpty && existingRoutes.first.hasLastCall;

            if (existingRoutes.isNotEmpty) {
              committedRouteId = existingRoutes.first.routeId;
              await _firestoreService
                  .updateRoute(committedRouteId, {
                    'last': routePoint.toMap(),
                    'hasLastCall': true,
                    'lastRetakeRequested': false,
                    'lastRetakeApproved': false,
                  })
                  .timeout(const Duration(seconds: 12));
            } else {
              // Fallback: if no route doc was returned (e.g. edge case where doc
              // was not created earlier), create/merge the full route document
              // with both First and Last Call so Last Call is NEVER dropped.
              committedRouteId = _todayRouteId ?? const Uuid().v4();
              await _firestoreService
                  .createRoute(
                    salesmanId: user.uid,
                    supervisorId: user.supervisorId ?? '',
                    date: _todayDate,
                    first: _firstPoint!,
                    last: routePoint,
                    hasFirstCall: true,
                    hasLastCall: true,
                    companyId: user.companyId,
                    customRouteId: committedRouteId,
                  )
                  .timeout(const Duration(seconds: 12));
            }

            // 4. Verified Firestore write succeeded! Now flush remaining checkpoints
            // and mark the session complete.
            await _clearActiveFirstCallCache();

            if (!mounted) return;
            setState(() {
              _todayRouteId = committedRouteId;
              _lastPoint = routePoint;
              _lastLocalImagePath = stampedResult.localFile.path;
              _lastRetakeRequested = false;
              _lastRetakeApproved = false;
              _lastCheckpointTime = null;
              _lastCheckpointLat = null;
              _lastCheckpointLon = null;
            });

            await BackgroundLocationService.flushPendingBatch();
            _checkpointQueue
                .flush(_firestoreService.appendRouteCheckpoint)
                .catchError((_) {});
            _syncCheckpointTracking();

            if (mounted) {
              context.read<VersionProvider>().setSessionActive(false);
            }

            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  isRetakeUpdate
                      ? (gallerySaveError == null
                          ? 'Last call updated and copied to gallery.'
                          : 'Last call updated. Gallery copy failed.')
                      : (gallerySaveError == null
                          ? 'Route saved successfully and copied to gallery.'
                          : 'Route saved successfully. Gallery copy failed.'),
                ),
              ),
            );
            return;
          } catch (e) {
            debugPrint('[SalesmanHomeScreen] Last call upload/commit failed: $e');
            final retry = await _promptUploadRetryDialog(
              title: 'Last Call Upload Failed',
              message:
                  'Your Last Call photo is saved to your gallery, but uploading the call data to the server failed.\n\nPlease check your internet connection and tap "Retry Upload". You do not need to retake the photo.',
            );
            if (retry) {
              continue;
            }
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Last Call is NOT uploaded to the server yet. Please tap Last Call again when your connection is stable.',
                ),
                duration: Duration(seconds: 5),
              ),
            );
            return;
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload error: $e')));
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstCallTaken = _firstPoint != null;
    final lastCallTaken = _lastPoint != null;
    final canTakeFirstCall =
        !_isUploading &&
        !_isConnectivityChecking &&
        !lastCallTaken &&
        (!firstCallTaken || _firstRetakeApproved);
    final canTakeLastCall =
        !_isUploading &&
        !_isConnectivityChecking &&
        firstCallTaken &&
        (!lastCallTaken || _lastRetakeApproved);
    final currentUser = context.watch<AuthProvider>().currentUser;
    final displayName = (currentUser?.name?.trim().isNotEmpty ?? false)
      ? currentUser!.name!.trim()
      : currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: (_firstRetakeRequested || _lastRetakeRequested) ? () async {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Synchronizing account status...')),
            );
            await context.read<AuthProvider>().checkCurrentUser();
            await _loadTodayRoute();
          } : null,
          child: const Text('Sales Route'),
        ),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Troubleshooting Guide',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const TroubleshootingScreen(),
                ),
              );
            },
          ),
          if (!kIsWeb) ...[
            IconButton(
              tooltip: 'Debug Dashboard',
              icon: const Icon(Icons.bug_report),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const SalesmanDebugScreen(),
                  ),
                );
              },
            ),
            StreamBuilder<int>(
              stream: currentUser == null
                  ? const Stream<int>.empty()
                  : _firestoreService.watchUnreadSalesmanNotificationCount(
                      uid: currentUser.uid,
                    ),
              initialData: 0,
              builder: (context, snapshot) {
                final unread = snapshot.data ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Notifications',
                        icon: const Icon(Icons.notifications_outlined),
                        onPressed: _showAlertsModal,
                      ),
                      if (unread > 0)
                        Positioned(
                          top: 8,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            constraints: const BoxConstraints(minWidth: 16),
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: _handleLogoutTapped,
                icon: const Icon(Icons.logout),
                label: const Text('Logout'),
              ),
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // Title
              const Text(
                'Daily Route Tracker',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _todayDate,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
              if (!kIsWeb && currentUser != null) ...[
                const SizedBox(height: 10),
                Text(
                  displayName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                ),
                const SizedBox(height: 2),
                Text(
                  currentUser.email,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
              const SizedBox(height: 48),

              // Status Cards
              _buildStatusCard(
                title: 'First Call',
                isComplete: firstCallTaken,
                subtitle: firstCallTaken
                    ? '${_firstPoint!.lat.toStringAsFixed(4)}, ${_firstPoint!.lon.toStringAsFixed(4)}'
                    : 'Not taken',
                onTap: !firstCallTaken
                    ? null
                    : () =>
                          _previewCallImage(isFirst: true, point: _firstPoint!),
              ),
              if (firstCallTaken)
                TextButton.icon(
                  onPressed: (lastCallTaken || _firstRetakeRequested)
                      ? null
                      : () => _requestRetake(true),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    _firstRetakeRequested
                        ? 'First call retake requested'
                        : _firstRetakeApproved
                        ? 'First call retake approved'
                        : 'Request first call retake',
                  ),
                ),
              const SizedBox(height: 16),
              _buildStatusCard(
                title: 'Last Call',
                isComplete: lastCallTaken,
                subtitle: lastCallTaken
                    ? '${_lastPoint!.lat.toStringAsFixed(4)}, ${_lastPoint!.lon.toStringAsFixed(4)}'
                    : 'Not taken',
                onTap: !lastCallTaken
                    ? null
                    : () =>
                          _previewCallImage(isFirst: false, point: _lastPoint!),
              ),
              if (_lastPoint != null)
                TextButton.icon(
                  onPressed: _lastRetakeRequested
                      ? null
                      : () => _requestRetake(false),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    _lastRetakeRequested
                        ? 'Last call retake requested'
                        : _lastRetakeApproved
                        ? 'Last call retake approved'
                        : 'Request last call retake',
                  ),
                ),
              const SizedBox(height: 48),

              // Buttons
              SizedBox(
                width: 280,
                height: 56,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take First Call'),
                  onPressed: canTakeFirstCall ? () => _takePhoto(true) : null,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 280,
                height: 56,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take Last Call'),
                  onPressed: canTakeLastCall ? () => _takePhoto(false) : null,
                ),
              ),

              if (_isUploading)
                const Padding(
                  padding: EdgeInsets.only(top: 32),
                  child: CircularProgressIndicator(),
                ),
              
              const Spacer(),
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final version = snapshot.data?.version ?? '';
                  final build = snapshot.data?.buildNumber ?? '';
                  final text = version.isNotEmpty ? 'v$version+$build' : '';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      text,
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard({
    required String title,
    required bool isComplete,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isComplete ? Colors.green : Colors.grey.shade300,
            width: 2,
          ),
          color: isComplete ? Colors.green.shade50 : Colors.grey.shade50,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isComplete ? Icons.check_circle : Icons.radio_button_unchecked,
              color: isComplete ? Colors.green : Colors.grey,
              size: 28,
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
            if (onTap != null) ...[
              const SizedBox(width: 12),
              Column(
                children: const [
                  Icon(Icons.image_outlined, size: 20),
                  SizedBox(height: 2),
                  Text('Preview', style: TextStyle(fontSize: 10)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StampedImageResult {
  final File localFile;
  final File uploadFile;

  _StampedImageResult({required this.localFile, required this.uploadFile});
}

class SalesmanAlertsModalContent extends StatefulWidget {
  final ScrollController scrollController;

  const SalesmanAlertsModalContent({super.key, required this.scrollController});

  @override
  State<SalesmanAlertsModalContent> createState() =>
      _SalesmanAlertsModalContentState();
}

class _SalesmanAlertsModalContentState
    extends State<SalesmanAlertsModalContent> {
  final FirestoreService _firestoreService = FirestoreService();
  bool _isMarkingRead = false;

  String _formatDate(dynamic value) {
    if (value is Timestamp) {
      return DateFormat('MMM d, yyyy h:mm a').format(value.toDate().toLocal());
    }
    return 'Unknown time';
  }

  Future<void> _markAllAsRead(String uid) async {
    setState(() => _isMarkingRead = true);
    try {
      await _firestoreService.markAllSalesmanNotificationsRead(uid: uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notifications marked as read.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to mark as read: $error')),
      );
    } finally {
      if (mounted) setState(() => _isMarkingRead = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    if (user == null) {
      return const Center(child: Text('Please sign in again.'));
    }

    return Column(
      children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(
            children: [
              Text(
                'Notifications',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              StreamBuilder<int>(
                stream: _firestoreService.watchUnreadSalesmanNotificationCount(
                  uid: user.uid,
                ),
                initialData: 0,
                builder: (context, snapshot) {
                  final unread = snapshot.data ?? 0;
                  return TextButton.icon(
                    onPressed: unread == 0 || _isMarkingRead
                        ? null
                        : () => _markAllAsRead(user.uid),
                    icon: const Icon(Icons.mark_email_read_outlined),
                    label: Text('Mark all ($unread)'),
                  );
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _firestoreService.watchSalesmanNotifications(uid: user.uid),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Unable to load notifications: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              final docs = (snapshot.data?.docs ?? const []).where((doc) {
                final data = doc.data();
                final occurrence =
                    ((data['occurrence'] as String?) ?? '').toLowerCase();
                final isRead = data['readAt'] != null;
                // One-time notifications are removed from the list once read.
                return !(occurrence == 'once' && isRead);
              }).toList();

              if (docs.isEmpty) {
                return const Center(child: Text('No notifications yet.'));
              }
              return ListView.separated(
                controller: widget.scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: docs.length,
                separatorBuilder: (separatorContext, separatorIndex) =>
                    const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final data = docs[index].data();
                  final title = (data['title'] as String?) ?? 'Notification';
                  final message = (data['message'] as String?) ?? '';
                  final status = (data['status'] as String?) ?? 'info';
                  final createdAt = data['createdAt'];
                  final isUnread = data['readAt'] == null;

                  final statusColor = switch (status) {
                    'approved' => Colors.green,
                    'rejected' => Colors.red,
                    _ => Colors.blueGrey,
                  };

                  return ListTile(
                    tileColor: isUnread ? Colors.yellow.shade50 : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: Colors.grey.shade300),
                    ),
                    leading: CircleAvatar(
                      backgroundColor: statusColor.withValues(alpha: 0.12),
                      child: Icon(Icons.notifications, color: statusColor),
                    ),
                    title: Row(
                      children: [
                        Expanded(child: Text(title)),
                        if (isUnread)
                          Container(
                            width: 9,
                            height: 9,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(message),
                        const SizedBox(height: 6),
                        Text(
                          _formatDate(createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    isThreeLine: true,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
