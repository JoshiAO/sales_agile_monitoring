import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/screens/supervisor/supervisor_dashboard.dart';
import 'package:compact_sales_monitoring/screens/supervisor/supervisor_home_screen.dart';
import 'package:compact_sales_monitoring/screens/supervisor/supervisor_agile_page.dart';

class SupervisorTabsScreen extends StatefulWidget {
  const SupervisorTabsScreen({super.key});

  @override
  State<SupervisorTabsScreen> createState() => _SupervisorTabsScreenState();
}

class _SupervisorTabsScreenState extends State<SupervisorTabsScreen> {
  int _currentIndex = 0;

  late final List<Widget> _pages = [
    const SupervisorHomeScreen(),
    const SupervisorDashboard(),
    const SupervisorAgilePage(),
  ];

  Widget _buildMenuHeader(bool isExpandedRail) {
    if (!isExpandedRail) {
      return const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 16),
        child: Tooltip(
          message: 'Sales Agile Monitoring\nCreated by: Joshua A. Ocampo',
          child: Icon(Icons.dashboard_customize_outlined),
        ),
      );
    }

    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 16, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sales Agile Monitoring',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 4),
          Text(
            'Created by: Joshua A. Ocampo',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutButton(bool isExpandedRail) {
    return Builder(
      builder: (context) {
        if (!isExpandedRail) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: IconButton(
              tooltip: 'Logout',
              icon: const Icon(Icons.logout),
              onPressed: () => context.read<AuthProvider>().logout(),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: SizedBox(
            width: 172,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(172, 40),
                  maximumSize: const Size(172, 40),
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.logout),
                label: const Text('Logout'),
                onPressed: () => context.read<AuthProvider>().logout(),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final isExpandedRail = constraints.maxWidth >= 1450;
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Expanded(
                        child: NavigationRail(
                          selectedIndex: _currentIndex,
                          onDestinationSelected: (index) =>
                              setState(() => _currentIndex = index),
                          leading: _buildMenuHeader(isExpandedRail),
                          extended: isExpandedRail,
                          labelType: NavigationRailLabelType.none,
                          minWidth: 68,
                          minExtendedWidth: 196,
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.home_outlined),
                              selectedIcon: Icon(Icons.home),
                              label: Text('Home'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.map_outlined),
                              selectedIcon: Icon(Icons.map),
                              label: Text('Map'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.auto_graph_outlined),
                              selectedIcon: Icon(Icons.auto_graph),
                              label: Text('Agile'),
                            ),
                          ],
                        ),
                      ),
                      _buildLogoutButton(isExpandedRail),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: IndexedStack(index: _currentIndex, children: _pages),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_graph_outlined),
            activeIcon: Icon(Icons.auto_graph),
            label: 'Agile',
          ),
        ],
      ),
    );
  }
}
