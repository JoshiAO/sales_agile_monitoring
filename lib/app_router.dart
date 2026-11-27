import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/providers/activation_provider.dart';
import 'package:compact_sales_monitoring/providers/company_branding_provider.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/screens/activation_screen.dart';
import 'package:compact_sales_monitoring/screens/login_screen.dart';
import 'package:compact_sales_monitoring/screens/launch_validation_loading_screen.dart';
import 'package:compact_sales_monitoring/screens/launch_validation_offline_screen.dart';
import 'package:compact_sales_monitoring/screens/force_update_screen.dart';
import 'package:compact_sales_monitoring/providers/version_provider.dart';
import 'package:compact_sales_monitoring/widgets/auth_wave_transition_overlay.dart';

// Salesman screens
import 'package:compact_sales_monitoring/screens/salesman/salesman_tabs_screen.dart';

// Supervisor screens
import 'package:compact_sales_monitoring/screens/supervisor/supervisor_tabs_screen.dart';

// Super User screens
import 'package:compact_sales_monitoring/screens/superuser/superuser_tabs_screen.dart';

// Manager screens
import 'package:compact_sales_monitoring/screens/manager/manager_tabs_screen.dart';

// Encoder screens
import 'package:compact_sales_monitoring/screens/encoder/encoder_tabs_screen.dart';

class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  Widget? _frozenBaseDuringLoading;
  Widget? _lastStableBase;

  String _baseKeyFor(Widget base) {
    if (base is ActivationScreen) return 'activation';
    if (base is LoginScreen) return 'login';
    if (base is SalesmanTabsScreen) return 'salesman';
    if (base is SupervisorTabsScreen) return 'supervisor';
    if (base is ManagerTabsScreen) return 'manager';
    if (base is EncoderTabsScreen) return 'encoder';
    if (base is SuperuserTabsScreen) return 'superuser';
    if (base is Scaffold) return 'loading';
    return base.runtimeType.toString();
  }

  Widget _resolveBase(
    AuthProvider authProvider,
    ActivationProvider activationProvider,
    VersionProvider versionProvider,
  ) {
    if (versionProvider.isChecking || activationProvider.isChecking || authProvider.isInitializing) {
      return const LaunchValidationLoadingScreen();
    }

    if (versionProvider.isOutdated) {
      return ForceUpdateScreen(downloadUrl: versionProvider.downloadUrl);
    }

    if (authProvider.requiresLaunchRetry) {
      return LaunchValidationOfflineScreen(
        onRetry: () => authProvider.retryLaunchValidation(),
        isRetrying: authProvider.isInitializing,
        message: authProvider.launchRetryMessage,
      );
    }

    if (!activationProvider.isActivated) {
      return const ActivationScreen();
    }

    if (authProvider.isAuthenticated) {
      switch (authProvider.currentUser!.role) {
        case UserRole.salesman:
          return const SalesmanTabsScreen();
        case UserRole.supervisor:
          return const SupervisorTabsScreen();
        case UserRole.manager:
          return const ManagerTabsScreen();
        case UserRole.encoder:
          return const EncoderTabsScreen();
        case UserRole.superuser:
          return const SuperuserTabsScreen();
      }
    }

    return const LoginScreen();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer3<AuthProvider, ActivationProvider, VersionProvider>(
      builder: (context, authProvider, activationProvider, versionProvider, _) {
        final resolvedBase = _resolveBase(authProvider, activationProvider, versionProvider);
        final Widget base;

        if (authProvider.isLoading && activationProvider.isActivated) {
          // Freeze the previous stable screen while the entrance cover animates.
          _frozenBaseDuringLoading ??= _lastStableBase ?? resolvedBase;
          base = _frozenBaseDuringLoading!;
        } else {
          _frozenBaseDuringLoading = null;
          _lastStableBase = resolvedBase;
          base = resolvedBase;
        }

        final baseKey = _baseKeyFor(base);
        final logoUrl = context.watch<CompanyBrandingProvider>().branding?.logoUrl;

        // The wave layer sits on top and manages its own enter/exit lifecycle.
        // When auth loading ends it plays the curtain-reveal, then disappears.
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 340),
              reverseDuration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    ...?(currentChild == null ? null : [currentChild]),
                  ],
                );
              },
              transitionBuilder: (child, animation) {
                final isIncoming = child.key == ValueKey<String>(baseKey);
                final tween = Tween<Offset>(
                  begin: isIncoming ? const Offset(1, 0) : Offset.zero,
                  end: isIncoming ? Offset.zero : const Offset(-0.14, 0),
                );

                return SlideTransition(
                  position: animation.drive(tween),
                  child: child,
                );
              },
              child: KeyedSubtree(key: ValueKey<String>(baseKey), child: base),
            ),
            // Show the wave curtain during:
            //  - launch validation   (isInitializing)
            //  - activation check    (isChecking)
            //  - version check       (isChecking)
            //  - login / logout      (isLoading, only when already activated)
            if (activationProvider.isActivated ||
                activationProvider.isChecking ||
                versionProvider.isChecking ||
                authProvider.isInitializing)
              AuthWaveRevealLayer(
                isAuthLoading: activationProvider.isChecking ||
                    versionProvider.isChecking ||
                    authProvider.isInitializing ||
                    (authProvider.isLoading && activationProvider.isActivated),
                logoUrl: logoUrl,
              ),
          ],
        );
      },
    );
  }
}
