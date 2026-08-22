import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';

class RouteCallDetailCard extends StatelessWidget {
  final String title;
  final RoutePoint point;
  final Widget imageWidget;
  final VoidCallback onOpenFullImage;
  final VoidCallback onOpenMaps;
  final VoidCallback onDataTap;
  final bool canApproveRetake;
  final VoidCallback? onApproveRetake;
  final String approveRetakeLabel;
  final String? placeholderMessage;

  const RouteCallDetailCard({
    super.key,
    required this.title,
    required this.point,
    required this.imageWidget,
    required this.onOpenFullImage,
    required this.onOpenMaps,
    required this.onDataTap,
    this.canApproveRetake = false,
    this.onApproveRetake,
    this.approveRetakeLabel = 'Approve Retake',
    this.placeholderMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: imageWidget,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: onOpenFullImage,
            icon: const Icon(Icons.open_in_full),
            label: const Text('Open Full Image'),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Location',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    '${point.lat.toStringAsFixed(4)}, ${point.lon.toStringAsFixed(4)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            ElevatedButton.icon(
              onPressed: onOpenMaps,
              icon: const Icon(Icons.location_on),
              label: const Text('Maps'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: onDataTap,
              icon: const Icon(Icons.data_usage),
              label: const Text('Data'),
            ),
          ],
        ),
        if (point.batteryLevel != null || point.appVersion != null) ...[
          const SizedBox(height: 8),
          Text('Device Telemetry', style: Theme.of(context).textTheme.bodySmall),
          Text(
            'App Ver: ${point.appVersion ?? 'N/A'} • Battery: ${point.batteryLevel != null ? '${point.batteryLevel}%' : 'N/A'}\n'
            'UUID: ${point.uuid ?? 'N/A'} • ${point.productName ?? 'Unknown'} ${point.modelName ?? 'Device'}'
            '${point.serialNumber != null ? ' • SN: ${point.serialNumber}' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Time',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  point.timestamp.toString().split('.').first,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ],
        ),
        if (canApproveRetake && onApproveRetake != null)
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: onApproveRetake,
              icon: const Icon(Icons.check),
              label: Text(approveRetakeLabel),
            ),
          ),
      ],
    );
  }
}
