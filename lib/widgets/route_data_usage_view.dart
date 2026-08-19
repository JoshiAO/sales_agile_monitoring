import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';

class RouteDataUsageView extends StatefulWidget {
  final RoutePoint point;
  final VoidCallback onBack;

  const RouteDataUsageView({
    super.key,
    required this.point,
    required this.onBack,
  });

  @override
  State<RouteDataUsageView> createState() => _RouteDataUsageViewState();
}

class _RouteDataUsageViewState extends State<RouteDataUsageView> {
  int _selectedIndex = 0;

  Widget _buildDataTable(List<DataUsageEntry>? data) {
    if (data == null || data.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 16.0),
        child: Text('No data usage recorded.', style: TextStyle(color: Colors.grey)),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DataTable(
        headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
        columns: const [
          DataColumn(label: Text('App Name')),
          DataColumn(label: Text('Usage (MB)')),
          DataColumn(label: Text('%')),
        ],
        rows: data.map((item) {
          return DataRow(
            cells: [
              DataCell(Text(item.appName)),
              DataCell(Text(item.usageMB.toStringAsFixed(2))),
              DataCell(Text(item.percentage.toStringAsFixed(1))),
            ],
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 8),
            const Text(
              'Call Data Management',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Center(
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment<int>(value: 0, label: Text('Mobile Data')),
              ButtonSegment<int>(value: 1, label: Text('WiFi Data')),
            ],
            selected: {_selectedIndex},
            onSelectionChanged: (Set<int> newSelection) {
              setState(() {
                _selectedIndex = newSelection.first;
              });
            },
          ),
        ),
        const SizedBox(height: 16),
        if (_selectedIndex == 0)
          _buildDataTable(widget.point.mobileDataUsage)
        else
          _buildDataTable(widget.point.wifiDataUsage),
      ],
    );
  }
}
