import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class CroppedProfileImageResult {
  final Uint8List bytes;
  final int width;
  final int height;

  const CroppedProfileImageResult({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Pure-Dart crop, resize (square [targetSize]x[targetSize]), and JPEG
/// compression helper. Keeps output <= [maxBytes] (default 150 KB).
CroppedProfileImageResult cropAndCompressProfileImage({
  required Uint8List sourceBytes,
  required double cropXFraction,
  required double cropYFraction,
  required double cropWidthFraction,
  required double cropHeightFraction,
  int targetSize = 512,
  int maxBytes = 150 * 1024,
}) {
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw Exception('Unable to decode selected image.');
  }

  final oriented = img.bakeOrientation(decoded);
  final srcW = oriented.width;
  final srcH = oriented.height;

  final rawX = (cropXFraction * srcW).round().clamp(0, srcW - 1);
  final rawY = (cropYFraction * srcH).round().clamp(0, srcH - 1);
  final rawW = (cropWidthFraction * srcW).round().clamp(1, srcW - rawX);
  final rawH = (cropHeightFraction * srcH).round().clamp(1, srcH - rawY);

  // Enforce a 1:1 square crop centered inside the requested box.
  final side = math.min(rawW, rawH);
  final squareX = (rawX + ((rawW - side) ~/ 2)).clamp(0, srcW - side);
  final squareY = (rawY + ((rawH - side) ~/ 2)).clamp(0, srcH - side);

  final cropped = img.copyCrop(
    oriented,
    x: squareX,
    y: squareY,
    width: side,
    height: side,
  );

  final finalSize = math.min(side, targetSize);
  final resized = finalSize < side
      ? img.copyResize(
          cropped,
          width: finalSize,
          height: finalSize,
          interpolation: img.Interpolation.average,
        )
      : cropped;

  int quality = 84;
  Uint8List encoded = Uint8List.fromList(
    img.encodeJpg(resized, quality: quality),
  );
  while (encoded.length > maxBytes && quality > 40) {
    quality -= 8;
    encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
  }

  return CroppedProfileImageResult(
    bytes: encoded,
    width: resized.width,
    height: resized.height,
  );
}

class ProfileImageCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final String userDisplayName;

  const ProfileImageCropDialog({
    super.key,
    required this.imageBytes,
    required this.userDisplayName,
  });

  static Future<CroppedProfileImageResult?> show(
    BuildContext context, {
    required Uint8List imageBytes,
    required String userDisplayName,
  }) {
    return showDialog<CroppedProfileImageResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProfileImageCropDialog(
        imageBytes: imageBytes,
        userDisplayName: userDisplayName,
      ),
    );
  }

  @override
  State<ProfileImageCropDialog> createState() => _ProfileImageCropDialogState();
}

class _ProfileImageCropDialogState extends State<ProfileImageCropDialog> {
  static const double _viewportSize = 300.0;
  static const double _minScale = 1.0;
  static const double _maxScale = 4.0;

  final TransformationController _transformController =
      TransformationController();

  int? _imageWidth;
  int? _imageHeight;
  double _displayWidth = _viewportSize;
  double _displayHeight = _viewportSize;
  double _zoom = 1.0;
  bool _isProcessing = false;
  String? _decodeError;

  @override
  void initState() {
    super.initState();
    _initImageDimensions();
    _transformController.addListener(_syncZoomFromController);
  }

  void _initImageDimensions() {
    final decoded = img.decodeImage(widget.imageBytes);
    if (decoded == null) {
      _decodeError = 'Unsupported or corrupted image file.';
      return;
    }
    final oriented = img.bakeOrientation(decoded);
    _imageWidth = oriented.width;
    _imageHeight = oriented.height;

    // Fit image so the shorter edge fills the square viewport (cover behavior).
    final aspect = oriented.width / oriented.height;
    if (aspect >= 1.0) {
      _displayHeight = _viewportSize;
      _displayWidth = _viewportSize * aspect;
    } else {
      _displayWidth = _viewportSize;
      _displayHeight = _viewportSize / aspect;
    }

    // Center the image in the viewport initially.
    final dx = (_viewportSize - _displayWidth) / 2.0;
    final dy = (_viewportSize - _displayHeight) / 2.0;
    _transformController.value = Matrix4.translationValues(dx, dy, 0.0);
  }

  void _syncZoomFromController() {
    final scale = _transformController.value.getMaxScaleOnAxis().clamp(
      _minScale,
      _maxScale,
    );
    if ((scale - _zoom).abs() > 0.01 && mounted) {
      setState(() => _zoom = scale);
    }
  }

