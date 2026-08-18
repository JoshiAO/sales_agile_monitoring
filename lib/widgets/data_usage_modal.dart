import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';

class DataUsageModal extends StatelessWidget {
  final RoutePoint point;

  const DataUsageModal({super.key, required this.point});

  Widget _buildDataTable(String title, List<dynamic>? data) {
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
                  DataCell(Text(item['appName']?.toString() ?? 'Unknown')),
                  DataCell(Text(item['usageMB']?.toString() ?? '0')),
                  DataCell(Text(item['index']?.toString() ?? '0')),
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogWidth = (screenWidth * 0.8).clamp(320.0, 800.0);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: dialogWidth, maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  const Text('Call Data Management', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDataTable('Mobile Data Usage', point.mobileDataUsage),
                    const SizedBox(height: 24),
                    _buildDataTable('WiFi Data Usage', point.wifiDataUsage),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
