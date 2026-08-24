import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math' as math;

class DataUsageEntry {
  final String appName;
  final double usageMB;
  final double percentage;

  DataUsageEntry({
    required this.appName,
    required this.usageMB,
    required this.percentage,
  });

  factory DataUsageEntry.fromMap(Map<String, dynamic> data) {
    return DataUsageEntry(
      appName: data['appName'] as String? ?? 'Unknown',
      usageMB: (data['usageMB'] as num?)?.toDouble() ?? 0.0,
      percentage: (data['index'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'appName': appName,
      'usageMB': usageMB,
      'index': percentage,
    };
  }
}

class RoutePoint {
  final double lat;
  final double lon;
  final String imageUrl;
  final DateTime timestamp;
  
  // Telemetry & Data Usage
  final String? productName;
  final String? modelName;
  final String? serialNumber;
  final String? uuid;
  final int? batteryLevel;
  final String? appVersion;
  final List<DataUsageEntry>? mobileDataUsage;
  final List<DataUsageEntry>? wifiDataUsage;

  RoutePoint({
    required this.lat,
    required this.lon,
    required this.imageUrl,
    required this.timestamp,
    this.productName,
    this.modelName,
    this.serialNumber,
    this.uuid,
    this.batteryLevel,
    this.appVersion,
    this.mobileDataUsage,
    this.wifiDataUsage,
  });

  factory RoutePoint.fromMap(Map<String, dynamic> data) {
    return RoutePoint(
      lat: (data['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (data['lon'] as num?)?.toDouble() ?? 0.0,
      imageUrl: data['imageUrl'] as String? ?? '',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      productName: data['productName'] as String?,
      modelName: data['modelName'] as String?,
      serialNumber: data['serialNumber'] as String?,
      uuid: data['uuid'] as String?,
      batteryLevel: data['batteryLevel'] as int?,
      appVersion: data['appVersion'] as String?,
      mobileDataUsage: (data['mobileDataUsage'] as List<dynamic>?)
          ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
          .toList(),
      wifiDataUsage: (data['wifiDataUsage'] as List<dynamic>?)
          ?.map((e) => DataUsageEntry.fromMap(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lon': lon,
      'imageUrl': imageUrl,
      'timestamp': timestamp,
      if (productName != null) 'productName': productName,
      if (modelName != null) 'modelName': modelName,
      if (serialNumber != null) 'serialNumber': serialNumber,
      if (uuid != null) 'uuid': uuid,
      if (batteryLevel != null) 'batteryLevel': batteryLevel,
      if (appVersion != null) 'appVersion': appVersion,
      if (mobileDataUsage != null)
        'mobileDataUsage': mobileDataUsage!.map((e) => e.toMap()).toList(),
      if (wifiDataUsage != null)
        'wifiDataUsage': wifiDataUsage!.map((e) => e.toMap()).toList(),
    };
  }
}

class RouteCheckpoint {
  final double lat;
  final double lon;
  final DateTime timestamp;
  final int? batteryLevel;
  final bool? isMobileDataOn;
  final bool? isWifiOn;

  RouteCheckpoint({
    required this.lat,
    required this.lon,
    required this.timestamp,
    this.batteryLevel,
    this.isMobileDataOn,
    this.isWifiOn,
  });

  factory RouteCheckpoint.fromMap(Map<String, dynamic> data) {
    return RouteCheckpoint(
      lat: (data['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (data['lon'] as num?)?.toDouble() ?? 0.0,
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      batteryLevel: data['batteryLevel'] as int?,
      isMobileDataOn: data['isMobileDataOn'] as bool?,
      isWifiOn: data['isWifiOn'] as bool?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'lat': lat, 
      'lon': lon, 
      'timestamp': timestamp,
      if (batteryLevel != null) 'batteryLevel': batteryLevel,
      if (isMobileDataOn != null) 'isMobileDataOn': isMobileDataOn,
      if (isWifiOn != null) 'isWifiOn': isWifiOn,
    };
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

  // Point-to-point great-circle distance sum including first call, checkpoints, and last call (if any).
  double get estimatedDistanceKm {
    if (!hasFirstCall) return 0.0;

    double totalDistance = 0.0;
    
    // Build a sequential list of coordinates
    final List<Map<String, double>> pathPoints = [];
    pathPoints.add({'lat': first.lat, 'lon': first.lon});
    
    for (final cp in sortedCheckpoints) {
      pathPoints.add({'lat': cp.lat, 'lon': cp.lon});
    }
    
    if (hasLastCall) {
      pathPoints.add({'lat': last.lat, 'lon': last.lon});
    }
    
    // Sum the distance between consecutive points
    for (int i = 0; i < pathPoints.length - 1; i++) {
      totalDistance += _haversineKm(
        pathPoints[i]['lat']!,
        pathPoints[i]['lon']!,
        pathPoints[i + 1]['lat']!,
        pathPoints[i + 1]['lon']!,
      );
    }
    
    return totalDistance;
  }

  // Prefer stored distance when available, otherwise use computed estimate.
  double get distanceKm => distance ?? estimatedDistanceKm;

  // Downsample checkpoints for map marker rendering when route has thousands of points
  List<RouteCheckpoint> get downsampledMapCheckpoints {
    final sorted = sortedCheckpoints;
    if (sorted.length <= 150) return sorted;
    final step = (sorted.length / 150).ceil();
    final result = <RouteCheckpoint>[];
    for (var i = 0; i < sorted.length; i += step) {
      result.add(sorted[i]);
    }
    if (sorted.isNotEmpty && result.last != sorted.last) {
      result.add(sorted.last);
    }
    return result;
  }

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
