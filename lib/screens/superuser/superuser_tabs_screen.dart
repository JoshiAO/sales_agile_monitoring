import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/screens/superuser/superuser_dashboard.dart';
import 'package:compact_sales_monitoring/screens/superuser/superuser_home_screen.dart';
import 'package:compact_sales_monitoring/screens/superuser/superuser_agile_page.dart';
import 'package:compact_sales_monitoring/screens/superuser/user_management_screen.dart';

class SuperuserTabsScreen extends StatefulWidget {
  const SuperuserTabsScreen({super.key});

  @override
  State<SuperuserTabsScreen> createState() => _SuperuserTabsScreenState();
}

class _SuperuserTabsScreenState extends State<SuperuserTabsScreen> {
  int _currentIndex = 0;
  DateTime _lastRefreshAt = DateTime.now();
  int _refreshTick = 0;

  List<Widget> _buildPages() {
    return [
      SuperuserHomeScreen(key: ValueKey('su-home-$_refreshTick')),
      SuperUserDashboard(key: ValueKey('su-map-$_refreshTick')),
      SuperuserAgilePage(key: ValueKey('su-agile-$_refreshTick')),
      UserManagementScreen(key: ValueKey('su-users-$_refreshTick')),
    ];
  }

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

  Stream<int> _newUploadsCountStream() {
    final baseline = _lastRefreshAt;
    return FirebaseFirestore.instance
        .collection('agile_submissions')
        .snapshots()
        .map((snapshot) {
          var count = 0;
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final submittedAt = data['submittedAt'];
            if (submittedAt is! Timestamp) continue;
            if (submittedAt.toDate().isAfter(baseline)) {
              count++;
            }
          }
          return count;
        });
  }

  Future<void> _handleRefresh() async {
    setState(() {
      _lastRefreshAt = DateTime.now();
      _refreshTick++;
    });
  }

  Widget _buildBadge(int count) {
    final hasNewData = count > 0;
    final background = hasNewData ? Colors.red : Colors.green;
    final text = count > 99 ? '99+' : '$count';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      constraints: const BoxConstraints(minWidth: 22),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildRefreshButton(bool isExpandedRail, int newCount) {
    return Builder(
      builder: (context) {
        if (!isExpandedRail) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IconButton(
              tooltip: 'Refresh',
              onPressed: _handleRefresh,
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.refresh),
                  Positioned(
                    top: -8,
                    right: -14,
                    child: _buildBadge(newCount),
                  ),
                ],
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
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
                icon: const Icon(Icons.refresh),
                label: Row(
                  children: [
                    const Expanded(child: Text('Refresh')),
                    _buildBadge(newCount),
                  ],
                ),
                onPressed: _handleRefresh,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = _buildPages();

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
                            NavigationRailDestination(
                              icon: Icon(Icons.manage_accounts_outlined),
                              selectedIcon: Icon(Icons.manage_accounts),
                              label: Text('Users'),
                            ),
                          ],
                        ),
                      ),
                      StreamBuilder<int>(
                        stream: _newUploadsCountStream(),
                        initialData: 0,
                        builder: (context, snapshot) {
                          return _buildRefreshButton(
                            isExpandedRail,
                            snapshot.data ?? 0,
                          );
                        },
                      ),
                      _buildLogoutButton(isExpandedRail),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: IndexedStack(index: _currentIndex, children: pages),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        backgroundColor: Theme.of(context).colorScheme.surface,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Colors.grey.shade700,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
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
          BottomNavigationBarItem(
            icon: Icon(Icons.manage_accounts_outlined),
            activeIcon: Icon(Icons.manage_accounts),
            label: 'Users',
          ),
        ],
      ),
    );
  }
}
