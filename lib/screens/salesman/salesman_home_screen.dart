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
import 'package:compact_sales_monitoring/screens/salesman/salesman_tabs_screen.dart';
import 'package:compact_sales_monitoring/screens/salesman/salesman_debug_screen.dart';
import 'package:compact_sales_monitoring/screens/salesman/camera_screen.dart';
import 'package:compact_sales_monitoring/services/checkpoint_queue_service.dart';
import 'package:compact_sales_monitoring/services/location_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/telemetry_service.dart';
import 'package:compact_sales_monitoring/services/background_location_service.dart';
import 'package:compact_sales_monitoring/screens/troubleshooting_screen.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

class SalesmanHomeScreen extends StatefulWidget {
  const SalesmanHomeScreen({super.key});

  @override
  State<SalesmanHomeScreen> createState() => _SalesmanHomeScreenState();
}

class _SalesmanHomeScreenState extends State<SalesmanHomeScreen>
    with WidgetsBindingObserver {
  static const Duration _checkpointMinInterval = Duration(minutes: 30);
  static const double _checkpointMinDistanceMeters = 500.0;
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

    _midnightRolloverTimer = Timer(delay, () {
      if (!mounted) return;

      // Ensure pending offline checkpoints are attempted at day rollover,
      // then load fresh route state for the new date.
      BackgroundLocationService.flushPendingBatch().catchError((_) {});
      _checkpointQueue
          .flush(_firestoreService.appendRouteCheckpoint)
          .catchError((_) {});
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

    showDialog(
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleMidnightRollover();
    BackgroundLocationService.flushPendingBatch().catchError((_) {});
    _checkpointQueue
        .flush(_firestoreService.appendRouteCheckpoint)
        .catchError((_) {});
    _loadTodayRoute();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Flush any offline-queued checkpoints each time the app comes to the
      // foreground — covers the case where data returned while the app was
      // backgrounded or while the salesman was stationary (no GPS events).
      BackgroundLocationService.flushPendingBatch().catchError((_) {});
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

    final bgStatus = await Permission.locationAlways.request();
    
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

  void _onLocationUpdate(geo.Position position) {
    // Deprecated. Logic moved to BackgroundLocationService headless task.
  }

  Future<void> _loadTodayRoute() async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;

    if (user != null) {
      List<SalesRoute> routes = [];
      try {
        routes = await _firestoreService.getRoutesBySalesman(
          user.uid,
          _todayDate,
        ).timeout(const Duration(seconds: 3));
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
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final rawPending = prefs.getString('pending_first_call_v2');
        if (rawPending != null && rawPending.isNotEmpty) {
          try {
            final pendingMap = jsonDecode(rawPending) as Map<String, dynamic>;
            final pendingRouteId = pendingMap['routeId'] as String;
            final pendingLocalPath = pendingMap['stampedLocalImagePath'] as String? ?? pendingMap['localImagePath'] as String?;
            final locationTime = DateTime.fromMillisecondsSinceEpoch(pendingMap['locationTime'] as int);

            final routePoint = RoutePoint(
              lat: (pendingMap['lat'] as num).toDouble(),
              lon: (pendingMap['lon'] as num).toDouble(),
              imageUrl: '',
              timestamp: locationTime,
            );

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
          } catch (_) {
            _resetRouteState();
          }
        } else {
          _resetRouteState();
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
      _uploadImage(File(capturedImagePath), position, isFirst);
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
    bool isFirst,
  ) async {
    setState(() => _isUploading = true);

    try {
      final authProvider = context.read<AuthProvider>();
      final user = authProvider.currentUser;

      if (user == null) return;

      final capturedAt = DateTime.now();
      final locationTime = position.timestamp;
      final timestamp = capturedAt.toIso8601String();
      final salesmanName = user.email.split('@').first;

      final stampedResult = await _createStampedCallImage(
        sourceFile: imageFile,
        salesmanName: salesmanName,
        position: position,
        capturedAt: capturedAt,
      );

      final gallerySaveError = await _saveStampedImageToGallery(
        stampedFile: stampedResult.localFile,
        capturedAt: capturedAt,
        isFirst: isFirst,
      );

      // Fetch Device Telemetry and Data Usage
      final telemetry = await TelemetryService.getDeviceTelemetry();
      final dataUsage = await TelemetryService.getDataUsage();

      String imageUrl = '';
      bool isOfflineFirstCall = false;

      if (isFirst) {
        try {
          imageUrl = await _storageService.uploadRouteImage(
            stampedResult.uploadFile,
            user.uid,
            timestamp,
          ).timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint('[SalesmanHomeScreen] First call storage upload failed (offline): $e');
          isOfflineFirstCall = true;
        }
      } else {
        try {
          imageUrl = await _storageService.uploadRouteImage(
            stampedResult.uploadFile,
            user.uid,
            timestamp,
          ).timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint('[SalesmanHomeScreen] Last call storage upload failed (offline): $e');
        }
      }

      // Create RoutePoint
      final routePoint = RoutePoint(
        lat: position.latitude,
        lon: position.longitude,
        imageUrl: imageUrl,
        timestamp: locationTime,
        productName: telemetry['productName'] as String?,
        modelName: telemetry['modelName'] as String?,
        serialNumber: telemetry['serialNumber'] as String?,
        uuid: telemetry['uuid'] as String?,
        batteryLevel: telemetry['batteryLevel'] as int?,
        appVersion: telemetry['appVersion'] as String?,
        mobileDataUsage: (dataUsage['mobile'] as List<dynamic>?)
            ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
            .toList(),
        wifiDataUsage: (dataUsage['wifi'] as List<dynamic>?)
            ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
            .toList(),
      );

      List<SalesRoute> existingRoutes = [];
      try {
        existingRoutes = await _firestoreService.getRoutesBySalesman(
          user.uid,
          _todayDate,
        ).timeout(const Duration(seconds: 3));
      } catch (_) {}

      if (existingRoutes.isEmpty) {
        if (isFirst) {
          final generatedRouteId = const Uuid().v4();
          if (isOfflineFirstCall) {
            final pendingCallData = {
              'routeId': generatedRouteId,
              'salesmanId': user.uid,
              'supervisorId': user.supervisorId ?? '',
              'companyId': user.companyId,
              'date': _todayDate,
              'localImagePath': stampedResult.uploadFile.path,
              'stampedLocalImagePath': stampedResult.localFile.path,
              'timestamp': timestamp,
              'locationTime': locationTime.millisecondsSinceEpoch,
              'lat': position.latitude,
              'lon': position.longitude,
              'productName': telemetry['productName'],
              'modelName': telemetry['modelName'],
              'serialNumber': telemetry['serialNumber'],
              'uuid': telemetry['uuid'],
              'batteryLevel': telemetry['batteryLevel'],
              'appVersion': telemetry['appVersion'],
              'mobileDataUsage': (dataUsage['mobile'] as List<dynamic>?)
                  ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>).toMap())
                  .toList(),
              'wifiDataUsage': (dataUsage['wifi'] as List<dynamic>?)
                  ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>).toMap())
                  .toList(),
            };

            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('pending_first_call_v2', jsonEncode(pendingCallData));
          } else {
            try {
              await _firestoreService.createRoute(
                salesmanId: user.uid,
                supervisorId: user.supervisorId ?? '',
                date: _todayDate,
                first: routePoint,
                last: routePoint,
                hasFirstCall: true,
                hasLastCall: false,
                companyId: user.companyId,
                customRouteId: generatedRouteId,
              ).timeout(const Duration(seconds: 3));
            } catch (e) {
              debugPrint('[SalesmanHomeScreen] Firestore createRoute failed (offline): $e');
              isOfflineFirstCall = true;
              final pendingCallData = {
                'routeId': generatedRouteId,
                'salesmanId': user.uid,
                'supervisorId': user.supervisorId ?? '',
                'companyId': user.companyId,
                'date': _todayDate,
                'localImagePath': stampedResult.uploadFile.path,
                'stampedLocalImagePath': stampedResult.localFile.path,
                'timestamp': timestamp,
                'locationTime': locationTime.millisecondsSinceEpoch,
                'lat': position.latitude,
                'lon': position.longitude,
                'productName': telemetry['productName'],
                'modelName': telemetry['modelName'],
                'serialNumber': telemetry['serialNumber'],
                'uuid': telemetry['uuid'],
                'batteryLevel': telemetry['batteryLevel'],
                'appVersion': telemetry['appVersion'],
              };
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('pending_first_call_v2', jsonEncode(pendingCallData));
            }
          }

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

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isOfflineFirstCall
                    ? 'First call saved offline. Live tracking started.'
                    : (gallerySaveError == null
                        ? 'First call saved and copied to gallery. Now take the last call.'
                        : 'First call saved. Gallery copy failed.'),
              ),
            ),
          );
        } else {
          if (_firstPoint == null) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Please take the first call first')),
            );
            return;
          }

          setState(() {
            _lastPoint = routePoint;
            _lastLocalImagePath = stampedResult.localFile.path;
          });
          // Flush any checkpoints queued while data was off before we stop
          // tracking (syncCheckpointTracking cancels the stream once lastPoint
          // is set, so this is the last reliable upload window).
          await BackgroundLocationService.flushPendingBatch();
          _checkpointQueue
              .flush(_firestoreService.appendRouteCheckpoint)
              .catchError((_) {});
          _syncCheckpointTracking();

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                gallerySaveError == null
                    ? 'Route saved successfully and copied to gallery.'
                    : 'Route saved successfully. Gallery copy failed.',
              ),
            ),
          );
        }
      } else {
        // Update existing route
        final route = existingRoutes[0];
        if (isFirst) {
          try {
            await _firestoreService.updateRoute(route.routeId, {
              'first': routePoint.toMap(),
              'hasFirstCall': true,
              'firstRetakeRequested': false,
              'firstRetakeApproved': false,
            }).timeout(const Duration(seconds: 3));
          } catch (e) {
            debugPrint('[SalesmanHomeScreen] updateRoute first call failed (offline): $e');
          }
          setState(() {
            _todayRouteId = route.routeId;
            _firstPoint = routePoint;
            _firstLocalImagePath = stampedResult.localFile.path;
            _firstRetakeRequested = false;
            _firstRetakeApproved = false;
            _lastCheckpointTime = routePoint.timestamp;
            _lastCheckpointLat = routePoint.lat;
            _lastCheckpointLon = routePoint.lon;
          });
          _syncCheckpointTracking();
        } else {
          try {
            await _firestoreService.updateRoute(route.routeId, {
              'last': routePoint.toMap(),
              'hasLastCall': true,
              'lastRetakeRequested': false,
              'lastRetakeApproved': false,
            }).timeout(const Duration(seconds: 3));
          } catch (e) {
            debugPrint('[SalesmanHomeScreen] updateRoute last call failed (offline): $e');
          }
          setState(() {
            _todayRouteId = route.routeId;
            _lastPoint = routePoint;
            _lastLocalImagePath = stampedResult.localFile.path;
            _lastRetakeRequested = false;
            _lastRetakeApproved = false;
            _lastCheckpointTime = null;
            _lastCheckpointLat = null;
            _lastCheckpointLon = null;
          });
          // Flush queued offline checkpoints before stream is cancelled.
          await BackgroundLocationService.flushPendingBatch();
          _checkpointQueue
              .flush(_firestoreService.appendRouteCheckpoint)
              .catchError((_) {});
          _syncCheckpointTracking();
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              gallerySaveError == null
                  ? '${isFirst ? 'First' : 'Last'} call updated and copied to gallery.'
                  : '${isFirst ? 'First' : 'Last'} call updated. Gallery copy failed.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload error: $e')));
    } finally {
      setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstCallTaken = _firstPoint != null;
    final lastCallTaken = _lastPoint != null;
    final canTakeFirstCall =
        !_isUploading &&
        !lastCallTaken &&
        (!firstCallTaken || _firstRetakeApproved);
    final canTakeLastCall =
        !_isUploading &&
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
                MaterialPageRoute(builder: (_) => const TroubleshootingScreen()),
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
                  MaterialPageRoute(
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
