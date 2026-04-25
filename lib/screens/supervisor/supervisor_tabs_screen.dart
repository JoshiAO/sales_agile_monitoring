import 'package:flutter/material.dart';
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

