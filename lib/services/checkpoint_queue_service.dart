import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';

class _QueuedCheckpoint {
  final String routeId;
  final double lat;
  final double lon;
  final DateTime timestamp;

  _QueuedCheckpoint({
    required this.routeId,
    required this.lat,
    required this.lon,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'routeId': routeId,
    'lat': lat,
    'lon': lon,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  factory _QueuedCheckpoint.fromJson(Map<String, dynamic> json) {
    return _QueuedCheckpoint(
      routeId: json['routeId'] as String,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }
}

/// Persists checkpoints that failed to upload (e.g. data off) and retries
/// them later when connectivity is available.
class CheckpointQueueService {
  static const _prefsKey = 'pending_checkpoints_v1';

  Future<void> enqueue(String routeId, RouteCheckpoint checkpoint) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    raw.add(
      jsonEncode(
        _QueuedCheckpoint(
          routeId: routeId,
          lat: checkpoint.lat,
          lon: checkpoint.lon,
          timestamp: checkpoint.timestamp,
        ).toJson(),
      ),
    );
    await prefs.setStringList(_prefsKey, raw);
  }

  /// Tries to upload all queued checkpoints.
  /// Each successfully uploaded entry is removed from the queue.
  /// Entries that still fail are kept for the next retry.
  Future<void> flush(
    Future<void> Function(String routeId, RouteCheckpoint checkpoint) uploader,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    if (raw.isEmpty) return;

    final remaining = <String>[];
    for (final entry in raw) {
      try {
        final q = _QueuedCheckpoint.fromJson(
          jsonDecode(entry) as Map<String, dynamic>,
        );
        await uploader(
          q.routeId,
          RouteCheckpoint(lat: q.lat, lon: q.lon, timestamp: q.timestamp),
        );
      } catch (_) {
        remaining.add(entry);
      }
    }

    if (remaining.length != raw.length) {
      await prefs.setStringList(_prefsKey, remaining);
    }
  }
}
