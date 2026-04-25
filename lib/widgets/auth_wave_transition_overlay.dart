import 'dart:math';

import 'package:flutter/material.dart';

/// Full-screen animated wave overlay that sits on TOP of the destination
/// screen.  It fades in when auth loading starts, then plays a curtain-reveal
/// exit (top half slides up / bottom half slides down) when loading finishes —
/// elegantly uncovering the page that was already rendered beneath it.
class AuthWaveRevealLayer extends StatefulWidget {
  final bool isAuthLoading;
  const AuthWaveRevealLayer({super.key, required this.isAuthLoading});

  @override
  State<AuthWaveRevealLayer> createState() => _AuthWaveRevealLayerState();
}

class _AuthWaveRevealLayerState extends State<AuthWaveRevealLayer>
    with TickerProviderStateMixin {
  // Continuously loops to drive wave movement.
  late final AnimationController _waveLoop;
  // 0 → 1: top descends from above and bottom rises from below.
  late final AnimationController _coverIn;
  // 0 → 1: drives the curtain-reveal exit (panels split apart).
  late final AnimationController _reveal;

  bool _visible = false;
  bool _exiting = false;
  late final AssetImage _logoImage;

  @override
  void initState() {
    super.initState();
    _logoImage = const AssetImage('assets/images/JoshiAO.jpg');

    _waveLoop = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    );
    _coverIn = AnimationController(
      duration: const Duration(milliseconds: 560),
      vsync: this,
    );
    _reveal = AnimationController(
      duration: const Duration(milliseconds: 860),
      vsync: this,
    );

    if (widget.isAuthLoading) _show();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Avoid first-frame decode stutter when logo appears in the transition.
    precacheImage(_logoImage, context);
  }

  @override
  void didUpdateWidget(AuthWaveRevealLayer old) {
    super.didUpdateWidget(old);
    if (!old.isAuthLoading && widget.isAuthLoading) {
      _show();
    } else if (old.isAuthLoading && !widget.isAuthLoading && _visible) {
      _startReveal();
    }
  }

  // Show overlay and play entrance from top/bottom edges into center.
  void _show() {
    _coverIn.stop();
    _coverIn.reset();
    _reveal.stop();
    _reveal.reset();
    setState(() {
      _visible = true;
      _exiting = false;
    });
    _waveLoop.repeat();
    _coverIn.forward(from: 0);
  }

  // Play curtain-reveal, then hide completely.
  Future<void> _startReveal() async {
    if (!_visible || _exiting) return;
    setState(() => _exiting = true);

    // If loading ended before entrance completed, finish the entrance first.
    if (_coverIn.value < 1) {
      await _coverIn.forward();
    }

    await _reveal.forward(from: 0);
    if (mounted) {
      setState(() {
        _visible = false;
        _exiting = false;
      });
      _waveLoop.stop();
      _coverIn.reset();
      _reveal.reset();
    }
  }

  @override
  void dispose() {
    _waveLoop.dispose();
    _coverIn.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: Listenable.merge([_waveLoop, _coverIn, _reveal]),
      builder: (context, _) {
        final size = MediaQuery.sizeOf(context);
        final halfH = size.height / 2;

        final coverT = Curves.easeOutCubic.transform(_coverIn.value);
        // Ease-out so curtain snaps open fast, eases to complete.
        final revealT = Curves.easeOutQuart.transform(_reveal.value);

        final topInPosition = -halfH + (halfH * coverT);
        final bottomInPosition = -halfH + (halfH * coverT);
        final logoDx = (80 * (1 - coverT)) + (-80 * revealT);
        final logoRotation = (0.12 * (1 - coverT)) + (-0.12 * revealT);
        final logoScale = 0.94 + (0.06 * coverT);
        final logoOpacity = coverT * (1 - revealT);

        // Wave panel content (drawn once, used for both halves).
        final wavePanel = Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF1A1533),
                    Color(0xFF26204A),
                    Color(0xFF32295A),
                  ],
                ),
              ),
            ),
            CustomPaint(
              painter: _WavePainter(
                phase: _waveLoop.value,
                colorA: scheme.primary.withValues(alpha: 0.26),
                colorB: scheme.secondary.withValues(alpha: 0.20),
                colorC: scheme.tertiary.withValues(alpha: 0.16),
              ),
            ),
          ],
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // Top enters from above, then exits upward on reveal.
            Positioned(
              left: 0,
              right: 0,
              top: topInPosition - (revealT * (halfH + 80)),
              height: halfH,
              child: ClipRect(
                child: Transform.scale(
                  scaleY: -1,
                  child: SizedBox.expand(child: wavePanel),
                ),
              ),
            ),

            // Bottom enters from below, then exits downward on reveal.
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomInPosition - (revealT * (halfH + 80)),
              height: halfH,
              child: ClipRect(
                child: SizedBox.expand(child: wavePanel),
              ),
            ),

            Center(
              child: Opacity(
                opacity: logoOpacity.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(logoDx, 0),
                  child: Transform.rotate(
                    angle: logoRotation,
                    child: Transform.scale(
                      scale: logoScale,
                      child: Container(
                        width: 116,
                        height: 116,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            const BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 12,
                              offset: Offset(0, 10),
                            ),
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.34),
                              blurRadius: 16,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Image(
                            image: _logoImage,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.low,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Painter ────────────────────────────────────────────────────────────────

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.phase,
    required this.colorA,
    required this.colorB,
    required this.colorC,
  });

  final double phase;
  final Color colorA;
  final Color colorB;
  final Color colorC;

  @override
  void paint(Canvas canvas, Size size) {
    // Three overlapping waves spread across the full screen height.
    _drawWave(canvas, size, waveHeight: 50, yShift: size.height * 0.28, speed: 1.05, color: colorA);
    _drawWave(canvas, size, waveHeight: 64, yShift: size.height * 0.46, speed: 1.65, color: colorB);
    _drawWave(canvas, size, waveHeight: 40, yShift: size.height * 0.63, speed: 2.25, color: colorC);
  }

  void _drawWave(
    Canvas canvas,
    Size size, {
    required double waveHeight,
    required double yShift,
    required double speed,
    required Color color,
  }) {
    final paint = Paint()..color = color;
    final path = Path()..moveTo(0, yShift);
    for (double x = 0; x <= size.width; x += 2) {
      path.lineTo(
        x,
        yShift + waveHeight * (0.5 + 0.5 * sin((x / size.width * 2 * pi) + phase * 2 * pi * speed)),
      );
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase ||
      old.colorA != colorA ||
      old.colorB != colorB ||
      old.colorC != colorC;
}
