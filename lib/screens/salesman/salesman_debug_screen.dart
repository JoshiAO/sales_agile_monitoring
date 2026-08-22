import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:flutter_background_service/flutter_background_service.dart';

class SalesmanDebugScreen extends StatefulWidget {
  const SalesmanDebugScreen({super.key});

  @override
  State<SalesmanDebugScreen> createState() => _SalesmanDebugScreenState();
}

class _SalesmanDebugScreenState extends State<SalesmanDebugScreen> {
  Timer? _timer;
  SharedPreferences? _prefs;
  
  String _activeTime = '00:00:00';
  int _checkpointCount = 0;
  String _lastSync = 'Pending';
  double? _lastLat;
  double? _lastLon;
  String _startTimeStr = 'Not started';
  List<Map<String, dynamic>> _pendingCheckpoints = [];
  Set<int> _pendingTimestamps = {};

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshData());
  }
  
  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _refreshData();
  }

  void _refreshData() {
    if (_prefs == null) return;
    _prefs!.reload(); // Ensure we get the latest background updates
    
    final startStr = _prefs!.getString('route_start_time');
    final endStr = _prefs!.getString('route_end_time');
    
    if (startStr != null) {
      final startTime = DateTime.parse(startStr);
      _startTimeStr = DateFormat('hh:mm a').format(startTime);
      
      final endTime = endStr != null ? DateTime.parse(endStr) : DateTime.now();
      final activeDuration = endTime.difference(startTime);
      
      final hours = activeDuration.inHours.toString().padLeft(2, '0');
      final minutes = (activeDuration.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (activeDuration.inSeconds % 60).toString().padLeft(2, '0');
      _activeTime = '$hours:$minutes:$seconds';
    } else {
      _activeTime = '00:00:00';
      _startTimeStr = 'Not started';
    }

    _checkpointCount = _prefs!.getInt('checkpoint_count') ?? 0;
    
    final lastFlushStr = _prefs!.getString('last_flush_time');
    if (lastFlushStr != null) {
      _lastSync = DateFormat('hh:mm a').format(DateTime.parse(lastFlushStr));
    } else {
      _lastSync = 'Pending';
    }

    _lastLat = _prefs!.getDouble('last_checkpoint_lat');
    _lastLon = _prefs!.getDouble('last_checkpoint_lon');

    final rawBatch = _prefs!.getStringList('session_checkpoints_history') ?? [];
    _pendingCheckpoints = rawBatch.map((e) {
      try {
        return jsonDecode(e) as Map<String, dynamic>;
      } catch (_) {
        return <String, dynamic>{};
      }
    }).where((e) => e.isNotEmpty).toList().reversed.toList();

    final rawPending = _prefs!.getStringList('batched_checkpoints_v2') ?? [];
    _pendingTimestamps = rawPending.map((e) {
      try {
        final map = jsonDecode(e) as Map<String, dynamic>;
        return map['timestamp'] as int?;
      } catch (_) {
        return null;
      }
    }).where((e) => e != null).cast<int>().toSet();

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('Live Tracker Dashboard'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Live Stopwatch Card
            Container(
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6750A4), Color(0xFF381E72)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6750A4).withOpacity(0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                children: [
                  const Text(
                    'ACTIVE DURATION',
                    style: TextStyle(
                      color: Colors.white70,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _activeTime,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 56,
                      fontWeight: FontWeight.w300,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            
            // Statistics Grid
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _buildStatCard(
                      icon: Icons.location_on_rounded,
                      title: 'Checkpoints',
                      value: '${_checkpointCount - _pendingTimestamps.length}',
                      color: Colors.blue.shade600,
                      badgeCount: _pendingTimestamps.length,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildStatCard(
                      icon: Icons.cloud_done_rounded,
                      title: 'Last Sync',
                      value: _lastSync,
                      color: Colors.green.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Detailed Info Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tracking Details',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildDetailRow('Start Time', _startTimeStr),
                  const Divider(height: 32),
                  _buildDetailRow('Last Lat', _lastLat?.toStringAsFixed(6) ?? 'N/A'),
                  const Divider(height: 32),
                  _buildDetailRow('Last Lon', _lastLon?.toStringAsFixed(6) ?? 'N/A'),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Capture Manual Checkpoint'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6750A4),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Capturing manual checkpoint...')),
                  );
                  FlutterBackgroundService().invoke('manual_checkpoint');
                },
              ),
            ),
            if (_pendingCheckpoints.isNotEmpty) ...[
              const SizedBox(height: 32),
              const Text(
                'Checkpoint History',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              ..._pendingCheckpoints.map((cp) {
                final lat = cp['lat'] as num?;
                final lon = cp['lon'] as num?;
                final ts = cp['timestamp'] as int?;
                final time = ts != null 
                    ? DateFormat('hh:mm:ss a').format(DateTime.fromMillisecondsSinceEpoch(ts))
                    : 'Unknown';
                final isPending = ts != null && _pendingTimestamps.contains(ts);
                final statusColor = isPending ? Colors.red : Colors.green;
                final statusText = isPending ? 'Pending' : 'Uploaded';
                final statusIcon = isPending ? Icons.cloud_upload : Icons.cloud_done;

                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: statusColor.withOpacity(0.3)),
                  ),
                  child: ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(statusIcon, color: statusColor, size: 20),
                    ),
                    title: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(time, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                          statusText,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Text('Lat: ${lat?.toStringAsFixed(5)}, Lon: ${lon?.toStringAsFixed(5)}'),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
    int? badgeCount,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.1),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Badge(
            isLabelVisible: badgeCount != null && badgeCount > 0,
            label: Text(badgeCount?.toString() ?? ''),
            backgroundColor: Colors.red.shade700,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 24),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
