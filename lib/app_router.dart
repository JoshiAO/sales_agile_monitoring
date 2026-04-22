import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/screens/login_screen.dart';

// Salesman screens
import 'package:compact_sales_monitoring/screens/salesman/salesman_tabs_screen.dart';

// Supervisor screens
import 'package:compact_sales_monitoring/screens/supervisor/supervisor_tabs_screen.dart';

// Super User screens
import 'package:compact_sales_monitoring/screens/superuser/superuser_tabs_screen.dart';

class AppRouter extends StatelessWidget {
  const AppRouter({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Not authenticated - show login
        if (!authProvider.isAuthenticated) {
          return const LoginScreen();
        }

        // Authenticated - route based on role
        final user = authProvider.currentUser!;

        switch (user.role) {
          case UserRole.salesman:
            return const SalesmanTabsScreen();
          case UserRole.supervisor:
            return const SupervisorTabsScreen();
          case UserRole.superuser:
            return const SuperuserTabsScreen();
        }
      },
    );
  }
}
