import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';

class RouteDataUsageView extends StatelessWidget {
  final RoutePoint point;
  final VoidCallback onBack;

  const RouteDataUsageView({
    super.key,
    required this.point,
    required this.onBack,
  });

  Widget _buildDataTable(String title, List<DataUsageEntry>? data) {
    if (data == null || data.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          const Text('No data usage recorded.'),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        Container(
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
        ),
      ],
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
              onPressed: onBack,
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
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _buildDataTable('Mobile Data Usage', point.mobileDataUsage),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: _buildDataTable('WiFi Data Usage', point.wifiDataUsage),
            ),
          ],
        ),
      ],
    );
  }
}
