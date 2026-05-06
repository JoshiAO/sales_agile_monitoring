import 'package:flutter/material.dart';

class LaunchValidationOfflineScreen extends StatelessWidget {
  final VoidCallback onRetry;
  final bool isRetrying;
  final String? message;

  const LaunchValidationOfflineScreen({
    super.key,
    required this.onRetry,
    required this.isRetrying,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
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
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.wifi_off_rounded,
                      color: Colors.white,
                      size: 52,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Unable To Validate Session',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      message ??
                          'Please connect to the internet and retry validation.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFE8E3FF),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton(
                        onPressed: isRetrying ? null : onRetry,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE6E1FD),
                          foregroundColor: const Color(0xFF3D356B),
                        ),
                        child: Text(isRetrying ? 'Validating...' : 'Retry'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
