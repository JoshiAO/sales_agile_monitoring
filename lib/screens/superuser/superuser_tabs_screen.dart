import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/screens/superuser/superuser_dashboard.dart';
import 'package:compact_sales_monitoring/screens/superuser/superuser_home_screen.dart';
import 'package:compact_sales_monitoring/screens/superuser/superuser_agile_page.dart';

class SuperuserTabsScreen extends StatefulWidget {
  const SuperuserTabsScreen({super.key});

  @override
  State<SuperuserTabsScreen> createState() => _SuperuserTabsScreenState();
}

class _SuperuserTabsScreenState extends State<SuperuserTabsScreen> {
  int _currentIndex = 0;

  late final List<Widget> _pages = [
    const SuperuserHomeScreen(),
    const SuperUserDashboard(),
    const SuperuserAgilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
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

