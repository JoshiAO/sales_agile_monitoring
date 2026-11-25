import 'dart:math' as math;
import 'package:flutter/material.dart';

class FaceOverlayPainter extends CustomPainter {
  final bool isFaceDetected;
  final bool isFaceAligned;
  final double countdownProgress;
  final bool screenFillLight;

  const FaceOverlayPainter({
    required this.isFaceDetected,
    required this.isFaceAligned,
    this.countdownProgress = 0.0,
    this.screenFillLight = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.43);
    final radius = math.min(size.width * 0.37, size.height * 0.27);
    final circleRect = Rect.fromCircle(center: center, radius: radius);

    // Outer mask: soft warm-white softbox when Screen Fill Light is ON,
    // or sleek dark scrim when OFF.
    final overlayPaint = Paint()
      ..color = screenFillLight
          ? const Color(0xFFFFFBF2).withValues(alpha: 0.90)
          : Colors.black.withValues(alpha: 0.62)
      ..style = PaintingStyle.fill;

    final cutoutPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(circleRect);
    canvas.drawPath(cutoutPath, overlayPaint);

    final ringColor = !isFaceDetected
        ? (screenFillLight ? Colors.black38 : Colors.white.withValues(alpha: 0.85))
        : (isFaceAligned ? Colors.greenAccent.shade400 : Colors.amber.shade400);

    // Subtle segmented biometric ticks just outside the main circle.
    final tickPaint = Paint()
      ..color = ringColor.withValues(alpha: isFaceAligned ? 0.55 : 0.30)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    const tickCount = 36;
    final outerTickR = radius + 12;
    final innerTickR = radius + 6;
    for (int i = 0; i < tickCount; i++) {
      final angle = (i * 2 * math.pi) / tickCount;
      final p1 = Offset(
        center.dx + innerTickR * math.cos(angle),
        center.dy + innerTickR * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + outerTickR * math.cos(angle),
        center.dy + outerTickR * math.sin(angle),
      );
      canvas.drawLine(p1, p2, tickPaint);
    }

    // Soft glow behind the ring when face is aligned.
    if (isFaceAligned) {
      final glowPaint = Paint()
        ..color = Colors.greenAccent.shade400.withValues(alpha: 0.32)
        ..strokeWidth = 10
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(center, radius, glowPaint);
    }

    // Base circular border.
    final baseBorderPaint = Paint()
      ..color = countdownProgress > 0
          ? ringColor.withValues(alpha: 0.35)
          : ringColor
      ..strokeWidth = 3.2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, baseBorderPaint);

    // Sweeping countdown progress arc around the circular border.
    if (countdownProgress > 0) {
      final sweepAngle = 2 * math.pi * countdownProgress.clamp(0.0, 1.0);
      final progressPaint = Paint()
        ..color = Colors.greenAccent.shade400
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawArc(
        circleRect,
        -math.pi / 2,
        sweepAngle,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant FaceOverlayPainter oldDelegate) {
    return oldDelegate.isFaceDetected != isFaceDetected ||
        oldDelegate.isFaceAligned != isFaceAligned ||
        oldDelegate.countdownProgress != countdownProgress ||
        oldDelegate.screenFillLight != screenFillLight;
  }
}
