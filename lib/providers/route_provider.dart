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
      await _generatePolylines();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _generatePolylines() async {
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

      // --- Cache-first: use stored polyline if available ---
      if (route.cachedPolyline.isNotEmpty && _isCacheFresh(route)) {
        _routePolylines[route.routeId] = route.cachedPolyline
            .map((p) => LatLng(p.lat, p.lon))
            .toList();
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
        _routePolylines[route.routeId] = anchors;
        _approximatePolylines.add(route.routeId);
        continue;
      }

      _routePolylines[route.routeId] = polyline;

      if (hasApproximateSegment) {
        _approximatePolylines.add(route.routeId);
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
            .savePolylineCache(route.routeId, cachePoints)
            .catchError((_) {});
      }
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
