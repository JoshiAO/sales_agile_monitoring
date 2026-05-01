import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/routing_service.dart';
import 'package:latlong2/latlong.dart';

class RouteProvider extends ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();
  final RoutingService _routingService = RoutingService();

  List<SalesRoute> _routes = [];
  Map<String, List<LatLng>> _routePolylines = {};

  /// Route IDs whose polyline is approximate (straight-line fallback).
  final Set<String> _approximatePolylines = {};
  final Map<String, Color> _salesmanRouteColors = {};
  bool _isLoading = false;
  String? _error;

  List<SalesRoute> get routes => _routes;
  Map<String, List<LatLng>> get routePolylines => _routePolylines;

  /// Returns true for a given routeId if the displayed line is a
  /// straight-line fallback due to an offline/error condition.
  bool isApproximate(String routeId) => _approximatePolylines.contains(routeId);
  Color routeColorForSalesman(String salesmanId) {
    return _salesmanRouteColors.putIfAbsent(
      salesmanId,
      () => _colorFromSalesmanId(salesmanId),
    );
  }

  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> fetchRoutesByDate(String supervisorId, String date) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _routes = await _firestoreService.getRoutesByDate(supervisorId, date);
      await _migrateLegacyCachedPolylineFlags();
      await _generatePolylines();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchAllRoutesByDate(String date) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _routes = await _firestoreService.getAllRoutesByDate(date);
      await _migrateLegacyCachedPolylineFlags();
      await _generatePolylines();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<RouteRealignResult> realignRoutesToRoads() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _generatePolylines(forceRoadRefresh: true);
      final fallbackRoutes = _approximatePolylines.length;
      return RouteRealignResult(
        totalRoutes: _routes.length,
        roadAlignedRoutes: _routes.length - fallbackRoutes,
        fallbackRoutes: fallbackRoutes,
      );
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _generatePolylines({bool forceRoadRefresh = false}) async {
    _routePolylines.clear();
    _approximatePolylines.clear();

    for (final route in _routes) {
      final anchors = <LatLng>[
        if (route.hasFirstCall) LatLng(route.first.lat, route.first.lon),
        ...route.sortedCheckpoints.map(
          (checkpoint) => LatLng(checkpoint.lat, checkpoint.lon),
        ),
        if (route.hasLastCall) LatLng(route.last.lat, route.last.lon),
      ];

      if (anchors.length < 2) {
        _routePolylines[route.routeId] = anchors;
        continue;
      }

      final cachedPolyline = route.cachedPolyline
          .map((p) => LatLng(p.lat, p.lon))
          .toList();

      // --- Cache-first: use stored polyline if available ---
      if (!forceRoadRefresh &&
          cachedPolyline.isNotEmpty &&
          _isCacheFresh(route)) {
        _routePolylines[route.routeId] = cachedPolyline;
        if (route.cachedPolylineApproximate ||
            _matchesAnchorPolyline(cachedPolyline, anchors)) {
          _approximatePolylines.add(route.routeId);
        }
        continue;
      }

      // Build strict ordered segments: first -> checkpoints -> last.
      // This guarantees the line passes each checkpoint in chronological order.
      final polyline = <LatLng>[];
      var hasApproximateSegment = false;

      for (var i = 0; i < anchors.length - 1; i++) {
        final start = anchors[i];
        final end = anchors[i + 1];

        try {
          final segment = await _routingService.getRoute(start, end);
          if (segment.length >= 2) {
            if (polyline.isEmpty) {
              polyline.addAll(segment);
            } else {
              polyline.addAll(segment.skip(1));
            }
          } else {
            hasApproximateSegment = true;
            if (polyline.isEmpty) {
              polyline.add(start);
            }
            polyline.add(end);
          }
        } catch (_) {
          hasApproximateSegment = true;
          if (polyline.isEmpty) {
            polyline.add(start);
          }
          polyline.add(end);
        }
      }

      if (polyline.length < 2) {
        if (cachedPolyline.isNotEmpty) {
          _routePolylines[route.routeId] = cachedPolyline;
          if (route.cachedPolylineApproximate ||
              _matchesAnchorPolyline(cachedPolyline, anchors)) {
            _approximatePolylines.add(route.routeId);
          }
        } else {
          _routePolylines[route.routeId] = anchors;
          _approximatePolylines.add(route.routeId);
          _firestoreService
              .savePolylineCache(
                route.routeId,
                _buildFallbackCachePoints(route),
                isApproximate: true,
              )
              .catchError((_) {});
        }
        continue;
      }

      _routePolylines[route.routeId] = polyline;

      if (hasApproximateSegment) {
        if (cachedPolyline.isNotEmpty) {
          _routePolylines[route.routeId] = cachedPolyline;
          if (route.cachedPolylineApproximate ||
              _matchesAnchorPolyline(cachedPolyline, anchors)) {
            _approximatePolylines.add(route.routeId);
          }
        } else {
          _routePolylines[route.routeId] = polyline;
          _approximatePolylines.add(route.routeId);
          _firestoreService
              .savePolylineCache(
                route.routeId,
                _buildTimedCachePointsFromPolyline(polyline),
                isApproximate: true,
              )
              .catchError((_) {});
        }
      } else {
        // Persist only fully road-aware paths to avoid caching straight fallbacks.
        final cacheTime = DateTime.now();
        final cachePoints = polyline
            .map(
              (ll) => CachedPolylinePoint(
                lat: ll.latitude,
                lon: ll.longitude,
                timestamp: cacheTime,
              ),
            )
            .toList();
        _firestoreService
            .savePolylineCache(route.routeId, cachePoints, isApproximate: false)
            .catchError((_) {});
      }
    }
  }

  Future<void> _migrateLegacyCachedPolylineFlags() async {
    final migrationWrites = <Future<void>>[];

    for (final route in _routes) {
      if (route.cachedPolyline.isEmpty ||
          route.hasCachedPolylineApproximateFlag) {
        continue;
      }

      final anchors = <LatLng>[
        if (route.hasFirstCall) LatLng(route.first.lat, route.first.lon),
        ...route.sortedCheckpoints.map(
          (checkpoint) => LatLng(checkpoint.lat, checkpoint.lon),
        ),
        if (route.hasLastCall) LatLng(route.last.lat, route.last.lon),
      ];

      final cachedPolyline = route.cachedPolyline
          .map((p) => LatLng(p.lat, p.lon))
          .toList();

      final isApproximate = _matchesAnchorPolyline(cachedPolyline, anchors);

      migrationWrites.add(
        _firestoreService
            .savePolylineCache(
              route.routeId,
              route.cachedPolyline,
              isApproximate: isApproximate,
            )
            .catchError((_) {}),
      );
    }

    if (migrationWrites.isNotEmpty) {
      await Future.wait(migrationWrites);
    }
  }

  bool _isCacheFresh(SalesRoute route) {
    if (route.cachedPolyline.isEmpty) return false;
    final cacheTime = route.cachedPolyline
        .map((point) => point.timestamp)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (latest, current) {
          if (latest == null) return current;
          return current.isAfter(latest) ? current : latest;
        });

    if (cacheTime == null) {
      return false;
    }

    final routeLatest = <DateTime>[
      route.first.timestamp,
      if (route.hasLastCall) route.last.timestamp,
      ...route.sortedCheckpoints.map((checkpoint) => checkpoint.timestamp),
    ].reduce((left, right) => left.isAfter(right) ? left : right);

    return !cacheTime.isBefore(routeLatest);
  }

  List<CachedPolylinePoint> _buildFallbackCachePoints(SalesRoute route) {
    final points = <CachedPolylinePoint>[];

    if (route.hasFirstCall) {
      points.add(
        CachedPolylinePoint(
          lat: route.first.lat,
          lon: route.first.lon,
          timestamp: route.first.timestamp,
        ),
      );
    }

    for (final checkpoint in route.sortedCheckpoints) {
      points.add(
        CachedPolylinePoint(
          lat: checkpoint.lat,
          lon: checkpoint.lon,
          timestamp: checkpoint.timestamp,
        ),
      );
    }

    if (route.hasLastCall) {
      points.add(
        CachedPolylinePoint(
          lat: route.last.lat,
          lon: route.last.lon,
          timestamp: route.last.timestamp,
        ),
      );
    }

    return points;
  }

  List<CachedPolylinePoint> _buildTimedCachePointsFromPolyline(
    List<LatLng> polyline,
  ) {
    final cacheTime = DateTime.now();
    return polyline
        .map(
          (point) => CachedPolylinePoint(
            lat: point.latitude,
            lon: point.longitude,
            timestamp: cacheTime,
          ),
        )
        .toList();
  }

  bool _matchesAnchorPolyline(List<LatLng> polyline, List<LatLng> anchors) {
    if (polyline.length != anchors.length) return false;

    const epsilon = 0.000001;
    for (var i = 0; i < anchors.length; i++) {
      final cached = polyline[i];
      final anchor = anchors[i];
      if ((cached.latitude - anchor.latitude).abs() > epsilon ||
          (cached.longitude - anchor.longitude).abs() > epsilon) {
        return false;
      }
    }

    return true;
  }

  Color _colorFromSalesmanId(String salesmanId) {
    var hash = 0;
    for (final codeUnit in salesmanId.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    final hsl = HSLColor.fromAHSL(1.0, hue, 0.72, 0.47);
    return hsl.toColor();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void clear() {
    _routes = [];
    _routePolylines = {};
    notifyListeners();
  }
}

class RouteRealignResult {
  final int totalRoutes;
  final int roadAlignedRoutes;
  final int fallbackRoutes;

  const RouteRealignResult({
    required this.totalRoutes,
    required this.roadAlignedRoutes,
    required this.fallbackRoutes,
  });
}
