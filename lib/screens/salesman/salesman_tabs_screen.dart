import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/screens/salesman/salesman_home_screen.dart';
import 'package:compact_sales_monitoring/widgets/agile_call_form_card.dart';


class SalesmanTabsScreen extends StatefulWidget {
  const SalesmanTabsScreen({super.key});

  @override
  State<SalesmanTabsScreen> createState() => _SalesmanTabsScreenState();
}

class _SalesmanTabsScreenState extends State<SalesmanTabsScreen> {
  int _currentIndex = 0;

  late final List<Widget> _pages = [
    const SalesmanHomeScreen(),
    const _AgileTab(),
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
          final isExpandedRail = constraints.maxWidth >= 1180;
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
                          minExtendedWidth: 210,
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.co_present_outlined),
                              selectedIcon: Icon(Icons.co_present),
                              label: Text('Calls'),
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
            icon: Icon(Icons.co_present_outlined),
            activeIcon: Icon(Icons.co_present),
            label: 'Calls',
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

class _AgileTab extends StatelessWidget {
  const _AgileTab();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agile')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final maxContentWidth = constraints.maxWidth >= 900 ? 760.0 : 680.0;

          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth),
              child: SizedBox(
                height: constraints.maxHeight,
                child: const AgileCallFormCard(),
              ),
            ),
          );
        },
      ),
    );
  }
}
