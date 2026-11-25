import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:compact_sales_monitoring/services/face_detection_service.dart';
import 'package:compact_sales_monitoring/widgets/face_overlay_painter.dart';

class CameraScreen extends StatefulWidget {
  final bool isFirstCall;

  const CameraScreen({super.key, required this.isFirstCall});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with SingleTickerProviderStateMixin {
  final FaceDetectionService _faceDetectionService = FaceDetectionService();

  CameraController? _cameraController;
  bool _isInitializing = true;
  bool _isDetecting = false;
  bool _isCapturing = false;
  bool _isFaceDetected = false;
  bool _isFaceAligned = false;
  bool _screenFillLight = false;
  String _feedbackText = 'Position your face in the circle';

  // Auto-capture countdown
  int _countdown = 0; // 3 → 2 → 1, then capture fires
  Timer? _countdownTimer;
  late final AnimationController _countdownAnimController;

  @override
  void initState() {
    super.initState();
    _countdownAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _initializeCamera();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _countdownAnimController.dispose();
    _cameraController?.dispose();
    _faceDetectionService.dispose();
    super.dispose();
  }

  void _startCountdown() {
    if (_countdownTimer != null) return; // already running
    setState(() => _countdown = 3);
    _countdownAnimController.forward(from: 0.0);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!_isFaceAligned || _isCapturing) {
        _cancelCountdown();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        timer.cancel();
        _countdownTimer = null;
        _capture();
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _countdownAnimController.stop();
    _countdownAnimController.reset();
    if (mounted) setState(() => _countdown = 0);
  }

  Future<void> _initializeCamera() async {
    try {
      final cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) {
        if (!mounted) return;
        setState(() {
          _isInitializing = false;
          _feedbackText = 'Camera permission required';
        });
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _isInitializing = false;
          _feedbackText = 'No camera available';
        });
        return;
      }

      final front = cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
      final selectedCamera = front.isNotEmpty ? front.first : cameras.first;

      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();
      await controller.startImageStream(_processCameraImage);

