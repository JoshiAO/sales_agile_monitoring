import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math' as math;

class RoutePoint {
  final double lat;
  final double lon;
  final String imageUrl;
  final DateTime timestamp;

  RoutePoint({
    required this.lat,
    required this.lon,
    required this.imageUrl,
    required this.timestamp,
  });

  factory RoutePoint.fromMap(Map<String, dynamic> data) {
    return RoutePoint(
      lat: (data['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (data['lon'] as num?)?.toDouble() ?? 0.0,
      imageUrl: data['imageUrl'] as String? ?? '',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lon': lon,
      'imageUrl': imageUrl,
      'timestamp': timestamp,
    };
  }
}

class RouteCheckpoint {
  final double lat;
  final double lon;
  final DateTime timestamp;

  RouteCheckpoint({
    required this.lat,
    required this.lon,
    required this.timestamp,
  });

  factory RouteCheckpoint.fromMap(Map<String, dynamic> data) {
    return RouteCheckpoint(
      lat: (data['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (data['lon'] as num?)?.toDouble() ?? 0.0,
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {'lat': lat, 'lon': lon, 'timestamp': timestamp};
  }
}

class CachedPolylinePoint {
  final double lat;
  final double lon;
  final DateTime? timestamp;

  const CachedPolylinePoint({
    required this.lat,
    required this.lon,
    this.timestamp,
  });

  factory CachedPolylinePoint.fromMap(Map<String, dynamic> data) {
    return CachedPolylinePoint(
      lat: (data['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (data['lon'] as num?)?.toDouble() ?? 0.0,
      timestamp: (data['timestamp'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
    'lat': lat,
    'lon': lon,
    if (timestamp != null) 'timestamp': timestamp,
  };
}

class SalesRoute {
  final String routeId;
  final String salesmanId;
  final String supervisorId;
  final String date; // YYYY-MM-DD format
  final RoutePoint first;
  final RoutePoint last;
  final bool hasFirstCall;
  final bool hasLastCall;
  final List<RouteCheckpoint> checkpoints;
  final List<CachedPolylinePoint> cachedPolyline;
  final bool cachedPolylineApproximate;
  final bool hasCachedPolylineApproximateFlag;
  final double? distance;
  final bool firstRetakeRequested;
  final bool firstRetakeApproved;
  final bool lastRetakeRequested;
  final bool lastRetakeApproved;

  SalesRoute({
    required this.routeId,
    required this.salesmanId,
    required this.supervisorId,
    required this.date,
    required this.first,
    required this.last,
    this.hasFirstCall = true,
    this.hasLastCall = true,
    this.checkpoints = const [],
    this.cachedPolyline = const [],
    this.cachedPolylineApproximate = false,
    this.hasCachedPolylineApproximateFlag = false,
    this.distance,
    this.firstRetakeRequested = false,
    this.firstRetakeApproved = false,
    this.lastRetakeRequested = false,
    this.lastRetakeApproved = false,
  });

  factory SalesRoute.fromMap(
    Map<String, dynamic> data, {
    required String routeId,
  }) {
    return SalesRoute(
      routeId: routeId,
      salesmanId: data['salesmanId'] as String? ?? '',
      supervisorId: data['supervisorId'] as String? ?? '',
      date: data['date'] as String? ?? '',
      first: RoutePoint.fromMap(data['first'] as Map<String, dynamic>? ?? {}),
      last: RoutePoint.fromMap(data['last'] as Map<String, dynamic>? ?? {}),
      hasFirstCall: data['hasFirstCall'] as bool? ?? true,
      hasLastCall: data['hasLastCall'] as bool? ?? true,
      checkpoints:
          ((data['checkpoints'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(RouteCheckpoint.fromMap)
              .toList()
            ..sort((a, b) => a.timestamp.compareTo(b.timestamp)),
      cachedPolyline: ((data['cachedPolyline'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CachedPolylinePoint.fromMap)
          .toList(),
      cachedPolylineApproximate:
          data['cachedPolylineApproximate'] as bool? ?? false,
      hasCachedPolylineApproximateFlag: data.containsKey(
        'cachedPolylineApproximate',
      ),
      distance: (data['distance'] as num?)?.toDouble(),
      firstRetakeRequested: data['firstRetakeRequested'] as bool? ?? false,
      firstRetakeApproved: data['firstRetakeApproved'] as bool? ?? false,
      lastRetakeRequested: data['lastRetakeRequested'] as bool? ?? false,
      lastRetakeApproved: data['lastRetakeApproved'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'salesmanId': salesmanId,
      'supervisorId': supervisorId,
      'date': date,
      'first': first.toMap(),
      'last': last.toMap(),
      'hasFirstCall': hasFirstCall,
      'hasLastCall': hasLastCall,
      'checkpoints': checkpoints
          .map((checkpoint) => checkpoint.toMap())
          .toList(),
      'cachedPolyline': cachedPolyline.map((p) => p.toMap()).toList(),
      'cachedPolylineApproximate': cachedPolylineApproximate,
      'distance': distance,
      'firstRetakeRequested': firstRetakeRequested,
      'firstRetakeApproved': firstRetakeApproved,
      'lastRetakeRequested': lastRetakeRequested,
      'lastRetakeApproved': lastRetakeApproved,
    };
  }

  List<RouteCheckpoint> get sortedCheckpoints {
    final ordered = List<RouteCheckpoint>.from(checkpoints);
    ordered.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return ordered;
  }

  // Great-circle estimate between first and last call points.
  double get estimatedDistanceKm => hasFirstCall && hasLastCall
      ? _haversineKm(first.lat, first.lon, last.lat, last.lon)
      : 0.0;

  // Prefer stored distance when available, otherwise use computed estimate.
  double get distanceKm => distance ?? estimatedDistanceKm;

  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadiusKm * c;
  }

  static double _toRadians(double degrees) => degrees * (math.pi / 180);
}
