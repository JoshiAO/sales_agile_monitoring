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
        _isFaceAligned = feedback.isAligned;
        _feedbackText = feedback.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
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

    final allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final rotation = _rotationFromCamera(controller);
    if (rotation == null) {
      return null;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
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
                CustomPaint(painter: const FaceOverlayPainter()),
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
