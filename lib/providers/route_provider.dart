import 'dart:math';

import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/routing_service.dart';
import 'package:latlong2/latlong.dart';

class RouteProvider extends ChangeNotifier {
  static final List<Color> _routeColorPalette = _buildRouteColorPalette();

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
    final existingColor = _salesmanRouteColors[salesmanId];
    if (existingColor != null) {
      return existingColor;
    }

    final usedColors = _salesmanRouteColors.values.toSet();
    for (final color in _routeColorPalette) {
      if (!usedColors.contains(color)) {
        _salesmanRouteColors[salesmanId] = color;
        return color;
      }
    }

    final overflowColor = _colorFromOverflowIndex(_salesmanRouteColors.length);
    _salesmanRouteColors[salesmanId] = overflowColor;
    return overflowColor;
  }

  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> fetchRoutesByDate(String supervisorId, String date) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _routes = await _firestoreService.getRoutesByDate(supervisorId, date);
      _assignDistinctSalesmanColors();
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
      _assignDistinctSalesmanColors();
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
        final cachedFallback = route.cachedPolyline
            .map((p) => LatLng(p.lat, p.lon))
            .toList();
        if (cachedFallback.length >= 2) {
          _routePolylines[route.routeId] = cachedFallback;
          _approximatePolylines.add(route.routeId);
        } else {
          _routePolylines[route.routeId] = anchors;
        }
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

    // If no timestamps are present (older cache format), treat as fresh rather
    // than discarding a valid cached polyline and forcing unnecessary re-routing.
    if (cacheTime == null) {
      return true;
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

  void _assignDistinctSalesmanColors() {
    _salesmanRouteColors.clear();

    final salesmanIds = _routes
        .map((route) => route.salesmanId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    if (salesmanIds.isEmpty) {
      return;
    }

    salesmanIds.sort();
    final selectedColors = _pickMostDistinctColors(salesmanIds.length);

    for (var i = 0; i < salesmanIds.length; i++) {
      final salesmanId = salesmanIds[i];
      if (i < selectedColors.length) {
        _salesmanRouteColors[salesmanId] = selectedColors[i];
      } else {
        _salesmanRouteColors[salesmanId] = _colorFromOverflowIndex(i);
      }
    }
  }

  List<Color> _pickMostDistinctColors(int count) {
    if (count <= 0) {
      return const [];
    }

    final available = List<Color>.from(_routeColorPalette)..shuffle(Random());
    if (available.isEmpty) {
      return const [];
    }

    final selected = <Color>[available.removeLast()];

    while (selected.length < count && available.isNotEmpty) {
      var bestIndex = 0;
      var bestScore = -1.0;

      for (var i = 0; i < available.length; i++) {
        final candidate = available[i];
        final score = _minRgbDistanceSquared(candidate, selected);
        if (score > bestScore) {
          bestScore = score;
          bestIndex = i;
        }
      }

      selected.add(available.removeAt(bestIndex));
    }

    while (selected.length < count) {
      selected.add(_colorFromOverflowIndex(selected.length));
    }

    return selected;
  }

  double _minRgbDistanceSquared(Color color, List<Color> selected) {
    var minDistance = double.infinity;

    for (final existing in selected) {
      final dr = color.red - existing.red;
      final dg = color.green - existing.green;
      final db = color.blue - existing.blue;
      final distance = (dr * dr + dg * dg + db * db).toDouble();
      if (distance < minDistance) {
        minDistance = distance;
      }
    }

    return minDistance;
  }

  static List<Color> _buildRouteColorPalette() {
    const colorCount = 40;
    const hueStep = 360.0 / colorCount;
    const leap = 7; // Coprime with 40 to maximize hue separation early on.

    final colors = <Color>[];
    for (var i = 0; i < colorCount; i++) {
      final wheelIndex = (i * leap) % colorCount;
      final hue = wheelIndex * hueStep;
      const saturation = 0.82;
      final lightness = i.isEven ? 0.48 : 0.56;
      colors.add(HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor());
    }
    return colors;
  }

  Color _colorFromOverflowIndex(int index) {
    final hue = (index * 137.508) % 360;
    final saturation = index.isEven ? 0.72 : 0.64;
    final lightness = index % 3 == 0 ? 0.47 : 0.52;
    final hsl = HSLColor.fromAHSL(1.0, hue, saturation, lightness);
    return hsl.toColor();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void clear() {
    _routes = [];
    _routePolylines = {};
    _approximatePolylines.clear();
    _salesmanRouteColors.clear();
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
