import 'dart:math';

import 'package:flutter/material.dart';

class ModularSplashConfig {
  const ModularSplashConfig({
    required this.title,
    required this.logoAssetPath,
    this.backgroundTop = const Color(0xFF1A1533),
    this.backgroundMid = const Color(0xFF26204A),
    this.backgroundBottom = const Color(0xFF32295A),
    this.logoSize = 180,
    this.logoRadius = 28,
    this.titleSize = 30,
    this.totalDuration = const Duration(milliseconds: 2400),
  });

  final String title;
  final String logoAssetPath;
  final Color backgroundTop;
  final Color backgroundMid;
  final Color backgroundBottom;
  final double logoSize;
  final double logoRadius;
  final double titleSize;
  final Duration totalDuration;
}

class ModularSplashScreen extends StatefulWidget {
  const ModularSplashScreen({
    super.key,
    required this.onComplete,
    required this.config,
  });

  final VoidCallback onComplete;
  final ModularSplashConfig config;

  @override
  State<ModularSplashScreen> createState() => _ModularSplashScreenState();
}

class _ModularSplashScreenState extends State<ModularSplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoController;
  late final AnimationController _titleController;
  late final AnimationController _waveController;
  late final AnimationController _exitController;

  late final Animation<double> _logoScale;
  late final Animation<double> _logoFade;
  late final Animation<double> _logoReveal;
  late final Animation<double> _silhouetteFade;

  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );
    _titleController = AnimationController(
      duration: const Duration(milliseconds: 1700),
      vsync: this,
    )..repeat(reverse: true);
    _waveController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();
    _exitController = AnimationController(
      duration: const Duration(milliseconds: 1),
      vsync: this,
    );

    _logoScale = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeIn),
    );
    _logoReveal = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.35, 1.0, curve: Curves.easeOut),
      ),
    );
    _silhouetteFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.25, 1.0, curve: Curves.easeOut),
      ),
    );

    _logoController.forward();
    _startExitSequence();
  }

  Future<void> _startExitSequence() async {
    await Future<void>.delayed(widget.config.totalDuration);
    if (!mounted) return;
    await _exitController.forward();
    if (!mounted) return;
    widget.onComplete();
  }

  @override
  void dispose() {
    _logoController.dispose();
    _titleController.dispose();
    _waveController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: AnimatedBuilder(
        animation: Listenable.merge([_waveController, _exitController]),
        builder: (context, child) {
          final exitValue = Curves.easeInOut.transform(_exitController.value);
          return Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      widget.config.backgroundTop,
                      widget.config.backgroundMid,
                      widget.config.backgroundBottom,
                    ],
                  ),
                ),
              ),
              CustomPaint(
                painter: _WavyExitPainter(
                  phase: _waveController.value,
                  progress: exitValue,
                  colorA: scheme.primary.withValues(alpha: 0.20),
                  colorB: scheme.secondary.withValues(alpha: 0.16),
                  colorC: scheme.tertiary.withValues(alpha: 0.14),
                ),
              ),
              SafeArea(
                child: Center(
                  child: Transform.translate(
                    offset: Offset(0, 0),
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _logoScale,
              child: FadeTransition(
                opacity: _logoFade,
                child: Container(
                  width: widget.config.logoSize,
                  height: widget.config.logoSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.config.logoRadius),
                    boxShadow: [
                      const BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 22,
                        offset: Offset(0, 10),
                      ),
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.38),
                        blurRadius: 42,
                        spreadRadius: 3,
                      ),
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .secondary
                            .withValues(alpha: 0.24),
                        blurRadius: 70,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.config.logoRadius),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FadeTransition(
                          opacity: _logoReveal,
                          child: Image.asset(
                            widget.config.logoAssetPath,
                            fit: BoxFit.cover,
                          ),
                        ),
                        FadeTransition(
                          opacity: _silhouetteFade,
                          child: ColorFiltered(
                            colorFilter: const ColorFilter.mode(
                              Color(0xE6000000),
                              BlendMode.srcATop,
                            ),
                            child: Image.asset(
                              widget.config.logoAssetPath,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            AnimatedBuilder(
              animation: _titleController,
              builder: (context, _) {
                final glow = 3 + (7 * _titleController.value);
                return ShaderMask(
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        scheme.primary,
                        scheme.tertiary,
                        scheme.secondary,
                      ],
                    ).createShader(bounds);
                  },
                  child: Text(
                    widget.config.title,
                    style: TextStyle(
                      fontSize: widget.config.titleSize,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          color: Colors.white.withValues(alpha: 0.24),
                          blurRadius: 10,
                          offset: const Offset(0, 0),
                        ),
                        Shadow(
                          color: scheme.primary.withValues(alpha: 0.55),
                          blurRadius: glow,
                          offset: const Offset(0, 1),
                        ),
                        Shadow(
                          color: scheme.secondary.withValues(alpha: 0.40),
                          blurRadius: glow + 8,
                          offset: const Offset(0, 0),
                        ),
                        Shadow(
                          color: scheme.tertiary.withValues(alpha: 0.28),
                          blurRadius: glow + 14,
                          offset: const Offset(0, 0),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _WavyExitPainter extends CustomPainter {
  _WavyExitPainter({
    required this.phase,
    required this.progress,
    required this.colorA,
    required this.colorB,
    required this.colorC,
  });

  final double phase;
  final double progress;
  final Color colorA;
  final Color colorB;
  final Color colorC;

  @override
  void paint(Canvas canvas, Size size) {
    _drawWave(
      canvas,
      size,
      waveHeight: 18 + (22 * progress),
      yShift: size.height * (0.70 - 0.35 * progress),
      speed: 1.0,
      color: colorA,
    );
    _drawWave(
      canvas,
      size,
      waveHeight: 24 + (18 * progress),
      yShift: size.height * (0.78 - 0.30 * progress),
      speed: 1.5,
      color: colorB,
    );
    _drawWave(
      canvas,
      size,
      waveHeight: 14 + (14 * progress),
      yShift: size.height * (0.84 - 0.24 * progress),
      speed: 2.0,
      color: colorC,
    );
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
    final width = size.width;

    for (double x = 0; x <= width; x += 1) {
      final y = yShift +
          waveHeight *
              (0.5 +
                  0.5 *
                      (sin((x / width * 2 * pi) + (phase * 2 * pi * speed))));
      path.lineTo(x, y);
    }

    path
      ..lineTo(width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavyExitPainter oldDelegate) {
    return oldDelegate.phase != phase || oldDelegate.progress != progress;
  }
}
