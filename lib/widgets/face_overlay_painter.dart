import 'package:flutter/material.dart';

class FaceOverlayPainter extends CustomPainter {
  final bool isFaceDetected;
  final bool isFaceAligned;

  const FaceOverlayPainter({
    required this.isFaceDetected,
    required this.isFaceAligned,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final ringColor = !isFaceDetected
        ? Colors.white
        : (isFaceAligned ? Colors.greenAccent.shade400 : Colors.amber.shade300);
    final borderPaint = Paint()
      ..color = ringColor
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width * 0.5, size.height * 0.42);
    final ovalRect = Rect.fromCenter(
      center: center,
      width: size.width * 0.56,
      height: size.height * 0.64,
    );

    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final ovalPath = Path()..addOval(ovalRect);
    final cutOut = Path.combine(PathOperation.difference, fullPath, ovalPath);

    canvas.drawPath(cutOut, overlayPaint);
    canvas.drawOval(ovalRect, borderPaint);

    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(center.dx - 16, center.dy),
      Offset(center.dx + 16, center.dy),
      guidePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 16),
      Offset(center.dx, center.dy + 16),
      guidePaint,
    );
  }

  @override
  bool shouldRepaint(covariant FaceOverlayPainter oldDelegate) {
    return oldDelegate.isFaceDetected != isFaceDetected ||
        oldDelegate.isFaceAligned != isFaceAligned;
  }
}
