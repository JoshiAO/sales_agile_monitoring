import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/activation_provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/providers/version_provider.dart';
import 'package:compact_sales_monitoring/services/background_location_service.dart';

/// Shown behind the AuthWaveRevealLayer curtain during launch validation.
/// If startup takes longer than 4 seconds, it reveals a visible spinner and
/// a self-recovery action so the user is never stranded on a blank dark violet
/// screen (`#1A1533`).
class LaunchValidationLoadingScreen extends StatefulWidget {
  const LaunchValidationLoadingScreen({super.key});

  @override
  State<LaunchValidationLoadingScreen> createState() =>
      _LaunchValidationLoadingScreenState();
}

class _LaunchValidationLoadingScreenState
    extends State<LaunchValidationLoadingScreen> {
  Timer? _slowStartupTimer;
  bool _showSlowStartupRecovery = false;
  bool _isRepairing = false;

  @override
  void initState() {
    super.initState();
    _slowStartupTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showSlowStartupRecovery = true);
      }
    });
  }

  @override
  void dispose() {
    _slowStartupTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleRepairStartup() async {
    if (_isRepairing) return;
    setState(() => _isRepairing = true);
    try {
      await BackgroundLocationService.repairAndSyncAppState().timeout(
        const Duration(seconds: 6),
        onTimeout: () => <String, dynamic>{},
      );
      if (!mounted) return;
      unawaited(context.read<ActivationProvider>().initialize());
      unawaited(context.read<VersionProvider>().checkVersion());
      unawaited(context.read<AuthProvider>().retryLaunchValidation());
    } finally {
      if (mounted) {
        setState(() => _isRepairing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1533),
      body: SafeArea(
        child: Center(
          child: AnimatedOpacity(
            opacity: _showSlowStartupRecovery ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: !_showSlowStartupRecovery,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFFE6E1FD),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Starting Sales Agile Monitoring...',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Verifying session and device state. Your login and activation are preserved.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFD0C9F2),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _isRepairing ? null : _handleRepairStartup,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE6E1FD),
                        foregroundColor: const Color(0xFF2F2A57),
                      ),
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: Text(
                        _isRepairing
                            ? 'Repairing Startup...'
                            : 'Repair & Retry Startup',
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
