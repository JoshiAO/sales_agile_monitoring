import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/company_branding_provider.dart';
import 'package:compact_sales_monitoring/widgets/modular_splash_screen.dart';

class SplashScreen extends StatelessWidget {
  final VoidCallback onComplete;

  const SplashScreen({
    super.key,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<CompanyBrandingProvider>(
      builder: (context, brandingProvider, _) {
        final branding = brandingProvider.branding;
        return ModularSplashScreen(
          onComplete: onComplete,
          config: ModularSplashConfig(
            title: branding?.tagline ?? 'JoshiAO Project',
            logoAssetPath: 'assets/images/JoshiAO.jpg',
            logoUrl: branding?.logoUrl,
            backgroundTop: const Color(0xFF1A1533),
            backgroundMid: const Color(0xFF26204A),
            backgroundBottom: const Color(0xFF32295A),
            logoSize: 180,
            logoRadius: 28,
            titleSize: 30,
            totalDuration: const Duration(milliseconds: 2400),
          ),
        );
      },
    );
  }
}
