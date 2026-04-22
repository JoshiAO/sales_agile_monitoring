import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/widgets/modular_splash_screen.dart';

class SplashScreen extends StatelessWidget {
  final VoidCallback onComplete;

  const SplashScreen({
    super.key,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    return ModularSplashScreen(
      onComplete: onComplete,
      config: const ModularSplashConfig(
        title: 'JoshiAO Project',
        logoAssetPath: 'assets/images/JoshiAO.jpg',
        backgroundTop: Color(0xFF1A1533),
        backgroundMid: Color(0xFF26204A),
        backgroundBottom: Color(0xFF32295A),
        logoSize: 180,
        logoRadius: 28,
        titleSize: 30,
        totalDuration: Duration(milliseconds: 2400),
      ),
    );
  }
}
