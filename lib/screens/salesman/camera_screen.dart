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

class _CameraScreenState extends State<CameraScreen> {
  final FaceDetectionService _faceDetectionService = FaceDetectionService();

  CameraController? _cameraController;
  bool _isInitializing = true;
  bool _isDetecting = false;
  bool _isCapturing = false;
  bool _isFaceDetected = false;
  bool _isFaceAligned = false;
  String _feedbackText = 'Center your face';

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetectionService.dispose();
    super.dispose();
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

      if (!mounted) return;
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
        setState(() {
          _isFaceDetected = false;
          _isFaceAligned = false;
          _feedbackText = 'Center your face';
        });
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

      setState(() {
        _isFaceDetected = true;
        _isFaceAligned = feedback.isAligned;
        _feedbackText = feedback.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isFaceDetected = false;
        _isFaceAligned = false;
        _feedbackText = 'Center your face';
      });
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

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
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

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.isFirstCall ? 'First Call Selfie' : 'Last Call Selfie',
        ),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: _isInitializing
          ? const Center(child: CircularProgressIndicator())
          : controller == null || !controller.value.isInitialized
          ? Center(
              child: Text(
                _feedbackText,
                style: const TextStyle(color: Colors.white),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),
                CustomPaint(
                  painter: FaceOverlayPainter(
                    isFaceDetected: _isFaceDetected,
                    isFaceAligned: _isFaceAligned,
                  ),
                ),
                Positioned(
                  top: 24,
                  left: 16,
                  right: 16,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _feedbackText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 36,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isFaceAligned
                            ? 'Face aligned. You can capture now.'
                            : 'Align your face within the guide.',
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _isFaceAligned && !_isCapturing
                            ? _capture
                            : null,
                        icon: _isCapturing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.camera_alt),
                        label: const Text('Capture'),
                      ),
                    ],
                  ),
                ),
              ],
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
