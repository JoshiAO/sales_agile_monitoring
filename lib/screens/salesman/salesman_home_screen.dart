import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:geolocator/geolocator.dart' show Position;
import 'package:intl/intl.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr/qr.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/location_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class SalesmanHomeScreen extends StatefulWidget {
  const SalesmanHomeScreen({super.key});

  @override
  State<SalesmanHomeScreen> createState() => _SalesmanHomeScreenState();
}

class _SalesmanHomeScreenState extends State<SalesmanHomeScreen> {
  static const Duration _checkpointMinInterval = Duration(minutes: 15);
  static const double _checkpointMinDistanceMeters = 300.0;

  final LocationService _locationService = LocationService();
  final StorageService _storageService = StorageService();
  final FirestoreService _firestoreService = FirestoreService();
  final ImagePicker _imagePicker = ImagePicker();

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
  StreamSubscription<geo.Position>? _locationSubscription;
  DateTime? _lastCheckpointTime;
  double? _lastCheckpointLat;
  double? _lastCheckpointLon;

  String get _todayDate => DateFormat('yyyy-MM-dd').format(DateTime.now());

  String _googleMapsLink(double lat, double lon) {
    return 'https://www.google.com/maps/search/?api=1&query=$lat,$lon';
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
      return _StampedImageResult(
        localFile: sourceFile,
        uploadFile: sourceFile,
      );
    }

    final baseImage = img.bakeOrientation(decoded);
    final output = img.Image.from(baseImage);

    // Place all details in a bottom-right square panel.
    final panelPadding = max(12, (output.width * 0.015).toInt());
    final panelSize = max(250, min(output.width, output.height) ~/ 3);
    final panelX = output.width - panelSize - panelPadding;
    final panelY = output.height - panelSize - panelPadding;

    // Outer soft shadow block
    img.fillRect(
      output,
      x1: panelX - 2,
      y1: panelY - 2,
      x2: panelX + panelSize + 2,
      y2: panelY + panelSize + 2,
      color: img.ColorRgba8(0, 0, 0, 120),
    );

    img.fillRect(
      output,
      x1: panelX,
      y1: panelY,
      x2: panelX + panelSize,
      y2: panelY + panelSize,
      color: img.ColorRgba8(18, 20, 24, 205),
    );

    // White border for clearer legibility against any background.
    img.drawRect(
      output,
      x1: panelX,
      y1: panelY,
      x2: panelX + panelSize,
      y2: panelY + panelSize,
      color: img.ColorRgba8(255, 255, 255, 210),
    );

    final mapsUrl = _googleMapsLink(position.latitude, position.longitude);
    final qrSize = max(88, (panelSize * 0.46).toInt());
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

    const innerPadding = 10;
    final qrX = panelX + ((panelSize - qrSize) ~/ 2);
    final qrY = panelY + panelSize - qrSize - innerPadding;

    img.fillRect(
      output,
      x1: qrX - 5,
      y1: qrY - 5,
      x2: qrX + qrSize + 5,
      y2: qrY + qrSize + 5,
      color: img.ColorRgb8(255, 255, 255),
    );
    img.compositeImage(output, qrImage, dstX: qrX, dstY: qrY);

    final textX = panelX + innerPadding;
    var textY = panelY + innerPadding;

    img.drawString(
      output,
      'CALL DETAILS',
      font: img.arial24,
      x: textX,
      y: textY,
      color: img.ColorRgb8(255, 255, 255),
    );
    textY += 30;

