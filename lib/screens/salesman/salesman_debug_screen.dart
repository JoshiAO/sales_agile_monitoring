import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../../services/background_location_service.dart';

class SalesmanDebugScreen extends StatefulWidget {
  const SalesmanDebugScreen({super.key});

  @override
  State<SalesmanDebugScreen> createState() => _SalesmanDebugScreenState();
}

class _SalesmanDebugScreenState extends State<SalesmanDebugScreen> {
  Timer? _timer;
  SharedPreferences? _prefs;
  bool _isRepairing = false;
  
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

    final rawPending = _prefs!.getStringList('batched_checkpoints_v2') ?? [];
    final pendingByTimestamp = <int, Map<String, dynamic>>{};
    for (final raw in rawPending) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final ts = map['timestamp'] as int?;
        if (ts != null) {
          pendingByTimestamp[ts] = map;
        }
      } catch (_) {}
    }
    _pendingTimestamps = pendingByTimestamp.keys.toSet();

    // Merge session_checkpoints_history and batched_checkpoints_v2 deduplicated
    // by timestamp so no checkpoint is ever missing from the history list.
    final rawBatch = _prefs!.getStringList('session_checkpoints_history') ?? [];
    final mergedCheckpointsByTs = <int, Map<String, dynamic>>{};
    for (final raw in rawBatch) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final ts = map['timestamp'] as int?;
        if (ts != null) {
          mergedCheckpointsByTs[ts] = map;
        }
      } catch (_) {}
    }
    for (final entry in pendingByTimestamp.entries) {
      mergedCheckpointsByTs.putIfAbsent(entry.key, () => entry.value);
    }

    final sortedMiddleCheckpoints = mergedCheckpointsByTs.values.toList()
      ..sort(
        (a, b) => ((a['timestamp'] as int?) ?? 0)
            .compareTo((b['timestamp'] as int?) ?? 0),
      );

    final fullTimeline = <Map<String, dynamic>>[];

    // 1. First Call (at the start of the timeline)
    final rawPendingFirstCall = _prefs!.getString('pending_first_call_v2');
    bool addedFirstCall = false;
    if (rawPendingFirstCall != null && rawPendingFirstCall.isNotEmpty) {
      try {
        final map = jsonDecode(rawPendingFirstCall) as Map<String, dynamic>;
        fullTimeline.add({
          'isFirstCall': true,
          'isPending': true,
          'lat': map['lat'],
          'lon': map['lon'],
          'timestamp': map['locationTime'],
        });
        addedFirstCall = true;
      } catch (_) {}
    }

    if (!addedFirstCall) {
      final firstTimeStr = _prefs!.getString('first_point_time');
      if (firstTimeStr != null) {
        try {
          final firstTime = DateTime.parse(firstTimeStr);
          final firstLat = _prefs!.getDouble('first_point_lat') ??
              _prefs!.getDouble('last_checkpoint_lat');
          final firstLon = _prefs!.getDouble('first_point_lon') ??
              _prefs!.getDouble('last_checkpoint_lon');
          fullTimeline.add({
            'isFirstCall': true,
            'isPending': false,
            'lat': firstLat,
            'lon': firstLon,
            'timestamp': firstTime.millisecondsSinceEpoch,
          });
          addedFirstCall = true;
        } catch (_) {}
      }
    }

    if (!addedFirstCall) {
      final rawCachedFirst = _prefs!.getString('active_first_call_cache_v1');
      if (rawCachedFirst != null && rawCachedFirst.isNotEmpty) {
        try {
          final cacheMap = jsonDecode(rawCachedFirst) as Map<String, dynamic>;
          final fp = cacheMap['firstPoint'] as Map<String, dynamic>?;
          if (fp != null) {
            final tsValue = fp['timestamp'];
            int? tsMs;
            if (tsValue is int) {
              tsMs = tsValue;
            } else if (tsValue is String) {
              tsMs = DateTime.tryParse(tsValue)?.millisecondsSinceEpoch;
            }
            fullTimeline.add({
              'isFirstCall': true,
              'isPending': false,
              'lat': fp['lat'],
              'lon': fp['lon'],
              'timestamp': tsMs,
            });
            addedFirstCall = true;
          }
        } catch (_) {}
      }
    }

    // 2. All Intermediate Route Checkpoints (Checkpoint #1 .. #N)
    for (int i = 0; i < sortedMiddleCheckpoints.length; i++) {
      final cp = Map<String, dynamic>.from(sortedMiddleCheckpoints[i]);
      cp['checkpointNumber'] = i + 1;
      fullTimeline.add(cp);
    }

    // 3. Last Call (at the end of the timeline, if completed)
    final lastTimeStr = _prefs!.getString('last_point_time');
    if (lastTimeStr != null) {
      try {
        final lastTime = DateTime.parse(lastTimeStr);
        fullTimeline.add({
          'isLastCall': true,
          'isPending': false,
          'lat': _prefs!.getDouble('last_point_lat'),
          'lon': _prefs!.getDouble('last_point_lon'),
          'timestamp': lastTime.millisecondsSinceEpoch,
        });
      } catch (_) {}
    }

    _pendingCheckpoints = fullTimeline;
    if (_checkpointCount < sortedMiddleCheckpoints.length) {
      _checkpointCount = sortedMiddleCheckpoints.length;
    }

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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                icon: _isRepairing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
                label: Text(
                  _isRepairing
                      ? 'Syncing & Repairing...'
                      : 'Repair & Sync App State',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF6750A4),
                  side: const BorderSide(color: Color(0xFF6750A4), width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: _isRepairing
                    ? null
                    : () async {
                        setState(() => _isRepairing = true);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final result =
                              await BackgroundLocationService.repairAndSyncAppState();
                          if (!mounted) return;
                          _refreshData();
                          final online = result['online'] == true;
                          final remaining =
                              result['remainingCheckpoints'] as int? ?? 0;
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                online
                                    ? (remaining == 0
                                        ? 'Pending data synced & tracking state repaired!'
                                        : 'Repaired. $remaining checkpoint(s) remain queued.')
                                    : 'Offline: tracking state repaired; pending data preserved.',
                              ),
                            ),
                          );
                        } catch (e) {
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(content: Text('Repair failed: $e')),
                          );
                        } finally {
                          if (mounted) setState(() => _isRepairing = false);
                        }
                      },
              ),
            ),
            if (_pendingCheckpoints.isNotEmpty) ...[
              const SizedBox(height: 32),
              const Text(
                'Checkpoint History (First Call to Last Call)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              ..._pendingCheckpoints.map((cp) {
                final isFirstCall = cp['isFirstCall'] == true;
                final isLastCall = cp['isLastCall'] == true;
                final checkpointNum = cp['checkpointNumber'] as int?;
                final lat = cp['lat'] as num?;
                final lon = cp['lon'] as num?;
                final ts = cp['timestamp'] as int?;
                final time = ts != null 
                    ? DateFormat('hh:mm:ss a').format(DateTime.fromMillisecondsSinceEpoch(ts))
                    : 'Unknown';

                if (isFirstCall || isLastCall) {
                  final isPending = cp['isPending'] == true;
                  final statusColor = isFirstCall
                      ? (isPending ? Colors.orange.shade800 : Colors.purple.shade700)
                      : Colors.teal.shade700;
                  final statusBg = isFirstCall
                      ? (isPending ? Colors.orange.shade50 : Colors.purple.shade50)
                      : Colors.teal.shade50;
                  final statusText = isFirstCall
                      ? (isPending ? 'First Call (Pending)' : 'First Call (Uploaded)')
                      : 'Last Call (Uploaded)';
                  final statusIcon = isFirstCall
                      ? (isPending ? Icons.add_a_photo_outlined : Icons.camera_alt_rounded)
                      : Icons.flag_circle_rounded;

                  return Card(
                    elevation: 1,
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: statusColor, width: 1.5),
                    ),
                    color: statusBg,
                    child: ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(statusIcon, color: statusColor, size: 20),
                      ),
                      title: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(time, style: TextStyle(fontWeight: FontWeight.w700, color: statusColor)),
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
                      subtitle: Text('Lat: ${lat?.toStringAsFixed(5) ?? 'N/A'}, Lon: ${lon?.toStringAsFixed(5) ?? 'N/A'}'),
                    ),
                  );
                }

                final isPending = ts != null && _pendingTimestamps.contains(ts);
                final statusColor = isPending ? Colors.red : Colors.green;
                final statusText = isPending ? 'Pending' : 'Uploaded';
                final statusIcon = isPending ? Icons.cloud_upload : Icons.cloud_done;
                final cpTitle = checkpointNum != null
                    ? 'Checkpoint #$checkpointNum • $time'
                    : time;

                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
                  ),
                  child: ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(statusIcon, color: statusColor, size: 20),
                    ),
                    title: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(cpTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
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
                    subtitle: Text('Lat: ${lat?.toStringAsFixed(5) ?? 'N/A'}, Lon: ${lon?.toStringAsFixed(5) ?? 'N/A'}'),
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
