import 'dart:math';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/routing_service.dart';
import 'package:latlong2/latlong.dart';

class RouteSegment {
  final List<LatLng> points;
  final bool isApproximate;
  RouteSegment({required this.points, this.isApproximate = false});
}

class RouteProvider extends ChangeNotifier {
  static final List<Color> _routeColorPalette = _buildRouteColorPalette();

  final FirestoreService _firestoreService = FirestoreService();
  final RoutingService _routingService = RoutingService();

  List<SalesRoute> _routes = [];
  Map<String, List<RouteSegment>> _routePolylines = {};

  /// Route IDs whose polyline is approximate (straight-line fallback).
  final Set<String> _approximatePolylines = {};
  final Map<String, Color> _salesmanRouteColors = {};
  bool _isLoading = false;
  bool _isAligningRoads = false;
  int _roadAlignGeneration = 0;
  String? _error;

  List<SalesRoute> get routes => _routes;
  Map<String, List<RouteSegment>> get routePolylines => _routePolylines;

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
  bool get isAligningRoads => _isAligningRoads;
  String? get error => _error;

  Future<void> fetchRoutesByDate(String supervisorId, String date, {bool silent = false}) async {
    final gen = ++_roadAlignGeneration;
    if (!silent && _routes.isEmpty) {
      _isLoading = true;
      _error = null;
      notifyListeners();
    }

    try {
      _routes = await _firestoreService.getRoutesByDate(supervisorId, date);
      _assignDistinctSalesmanColors();
      _seedImmediatePolylines();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }

    if (_error == null && _routes.isNotEmpty) {
      _alignPolylinesInBackground(generation: gen);
    }
  }

  Future<void> fetchAllRoutesByDate(String date, {bool silent = false}) async {
    final gen = ++_roadAlignGeneration;
    if (!silent && _routes.isEmpty) {
      _isLoading = true;
      _error = null;
      notifyListeners();
    }

    try {
      _routes = await _firestoreService.getAllRoutesByDate(date);
      _assignDistinctSalesmanColors();
      _seedImmediatePolylines();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }

    if (_error == null && _routes.isNotEmpty) {
      _alignPolylinesInBackground(generation: gen);
    }
  }

  Future<void> fetchAllRoutesByDateAndCompany(
    String companyId,
    String date, {
    bool silent = false,
  }) async {
    final gen = ++_roadAlignGeneration;
    if (!silent && _routes.isEmpty) {
      _isLoading = true;
      _error = null;
      notifyListeners();
    }

    try {
      _routes = await _firestoreService.getAllRoutesByDateAndCompany(
        companyId,
        date,
      );
      _assignDistinctSalesmanColors();
      _seedImmediatePolylines();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }

    if (_error == null && _routes.isNotEmpty) {
      _alignPolylinesInBackground(generation: gen);
    }
  }

  Future<RouteRealignResult> realignRoutesToRoads() async {
    final gen = ++_roadAlignGeneration;
    _isAligningRoads = true;
    _error = null;
    notifyListeners();

    try {
      await _generatePolylines(generation: gen, forceRoadRefresh: true);
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
      if (gen == _roadAlignGeneration) {
        _isAligningRoads = false;
      }
      notifyListeners();
    }
  }

  List<LatLng> _extractFilteredAnchors(SalesRoute route) {
    final sortedCps = route.sortedCheckpoints;

    // Downsample checkpoints if oversized for fast OSRM road snapping
    final List<RouteCheckpoint> effectiveCheckpoints;
    if (sortedCps.length > 200) {
      final step = (sortedCps.length / 200).ceil();
      effectiveCheckpoints = <RouteCheckpoint>[];
      for (var i = 0; i < sortedCps.length; i += step) {
        effectiveCheckpoints.add(sortedCps[i]);
      }
      if (sortedCps.isNotEmpty && effectiveCheckpoints.last != sortedCps.last) {
        effectiveCheckpoints.add(sortedCps.last);
      }
    } else {
      effectiveCheckpoints = sortedCps;
    }

    final rawAnchors = <LatLng>[];
    if (route.hasFirstCall) {
      rawAnchors.add(LatLng(route.first.lat, route.first.lon));
    }
    for (final checkpoint in effectiveCheckpoints) {
      rawAnchors.add(LatLng(checkpoint.lat, checkpoint.lon));
    }
    if (route.hasLastCall) {
      rawAnchors.add(LatLng(route.last.lat, route.last.lon));
    }

    return _filterTeleportSpikes(_filterIndoorJitterAnchors(rawAnchors));
  }

