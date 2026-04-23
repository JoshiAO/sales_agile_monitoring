import 'package:flutter/material.dart';
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
          ));
        },
      ),
    );
  }
}
