import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/screens/login_screen.dart';
import 'package:compact_sales_monitoring/widgets/auth_wave_transition_overlay.dart';

// Salesman screens
import 'package:compact_sales_monitoring/screens/salesman/salesman_tabs_screen.dart';

// Supervisor screens
import 'package:compact_sales_monitoring/screens/supervisor/supervisor_tabs_screen.dart';

// Super User screens
import 'package:compact_sales_monitoring/screens/superuser/superuser_tabs_screen.dart';

class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  Widget? _frozenBaseDuringLoading;
  Widget? _lastStableBase;

  Widget _resolveBase(AuthProvider authProvider) {
    if (authProvider.isAuthenticated) {
      switch (authProvider.currentUser!.role) {
        case UserRole.salesman:
          return const SalesmanTabsScreen();
        case UserRole.supervisor:
          return const SupervisorTabsScreen();
        case UserRole.superuser:
          return const SuperuserTabsScreen();
      }
    }

    return const LoginScreen();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final resolvedBase = _resolveBase(authProvider);
        final Widget base;

        if (authProvider.isLoading) {
          // Freeze the previous stable screen while the entrance cover animates.
          _frozenBaseDuringLoading ??= _lastStableBase ?? resolvedBase;
          base = _frozenBaseDuringLoading!;
        } else {
          _frozenBaseDuringLoading = null;
          _lastStableBase = resolvedBase;
          base = resolvedBase;
        }

        // The wave layer sits on top and manages its own enter/exit lifecycle.
        // When auth loading ends it plays the curtain-reveal, then disappears.
        return Stack(
          fit: StackFit.expand,
          children: [
            base,
            AuthWaveRevealLayer(isAuthLoading: authProvider.isLoading),
          ],
        );
      },
    );
  }
}