  /// Phase 1: Immediately populates [_routePolylines] from raw filtered GPS
  /// checkpoints so the map, markers, and paths render without waiting on OSRM.
  void _seedImmediatePolylines() {
    _routePolylines.clear();
    _approximatePolylines.clear();

    for (final route in _routes) {
      final anchors = _extractFilteredAnchors(route);
      _routePolylines[route.routeId] = [
        RouteSegment(points: anchors, isApproximate: true),
      ];
      _approximatePolylines.add(route.routeId);
    }
  }

  Future<void> _alignPolylinesInBackground({required int generation}) async {
    _isAligningRoads = true;
    notifyListeners();

    try {
      await _generatePolylines(generation: generation);
    } finally {
      if (generation == _roadAlignGeneration) {
        _isAligningRoads = false;
        notifyListeners();
      }
    }
  }

  Future<void> _generatePolylines({
    int? generation,
    bool forceRoadRefresh = false,
  }) async {
    final activeGen = generation ?? _roadAlignGeneration;
    final routesSnapshot = List<SalesRoute>.from(_routes);
    const concurrency = 3;

    for (var i = 0; i < routesSnapshot.length; i += concurrency) {
      if (activeGen != _roadAlignGeneration) return;
      final batch = routesSnapshot.sublist(
        i,
        min(i + concurrency, routesSnapshot.length),
      );
      await Future.wait(
        batch.map((route) => _snapSingleRoute(route, activeGen)),
      );
      if (activeGen != _roadAlignGeneration) return;
      notifyListeners();
    }
  }

