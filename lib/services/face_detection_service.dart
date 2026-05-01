import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectionFeedback {
  final bool isAligned;
  final String message;

  const FaceDetectionFeedback({required this.isAligned, required this.message});
}

class FaceDetectionService {
  FaceDetectionService()
    : _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableLandmarks: true,
          enableClassification: true,
          minFaceSize: 0.08,
        ),
      );

  final FaceDetector _faceDetector;

  Future<List<Face>> detectFaces(InputImage inputImage) {
    return _faceDetector.processImage(inputImage);
  }

  FaceDetectionFeedback assessFaceAlignment({
    required Face face,
    required Size imageSize,
    required double previewAspectRatio,
    required bool isFrontCamera,
  }) {
    final box = face.boundingBox;
    if (box.isEmpty) {
      return const FaceDetectionFeedback(
        isAligned: false,
        message: 'Center your face',
      );
    }

    final centerX = box.left + box.width / 2;
    final centerY = box.top + box.height / 2;
    final normalizedX = centerX / imageSize.width;
    final normalizedY = centerY / imageSize.height;

    final portraitBias = ((1.0 / previewAspectRatio) - 1.7).clamp(-0.25, 0.25);
    final frontBias = isFrontCamera ? 1.0 : 0.0;

    final ovalCenterX = 0.5;
    final ovalCenterY = (0.42 + (portraitBias * 0.04) - (frontBias * 0.01))
        .clamp(0.38, 0.46);
    final radiusX = (0.28 + (portraitBias * 0.02) + (frontBias * 0.01)).clamp(
      0.25,
      0.32,
    );
    final radiusY = (0.32 + (portraitBias * 0.03) + (frontBias * 0.01)).clamp(
      0.30,
      0.38,
    );

    final ellipseCheck =
        ((normalizedX - ovalCenterX) * (normalizedX - ovalCenterX)) /
            (radiusX * radiusX) +
        ((normalizedY - ovalCenterY) * (normalizedY - ovalCenterY)) /
            (radiusY * radiusY);

    final faceArea = box.width * box.height;
    final imageArea = imageSize.width * imageSize.height;
    final areaRatio = imageArea <= 0 ? 0.0 : faceArea / imageArea;

    final minAreaRatio = (0.09 - (portraitBias * 0.015) - (frontBias * 0.01))
        .clamp(0.06, 0.10);

    if (areaRatio < minAreaRatio) {
      return const FaceDetectionFeedback(
        isAligned: false,
        message: 'Move closer',
      );
    }

    final yawLimit = isFrontCamera ? 18.0 : 15.0;
    final pitchLimit = isFrontCamera ? 18.0 : 14.0;
    final yaw = face.headEulerAngleY ?? 0.0;
    final pitch = face.headEulerAngleX ?? 0.0;
    if (yaw.abs() > yawLimit || pitch.abs() > pitchLimit) {
      return const FaceDetectionFeedback(
        isAligned: false,
        message: 'Center your face',
      );
    }

    if (ellipseCheck > 1.0) {
      return const FaceDetectionFeedback(
        isAligned: false,
        message: 'Center your face',
      );
    }

    return const FaceDetectionFeedback(isAligned: true, message: 'Aligned');
  }

  Future<void> dispose() async {
    await _faceDetector.close();
  }
}
