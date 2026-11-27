import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/activation_provider.dart';

/// A slim, dismissible marquee banner placed directly under a screen's header
/// (AppBar) that scrolls the Device Activation Status from right to left.
class DeviceActivationBanner extends StatelessWidget {
  const DeviceActivationBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final activationProvider = context.watch<ActivationProvider>();
    final shouldShow = activationProvider.shouldShowLeaseBanner;
    final message = activationProvider.leaseStatusMessage ?? '';
    final urgent = activationProvider.isLeaseStatusUrgent;

    final background = urgent
        ? const Color(0xFFFDE7E9)
        : const Color(0xFFFFF7E0);
    final border = urgent
        ? const Color(0xFFF28B95)
        : const Color(0xFFF0C36A);
    final textColor = urgent
        ? const Color(0xFF7A1F28)
        : const Color(0xFF6A4A00);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: shouldShow
          ? Material(
              color: background,
              child: Container(
                height: 36,
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: border, width: 1),
                  ),
                ),
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(
                  children: [
                    Icon(
                      urgent
                          ? Icons.warning_amber_rounded
                          : Icons.info_outline_rounded,
                      color: textColor,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _RightToLeftMarquee(
                        text: 'Device Activation Status: $message',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Dismiss',
                      onPressed: () =>
                          context.read<ActivationProvider>().dismissLeaseBanner(),
                      icon: Icon(Icons.close, size: 16, color: textColor),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      splashRadius: 16,
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Convenience wrapper for a Scaffold body that places [DeviceActivationBanner]
/// directly underneath the AppBar without overlapping page content.
class DeviceActivationBannerWrapper extends StatelessWidget {
  final Widget child;

  const DeviceActivationBannerWrapper({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const DeviceActivationBanner(),
        Expanded(child: child),
      ],
    );
  }
}

class _RightToLeftMarquee extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _RightToLeftMarquee({
    required this.text,
    required this.style,
  });

  @override
  State<_RightToLeftMarquee> createState() => _RightToLeftMarqueeState();
}

class _RightToLeftMarqueeState extends State<_RightToLeftMarquee>
    with SingleTickerProviderStateMixin {
  static const double _pixelsPerSecond = 55.0;

  late final AnimationController _controller;
  double _textWidth = 0;
  double _unitWidth = 0;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _RightToLeftMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _textWidth = 0;
      _unitWidth = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _measureTextWidth(TextScaler textScaler) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    return painter.width;
  }

  void _syncAnimation(double viewportWidth, double textWidth) {
    final gap = math.max(120.0, viewportWidth * 0.45);
    final nextUnitWidth = textWidth + gap;

    if ((_unitWidth - nextUnitWidth).abs() < 0.5 &&
        (_textWidth - textWidth).abs() < 0.5) {
      return;
    }

    _textWidth = textWidth;
    _unitWidth = nextUnitWidth;

    final durationMs =
        ((_unitWidth / _pixelsPerSecond) * 1000).round().clamp(3000, 60000);
    _controller.duration = Duration(milliseconds: durationMs);
    if (!_isHovered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isHovered) return;
        _controller.repeat(min: 0.0, max: 1.0);
      });
    }
  }

  void _setHovered(bool hovered) {
    if (_isHovered == hovered) return;
    _isHovered = hovered;
    if (hovered) {
      _controller.stop(canceled: false);
    } else if (_unitWidth > 0) {
      _controller.repeat(min: 0.0, max: 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = constraints.maxWidth;
          if (!viewportWidth.isFinite || viewportWidth <= 0) {
            return const SizedBox.shrink();
          }

          final textWidth = _measureTextWidth(textScaler);
          _syncAnimation(viewportWidth, textWidth);

          final unitWidth = _unitWidth;
          final copies = math.max(2, (viewportWidth / unitWidth).ceil() + 2);

          return ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final shift = _controller.value * unitWidth;
                return Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    for (int i = 0; i < copies; i++)
                      Positioned(
                        left: (i * unitWidth) - shift,
                        top: 0,
                        bottom: 0,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: child!,
                        ),
                      ),
                  ],
                );
              },
              child: Text(
                widget.text,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
          );
        },
      ),
    );
  }
}
