import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
  final Color accentColor;

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
    this.accentColor = const Color(0xFF0F766E),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formattedTime = DateFormat('hh:mm:ss a').format(point.timestamp);
    final hasDeviceBadges = (point.appVersion != null && point.appVersion!.isNotEmpty) ||
        point.productName != null ||
        point.modelName != null ||
        (point.uuid != null && point.uuid!.isNotEmpty);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Status Dot + Title + Timestamp Pill
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Colors.grey.shade900,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 13,
                      color: Colors.grey.shade700,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      formattedTime,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 50/50 Split:
          // Left 50%: Call Photo
          // Right 50%:
          //   Row 1: [Location] [Battery]
          //   Row 2: [Version] [Device] [UUID]
          //   Row 3: [Maps] [Data Usage]
          //   Row 4: [Open Full Image]
          SizedBox(
            height: 174,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left 50%: Call Photo
                Expanded(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onOpenFullImage,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          color: Colors.grey.shade100,
                          child: imageWidget,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Right 50%: Telemetry + Actions
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Row 1: [Location] [Battery]
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.location_on_outlined,
                                    size: 13.5,
                                    color: accentColor,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '${point.lat.toStringAsFixed(4)}, ${point.lon.toStringAsFixed(4)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade800,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (point.batteryLevel != null) ...[
                            const SizedBox(width: 6),
                            _TelemetryBadge(
                              icon: _batteryIcon(point.batteryLevel!),
                              label: '${point.batteryLevel}%',
                              iconColor: _batteryColor(point.batteryLevel!),
                              verticalPadding: 5,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Row 2: [Version] [Device] [UUID]
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: hasDeviceBadges
                              ? SingleChildScrollView(
                                  child: Wrap(
                                    spacing: 5,
                                    runSpacing: 5,
                                    children: [
                                      if (point.appVersion != null &&
                                          point.appVersion!.isNotEmpty)
                                        _TelemetryBadge(
                                          icon: Icons.apps_rounded,
                                          label: 'v${point.appVersion}',
                                        ),
                                      if (point.productName != null ||
                                          point.modelName != null)
                                        _TelemetryBadge(
                                          icon: Icons.tablet_android_rounded,
                                          label:
                                              '${point.productName ?? ''} ${point.modelName ?? ''}'
                                                  .trim(),
                                        ),
                                      if (point.uuid != null &&
                                          point.uuid!.isNotEmpty)
                                        Tooltip(
                                          message:
                                              'UUID: ${point.uuid}${point.serialNumber != null ? '\nSN: ${point.serialNumber}' : ''}',
                                          child: _TelemetryBadge(
                                            icon: Icons.fingerprint_rounded,
                                            label: point.uuid!.length > 8
                                                ? '${point.uuid!.substring(0, 8)}…'
                                                : point.uuid!,
                                          ),
                                        ),
                                    ],
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Row 3: [Maps] [Data Usage]
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 33,
                              child: FilledButton.tonalIcon(
                                onPressed: onOpenMaps,
                                icon: const Icon(Icons.map_outlined, size: 14),
                                label: const Text(
                                  'Maps',
                                  overflow: TextOverflow.ellipsis,
                                ),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: SizedBox(
                              height: 33,
                              child: FilledButton.tonalIcon(
                                onPressed: onDataTap,
                                icon: const Icon(
                                  Icons.data_usage_rounded,
                                  size: 14,
                                ),
                                label: const Text(
                                  'Data Usage',
                                  overflow: TextOverflow.ellipsis,
                                ),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Row 4: [Open Full Image]
                      SizedBox(
                        height: 33,
                        child: OutlinedButton.icon(
                          onPressed: onOpenFullImage,
                          icon: const Icon(
                            Icons.open_in_full_rounded,
                            size: 14,
                          ),
                          label: const Text(
                            'Open Full Image',
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            textStyle: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Retake Approval Banner
          if (canApproveRetake && onApproveRetake != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: Colors.amber.shade900,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Retake requested',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: onApproveRetake,
                    icon: const Icon(Icons.check_rounded, size: 15),
                    label: Text(approveRetakeLabel),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.amber.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      textStyle: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _batteryIcon(int level) {
    if (level >= 80) return Icons.battery_full_rounded;
    if (level >= 50) return Icons.battery_5_bar_rounded;
    if (level >= 25) return Icons.battery_3_bar_rounded;
    return Icons.battery_alert_rounded;
  }

  Color _batteryColor(int level) {
    if (level >= 50) return Colors.teal.shade700;
    if (level >= 25) return Colors.amber.shade800;
    return Colors.red.shade700;
  }
}

class _TelemetryBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? iconColor;
  final double verticalPadding;

  const _TelemetryBadge({
    required this.icon,
    required this.label,
    this.iconColor,
    this.verticalPadding = 3,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: verticalPadding),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: iconColor ?? Colors.grey.shade700),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }
}
