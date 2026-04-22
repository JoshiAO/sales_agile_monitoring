import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/screens/salesman/salesman_home_screen.dart';

class SalesmanTabsScreen extends StatefulWidget {
  const SalesmanTabsScreen({super.key});

  @override
  State<SalesmanTabsScreen> createState() => _SalesmanTabsScreenState();
}

class _SalesmanTabsScreenState extends State<SalesmanTabsScreen> {
  int _currentIndex = 0;

  late final List<Widget> _pages = [
    const SalesmanHomeScreen(),
    const _BlankRoleTab(title: 'Agile'),
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

class _BlankRoleTab extends StatelessWidget {
  final String title;

  const _BlankRoleTab({required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const SizedBox.expand(),
    );
  }
}
