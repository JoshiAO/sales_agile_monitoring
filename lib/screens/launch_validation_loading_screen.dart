import 'package:flutter/material.dart';

/// Shown behind the AuthWaveRevealLayer curtain during launch validation.
/// The curtain covers this entirely — this screen just provides the matching
/// dark background so there is no colour flash if the curtain hasn't fully
/// painted yet.
class LaunchValidationLoadingScreen extends StatelessWidget {
  const LaunchValidationLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF1A1533),
      body: SizedBox.shrink(),
    );
  }
}