  Future<void> _snapSingleRoute(SalesRoute route, int activeGen) async {
    final anchors = _extractFilteredAnchors(route);
    if (anchors.length < 2) {
      if (activeGen != _roadAlignGeneration) return;
      _routePolylines[route.routeId] = [
        RouteSegment(points: anchors, isApproximate: true),
      ];
      _approximatePolylines.add(route.routeId);
      return;
    }

    const distanceCalc = Distance();
    final roadWaypoints = <LatLng>[anchors.first];
    var isApproximate = false;

    // Batch consecutive waypoints (up to 25 per OSRM request) to avoid N-1 sequential HTTP calls.
    const maxBatchWaypoints = 25;
    var index = 0;

    while (index < anchors.length - 1) {
      if (activeGen != _roadAlignGeneration) return;

      final start = anchors[index];
      final next = anchors[index + 1];
      final firstStepMeters = distanceCalc.as(LengthUnit.Meter, start, next);

      if (firstStepMeters < 15) {
        roadWaypoints.add(next);
        index++;
        continue;
      }

      // Build a multi-waypoint chunk starting at index
      final chunk = <LatLng>[start];
      var chunkStraightMeters = 0.0;
      var cursor = index;

      while (cursor < anchors.length - 1 && chunk.length < maxBatchWaypoints) {
        final a = anchors[cursor];
        final b = anchors[cursor + 1];
        final stepMeters = distanceCalc.as(LengthUnit.Meter, a, b);
        if (stepMeters < 15 && chunk.length > 1) {
          break;
        }
        chunk.add(b);
        chunkStraightMeters += stepMeters;
        cursor++;
      }

      try {
        final osrmSegment = await _routingService.getRouteForWaypoints(chunk);
        if (osrmSegment.length >= 2) {
          var osrmMeters = 0.0;
          for (var k = 0; k < osrmSegment.length - 1; k++) {
            osrmMeters += distanceCalc.as(
              LengthUnit.Meter,
              osrmSegment[k],
              osrmSegment[k + 1],
            );
          }

          if (osrmMeters <= chunkStraightMeters * 5.0 ||
              chunkStraightMeters < 500) {
            roadWaypoints.addAll(osrmSegment.skip(1));
          } else {
            roadWaypoints.addAll(chunk.skip(1));
          }
        } else {
          roadWaypoints.addAll(chunk.skip(1));
        }
      } catch (_) {
        isApproximate = true;
        roadWaypoints.addAll(chunk.skip(1));
      }

      index = cursor;
    }

    if (activeGen != _roadAlignGeneration) return;

    final finalPoints = roadWaypoints.length >= 2 ? roadWaypoints : anchors;
    _routePolylines[route.routeId] = [
      RouteSegment(points: finalPoints, isApproximate: isApproximate),
    ];

    if (isApproximate) {
      _approximatePolylines.add(route.routeId);
    } else {
      _approximatePolylines.remove(route.routeId);
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
    SalesRoute route,
    List<LatLng> polyline,
  ) {
    if (polyline.isEmpty) return const [];

    final startTime = route.first.timestamp;
    final endTime = route.hasLastCall
        ? route.last.timestamp
        : (route.sortedCheckpoints.isNotEmpty
              ? route.sortedCheckpoints.last.timestamp
              : DateTime.now());

    var totalMs = endTime.difference(startTime).inMilliseconds;
    final minimumSpanMs = polyline.length - 1;
    if (totalMs < minimumSpanMs) {
      totalMs = minimumSpanMs;
    }

    if (polyline.length == 1) {
      return [
        CachedPolylinePoint(
          lat: polyline.first.latitude,
          lon: polyline.first.longitude,
          timestamp: startTime,
        ),
      ];
    }

    return polyline
        .asMap()
        .entries
        .map(
          (entry) => CachedPolylinePoint(
            lat: entry.value.latitude,
            lon: entry.value.longitude,
            // Interpolate timestamps across the actual route window so fallback
            // checkpoints remain monotonic and closer to real chronology.
            timestamp: startTime.add(
              Duration(
                milliseconds: ((totalMs * entry.key) / (polyline.length - 1))
                    .round(),
              ),
            ),
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

  List<LatLng> _filterIndoorJitterAnchors(List<LatLng> rawAnchors) {
    if (rawAnchors.length <= 2) return rawAnchors;

    final distanceCalc = const Distance();
    final filtered = <LatLng>[rawAnchors.first];

    for (var i = 1; i < rawAnchors.length; i++) {
      final prev = filtered.last;
      final current = rawAnchors[i];
      final dist = distanceCalc.as(LengthUnit.Meter, prev, current);

      // If consecutive checkpoint is within 50m of previous (indoor establishment dwell),
      // suppress rooftop micro-bouncing and keep entry establishment coordinate.
      if (dist < 50 && i < rawAnchors.length - 1) {
        continue;
      }

      filtered.add(current);
    }

    return filtered;
  }

  List<LatLng> _filterTeleportSpikes(List<LatLng> rawAnchors) {
    if (rawAnchors.length <= 2) return rawAnchors;

    final distanceCalc = const Distance();
    final result = <LatLng>[rawAnchors.first];

    for (var i = 1; i < rawAnchors.length - 1; i++) {
      final prev = result.last;
      final current = rawAnchors[i];
      final next = rawAnchors[i + 1];

      final distPrevCurrent = distanceCalc.as(LengthUnit.Meter, prev, current);
      final distCurrentNext = distanceCalc.as(LengthUnit.Meter, current, next);
      final distPrevNext = distanceCalc.as(LengthUnit.Meter, prev, next);

      // If current point is >25km away from both prev and next, but prev and next are <15km apart,
      // it's an isolated V-shaped teleport spike (e.g. stale checkpoint from yesterday 50km away).
      if (distPrevCurrent > 25000 && distCurrentNext > 25000 && distPrevNext < 15000) {
        developer.log('[RouteProvider] Filtered V-shaped teleport spike checkpoint at $current');
        continue;
      }

      result.add(current);
    }

    result.add(rawAnchors.last);
    return result;
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