    final lines = <String>[
      'Salesman: $salesmanName',
      'Long-Lat: ${position.longitude.toStringAsFixed(6)}, ${position.latitude.toStringAsFixed(6)}',
      'Date: ${DateFormat('yyyy-MM-dd').format(capturedAt)}',
      'Time: ${DateFormat('HH:mm:ss').format(capturedAt)}',
      'Scan QR to open map',
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
      textY += 20;
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
    await uploadFile.writeAsBytes(img.encodeJpg(uploadImage, quality: 72));

    return _StampedImageResult(
      localFile: localFile,
      uploadFile: uploadFile,
    );
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

  void _previewCallImage({
    required bool isFirst,
    required RoutePoint point,
  }) {
    final localPath = isFirst ? _firstLocalImagePath : _lastLocalImagePath;
    final imageProvider =
        (localPath != null && File(localPath).existsSync())
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
                  child: Image(
                    image: imageProvider,
                    fit: BoxFit.contain,
                  ),
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
    _loadTodayRoute();
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _syncCheckpointTracking() async {
    final shouldTrack =
        _todayRouteId != null && _firstPoint != null && _lastPoint == null;

    if (!shouldTrack) {
      await _locationSubscription?.cancel();
      _locationSubscription = null;
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

    if (_locationSubscription != null) {
      return;
    }

    // Request background location permission so the foreground service
    // can continue reporting position when the screen is off.
    final bgStatus = await Permission.locationAlways.request();
    if (!bgStatus.isGranted) {
      // Fall back to foreground-only stream; checkpoints will still work
      // while the screen is on.
    }

    const notificationConfig = geo.ForegroundNotificationConfig(
      notificationText: 'Tracking your sales route in the background.',
      notificationTitle: 'Route Tracker Active',
      enableWakeLock: true,
    );

    final stream = geo.Geolocator.getPositionStream(
      locationSettings: geo.AndroidSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 50,
        forceLocationManager: false,
        foregroundNotificationConfig: notificationConfig,
      ),
    );

    _locationSubscription = stream.listen(
      _onLocationUpdate,
      onError: (_) {},
    );
  }

  void _onLocationUpdate(geo.Position position) {
    final routeId = _todayRouteId;
    if (routeId == null || _firstPoint == null || _lastPoint != null) {
      return;
    }

    final now = DateTime.now();
    final prevLat = _lastCheckpointLat;
    final prevLon = _lastCheckpointLon;

    final timeSinceLast = _lastCheckpointTime == null
        ? _checkpointMinInterval
        : now.difference(_lastCheckpointTime!);

    double distanceSinceLast = 0.0;
    if (prevLat != null && prevLon != null) {
      distanceSinceLast = geo.Geolocator.distanceBetween(
        prevLat,
        prevLon,
        position.latitude,
        position.longitude,
      );
    }

    final timeThresholdMet = timeSinceLast >= _checkpointMinInterval;
    final distanceThresholdMet =
        prevLat != null && prevLon != null &&
            distanceSinceLast >= _checkpointMinDistanceMeters;

    if (!timeThresholdMet && !distanceThresholdMet) {
      return;
    }

    _lastCheckpointTime = now;
  _lastCheckpointLat = position.latitude;
  _lastCheckpointLon = position.longitude;

    final checkpoint = RouteCheckpoint(
      lat: position.latitude,
      lon: position.longitude,
      timestamp: now,
    );

    _firestoreService.appendRouteCheckpoint(routeId, checkpoint).catchError(
      (_) {},
    );
  }

  Future<void> _loadTodayRoute() async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;

    if (user != null) {
      final routes =
          await _firestoreService.getRoutesBySalesman(user.uid, _todayDate);
      if (routes.isNotEmpty) {
        final route = routes[0];
        setState(() {
          _todayRouteId = route.routeId;
          _firstPoint = route.hasFirstCall ? route.first : null;
          _lastPoint = route.hasLastCall ? route.last : null;
          _firstRetakeRequested = route.firstRetakeRequested;
          _firstRetakeApproved = route.firstRetakeApproved;
          _lastRetakeRequested = route.lastRetakeRequested;
          _lastRetakeApproved = route.lastRetakeApproved;
        });
        _syncCheckpointTracking();
      } else {
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
    }
  }

  Future<void> _refreshRouteState() async {
    await _loadTodayRoute();
  }

  Future<void> _requestRetake(bool isFirst) async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;
    if (user == null) return;

    if (_todayRouteId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Retake can only be requested after calls are submitted.'),
        ),
      );
      return;
    }