      if (!mounted) {
        await controller.stopImageStream().catchError((_) {});
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _isInitializing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _feedbackText = 'Unable to initialize camera';
      });
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isDetecting || _isCapturing || _cameraController == null) {
      return;
    }

    _isDetecting = true;
    try {
      final inputImage = _toInputImage(image);
      if (inputImage == null) {
        return;
      }

      final faces = await _faceDetectionService.detectFaces(inputImage);
      if (!mounted) return;

      if (faces.isEmpty) {
        final wasAligned = _isFaceAligned;
        setState(() {
          _isFaceDetected = false;
          _isFaceAligned = false;
          _feedbackText = 'Center your face';
        });
        if (wasAligned) _cancelCountdown();
        return;
      }

      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final previewAspectRatio =
          _cameraController?.value.aspectRatio ?? (image.width / image.height);
      final isFrontCamera =
          _cameraController?.description.lensDirection ==
          CameraLensDirection.front;
      final feedback = _faceDetectionService.assessFaceAlignment(
        face: faces.first,
        imageSize: imageSize,
        previewAspectRatio: previewAspectRatio,
        isFrontCamera: isFrontCamera,
      );

      final wasAligned = _isFaceAligned;
      setState(() {
        _isFaceDetected = true;
        _isFaceAligned = feedback.isAligned;
        _feedbackText = feedback.message;
      });
      if (feedback.isAligned && !wasAligned) {
        _startCountdown();
      } else if (!feedback.isAligned && wasAligned) {
        _cancelCountdown();
      }
    } catch (_) {
      if (!mounted) return;
      final wasAligned = _isFaceAligned;
      setState(() {
        _isFaceDetected = false;
        _isFaceAligned = false;
        _feedbackText = 'Center your face';
      });
      if (wasAligned) _cancelCountdown();
    } finally {
      _isDetecting = false;
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    final controller = _cameraController;
    if (controller == null) return null;

    final rotation = _rotationFromCamera(controller);
    if (rotation == null) {
      return null;
    }

    final converted = _convertCameraImage(image);
    if (converted == null) return null;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: converted.format,
      bytesPerRow: converted.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: converted.bytes, metadata: metadata);
  }

  _InputImageBytes? _convertCameraImage(CameraImage image) {
    if (Platform.isIOS) {
      if (image.planes.isEmpty) return null;
      return _InputImageBytes(
        bytes: image.planes.first.bytes,
        format: InputImageFormat.bgra8888,
        bytesPerRow: image.planes.first.bytesPerRow,
      );
    }

    // Android: prefer NV21. Some devices still deliver YUV_420_888, so convert.
    if (image.planes.length == 1) {
      return _InputImageBytes(
        bytes: image.planes.first.bytes,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      );
    }

    if (image.planes.length == 3) {
      final nv21 = _convertYuv420ToNv21(image);
      if (nv21 == null) return null;
      return _InputImageBytes(
        bytes: nv21,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      );
    }

    final rawFormat = image.format.raw;
    final int? rawValue = rawFormat is int ? rawFormat : int.tryParse(rawFormat.toString());
    final format = rawValue != null ? InputImageFormatValue.fromRawValue(rawValue) : null;
    if (format == null || image.planes.isEmpty) return null;
    return _InputImageBytes(
      bytes: image.planes.first.bytes,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );
  }

  Uint8List? _convertYuv420ToNv21(CameraImage image) {
    if (image.planes.length != 3) return null;

    final width = image.width;
    final height = image.height;
    final ySize = width * height;
    final uvSize = width * height ~/ 2;
    final nv21 = Uint8List(ySize + uvSize);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    var dstIndex = 0;
    for (var row = 0; row < height; row++) {
      final rowStart = row * yPlane.bytesPerRow;
      for (var col = 0; col < width; col++) {
        nv21[dstIndex++] = yPlane.bytes[rowStart + col];
      }
    }

    final uRowStride = uPlane.bytesPerRow;
    final vRowStride = vPlane.bytesPerRow;
    final uPixelStride = uPlane.bytesPerPixel ?? 1;
    final vPixelStride = vPlane.bytesPerPixel ?? 1;

    var uvIndex = ySize;
    for (var row = 0; row < height ~/ 2; row++) {
      final uRowStart = row * uRowStride;
      final vRowStart = row * vRowStride;
      for (var col = 0; col < width ~/ 2; col++) {
        final uIndex = uRowStart + col * uPixelStride;
        final vIndex = vRowStart + col * vPixelStride;
        if (uIndex >= uPlane.bytes.length || vIndex >= vPlane.bytes.length) {
          return null;
        }
        nv21[uvIndex++] = vPlane.bytes[vIndex];
        nv21[uvIndex++] = uPlane.bytes[uIndex];
      }
    }

    return nv21;
  }

  InputImageRotation? _rotationFromCamera(CameraController controller) {
    final camera = controller.description;
    final sensorOrientation = camera.sensorOrientation;

    var deviceRotationDegrees = 0;
    switch (controller.value.deviceOrientation) {
      case DeviceOrientation.portraitUp:
        deviceRotationDegrees = 0;
        break;
      case DeviceOrientation.landscapeLeft:
        deviceRotationDegrees = 90;
        break;
      case DeviceOrientation.portraitDown:
        deviceRotationDegrees = 180;
        break;
      case DeviceOrientation.landscapeRight:
        deviceRotationDegrees = 270;
        break;
    }

    final rotationCompensation =
        camera.lensDirection == CameraLensDirection.front
        ? (sensorOrientation + deviceRotationDegrees) % 360
        : (sensorOrientation - deviceRotationDegrees + 360) % 360;

    return InputImageRotationValue.fromRawValue(rotationCompensation);
  }

  Future<void> _capture() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (!_isFaceAligned || _isCapturing) return;

    setState(() => _isCapturing = true);
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop<String>(file.path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capture failed. Please retry.')),
      );
      try {
        if (!controller.value.isStreamingImages) {
          await controller.startImageStream(_processCameraImage);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final title =
        widget.isFirstCall ? 'First Call Selfie' : 'Last Call Selfie';
    final canManualCapture = _isFaceAligned && !_isCapturing;

    return Scaffold(
      backgroundColor: Colors.black,
      body: _isInitializing
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : controller == null || !controller.value.isInitialized
          ? SafeArea(
              child: Stack(
                children: [
                  Positioned(
                    top: 12,
                    left: 12,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _feedbackText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                // Aspect-ratio-correct full-bleed camera preview
                _buildFullBleedPreview(controller),

                // Circular biometric scanner overlay + sweeping countdown arc
                AnimatedBuilder(
                  animation: _countdownAnimController,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: FaceOverlayPainter(
                        isFaceDetected: _isFaceDetected,
                        isFaceAligned: _isFaceAligned,
                        countdownProgress: _countdown > 0
                            ? _countdownAnimController.value
                            : 0.0,
                        screenFillLight: _screenFillLight,
                      ),
                    );
                  },
                ),

                // Floating glass top bar + status/countdown pill
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            _buildGlassCircleButton(
                              icon: Icons.arrow_back_rounded,
                              tooltip: 'Back',
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    widget.isFirstCall
                                        ? Icons.wb_twilight_rounded
                                        : Icons.nights_stay_rounded,
                                    size: 15,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            _buildGlassCircleButton(
                              icon: _screenFillLight
                                  ? Icons.wb_sunny_rounded
                                  : Icons.wb_sunny_outlined,
                              tooltip: _screenFillLight
                                  ? 'Turn Off Fill Light'
                                  : 'Screen Fill Light',
                              active: _screenFillLight,
                              onPressed: () {
                                setState(
                                  () => _screenFillLight = !_screenFillLight,
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // Dynamic guidance + countdown status pill
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: _isFaceAligned
                                ? const Color(0xFF0E3A24).withValues(alpha: 0.85)
                                : Colors.black.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: _isFaceAligned
                                  ? Colors.greenAccent.shade400
                                  : _isFaceDetected
                                  ? Colors.amber.shade300.withValues(alpha: 0.7)
                                  : Colors.white.withValues(alpha: 0.22),
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isFaceAligned
                                    ? Icons.check_circle_rounded
                                    : _isFaceDetected
                                    ? Icons.center_focus_weak_rounded
                                    : Icons.face_retouching_natural_rounded,
                                size: 17,
                                color: _isFaceAligned
                                    ? Colors.greenAccent.shade400
                                    : _isFaceDetected
                                    ? Colors.amber.shade300
                                    : Colors.white,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _isCapturing
                                    ? 'Capturing photo…'
                                    : _countdown > 0
                                    ? 'Hold still  •  $_countdown'
                                    : _feedbackText,
                                style: TextStyle(
                                  color: _isFaceAligned
                                      ? Colors.greenAccent.shade200
                                      : Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom shutter control bar safely above Android navigation bar
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _isCapturing
                                  ? 'Saving selfie…'
                                  : _countdown > 0
                                  ? 'Auto-capturing in ${_countdown}s — or tap shutter'
                                  : _isFaceAligned
                                  ? 'Aligned! Tap shutter or hold still'
                                  : 'Align your face inside the circle',
                              style: TextStyle(
                                color: _countdown > 0
                                    ? Colors.greenAccent.shade200
                                    : Colors.white.withValues(alpha: 0.92),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          GestureDetector(
                            onTap: canManualCapture
                                ? () {
                                    _cancelCountdown();
                                    _capture();
                                  }
                                : null,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 180),
                              opacity: canManualCapture || _isCapturing
                                  ? 1.0
                                  : 0.42,
                              child: Container(
                                width: 76,
                                height: 76,
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _isFaceAligned
                                        ? Colors.greenAccent.shade400
                                        : Colors.white,
                                    width: 3.5,
                                  ),
                                  color: Colors.black.withValues(alpha: 0.3),
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _isFaceAligned
                                        ? Colors.greenAccent.shade400
                                        : Colors.white,
                                  ),
                                  child: Center(
                                    child: _isCapturing
                                        ? const SizedBox(
                                            width: 26,
                                            height: 26,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.8,
                                              color: Colors.black87,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.camera_alt_rounded,
                                            size: 30,
                                            color: Colors.black87,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildFullBleedPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return CameraPreview(controller);
    }
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: previewSize.height,
          height: previewSize.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  Widget _buildGlassCircleButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active
            ? Colors.amber.shade400
            : Colors.black.withValues(alpha: 0.52),
        shape: CircleBorder(
          side: BorderSide(
            color: active
                ? Colors.amber.shade200
                : Colors.white.withValues(alpha: 0.2),
          ),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 21,
              color: active ? Colors.black87 : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _InputImageBytes {
  final Uint8List bytes;
  final InputImageFormat format;
  final int bytesPerRow;

  const _InputImageBytes({
    required this.bytes,
    required this.format,
    required this.bytesPerRow,
  });
}