  void _setZoom(double newScale) {
    final clampedScale = newScale.clamp(_minScale, _maxScale);
    final current = _transformController.value;
    final currentScale = current.getMaxScaleOnAxis();
    if (currentScale <= 0) return;

    // Zoom around the center of the viewport.
    const focal = Offset(_viewportSize / 2, _viewportSize / 2);
    final tx = current.storage[12];
    final ty = current.storage[13];
    final ratio = clampedScale / currentScale;

    var nextTx = focal.dx - (focal.dx - tx) * ratio;
    var nextTy = focal.dy - (focal.dy - ty) * ratio;

    // Clamp translation so the image always covers the crop viewport.
    final scaledW = _displayWidth * clampedScale;
    final scaledH = _displayHeight * clampedScale;
    nextTx = nextTx.clamp(_viewportSize - scaledW, 0.0);
    nextTy = nextTy.clamp(_viewportSize - scaledH, 0.0);

    final next = Matrix4.identity()
      ..setEntry(0, 0, clampedScale)
      ..setEntry(1, 1, clampedScale)
      ..setEntry(0, 3, nextTx)
      ..setEntry(1, 3, nextTy);

    _transformController.value = next;
    setState(() => _zoom = clampedScale);
  }

  Future<void> _confirmCrop() async {
    if (_isProcessing || _imageWidth == null || _imageHeight == null) return;
    setState(() => _isProcessing = true);

    try {
      // Allow spinner to paint before synchronous pixel crop/encode.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final matrix = _transformController.value;
      final scale = matrix.getMaxScaleOnAxis();
      final tx = matrix.storage[12];
      final ty = matrix.storage[13];

      // Convert viewport [0.._viewportSize] back into child image coordinates.
      final childLeft = (-tx / scale).clamp(0.0, _displayWidth);
      final childTop = (-ty / scale).clamp(0.0, _displayHeight);
      final childWidth = (_viewportSize / scale).clamp(
        1.0,
        _displayWidth - childLeft,
      );
      final childHeight = (_viewportSize / scale).clamp(
        1.0,
        _displayHeight - childTop,
      );

      final result = cropAndCompressProfileImage(
        sourceBytes: widget.imageBytes,
        cropXFraction: childLeft / _displayWidth,
        cropYFraction: childTop / _displayHeight,
        cropWidthFraction: childWidth / _displayWidth,
        cropHeightFraction: childHeight / _displayHeight,
      );

      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Crop failed: $e')));
    }
  }

  @override
  void dispose() {
    _transformController.removeListener(_syncZoomFromController);
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(
        'Crop Profile Photo — ${widget.userDisplayName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      content: _decodeError != null
          ? SizedBox(
              width: _viewportSize,
              child: Text(
                _decodeError!,
                style: const TextStyle(color: Colors.red),
              ),
            )
          : SizedBox(
              width: _viewportSize + 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Drag to reposition and use the slider or scroll to zoom.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: _viewportSize,
                        height: _viewportSize,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(color: Colors.black),
                            InteractiveViewer(
                              transformationController: _transformController,
                              constrained: false,
                              minScale: _minScale,
                              maxScale: _maxScale,
                              boundaryMargin: EdgeInsets.zero,
                              child: SizedBox(
                                width: _displayWidth,
                                height: _displayHeight,
                                child: Image.memory(
                                  widget.imageBytes,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _CircularCropMaskPainter(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(
                        Icons.zoom_out_rounded,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      Expanded(
                        child: Slider(
                          value: _zoom.clamp(_minScale, _maxScale),
                          min: _minScale,
                          max: _maxScale,
                          onChanged: _isProcessing ? null : _setZoom,
                        ),
                      ),
                      Icon(
                        Icons.zoom_in_rounded,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                  Text(
                    'Output will be compressed to 512×512 JPEG (≤ 150 KB)',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: (_isProcessing || _decodeError != null)
              ? null
              : _confirmCrop,
          icon: _isProcessing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.crop_rounded, size: 18),
          label: Text(_isProcessing ? 'Compressing...' : 'Crop & Upload'),
        ),
      ],
    );
  }
}

class _CircularCropMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final overlayPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    final rect = Offset.zero & size;
    final radius = math.min(size.width, size.height) / 2.0 - 4.0;
    final center = Offset(size.width / 2.0, size.height / 2.0);

    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect)
      ..addOval(Rect.fromCircle(center: center, radius: radius));

    canvas.drawPath(path, overlayPaint);

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawCircle(center, radius, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