    if (isFirst && _lastPoint != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('First call retake is not allowed once last call is taken.'),
        ),
      );
      return;
    }

    if (isFirst && _firstRetakeRequested || !isFirst && _lastRetakeRequested) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${isFirst ? 'First' : 'Last'} call retake request is already pending.'),
        ),
      );
      return;
    }

    if (isFirst && _firstRetakeApproved || !isFirst && _lastRetakeApproved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${isFirst ? 'First' : 'Last'} call retake already approved. You can retake now.'),
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
        content: Text('${isFirst ? 'First' : 'Last'} call retake request submitted.'),
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
          const SnackBar(
            content: Text('Please take the first call first.'),
          ),
        );
        return;
      }

      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      final position = await _locationService.getCurrentLocation();
      if (position == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to get location')),
        );
        return;
      }

      if (!mounted) return;
      _uploadImage(
        File(pickedFile.path),
        position,
        isFirst,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _uploadImage(File imageFile, Position position, bool isFirst) async {
    setState(() => _isUploading = true);

    try {
      final authProvider = context.read<AuthProvider>();
      final user = authProvider.currentUser;

      if (user == null) return;

      final capturedAt = DateTime.now();
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

      // Upload image to Firebase Storage
      final imageUrl = await _storageService.uploadRouteImage(
        stampedResult.uploadFile,
        user.uid,
        timestamp,
      );

      // Create RoutePoint
      final routePoint = RoutePoint(
        lat: position.latitude,
        lon: position.longitude,
        imageUrl: imageUrl,
        timestamp: capturedAt,
      );

      // Get existing route for today or create new one
      final existingRoutes =
          await _firestoreService.getRoutesBySalesman(user.uid, _todayDate);

      if (existingRoutes.isEmpty) {
        if (isFirst) {
          final routeId = await _firestoreService.createRoute(
            salesmanId: user.uid,
            supervisorId: user.supervisorId ?? '',
            date: _todayDate,
            first: routePoint,
            last: routePoint,
            hasFirstCall: true,
            hasLastCall: false,
          );

          setState(() {
            _todayRouteId = routeId;
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
                gallerySaveError == null
                    ? 'First call saved and copied to gallery. Now take the last call.'
                    : 'First call saved. Gallery copy failed.',
              ),
            ),
          );
        } else {
          if (_firstPoint == null) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please take the first call first'),
              ),
            );
            return;
          }

          setState(() {
            _lastPoint = routePoint;
            _lastLocalImagePath = stampedResult.localFile.path;
          });
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
          await _firestoreService.updateRoute(
            route.routeId,
            {
              'first': routePoint.toMap(),
              'hasFirstCall': true,
              'firstRetakeRequested': false,
              'firstRetakeApproved': false,
            },
          );
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
          await _firestoreService.updateRoute(
            route.routeId,
            {
              'last': routePoint.toMap(),
              'hasLastCall': true,
              'lastRetakeRequested': false,
              'lastRetakeApproved': false,
            },
          );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload error: $e')),
      );
    } finally {
      setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstCallTaken = _firstPoint != null;
    final lastCallTaken = _lastPoint != null;
    final canTakeFirstCall =
      !_isUploading && !lastCallTaken && (!firstCallTaken || _firstRetakeApproved);
    final canTakeLastCall =
      !_isUploading && firstCallTaken && (!lastCallTaken || _lastRetakeApproved);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales Route'),
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _isUploading ? null : _refreshRouteState,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: GestureDetector(
                onTap: () {
                  context.read<AuthProvider>().logout();
                },
                child: const Text(
                  'Logout',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
                    : () => _previewCallImage(
                          isFirst: true,
                          point: _firstPoint!,
                        ),
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
                    : () => _previewCallImage(
                          isFirst: false,
                          point: _lastPoint!,
                        ),
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
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            if (onTap != null) ...[
              const SizedBox(width: 12),
              Column(
                children: const [
                  Icon(Icons.image_outlined, size: 20),
                  SizedBox(height: 2),
                  Text(
                    'Preview',
                    style: TextStyle(fontSize: 10),
                  ),
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

  _StampedImageResult({
    required this.localFile,
    required this.uploadFile,
  });
}
