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
  bool _isLoading = false;
  String? _error;

  List<SalesRoute> get routes => _routes;
  Map<String, List<LatLng>> get routePolylines => _routePolylines;
  /// Returns true for a given routeId if the displayed line is a
  /// straight-line fallback due to an offline/error condition.
  bool isApproximate(String routeId) => _approximatePolylines.contains(routeId);
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
        ...route.sortedCheckpoints
            .map((checkpoint) => LatLng(checkpoint.lat, checkpoint.lon)),
        if (route.hasLastCall) LatLng(route.last.lat, route.last.lon),
      ];

      if (anchors.length < 2) {
        _routePolylines[route.routeId] = anchors;
        continue;
      }

      // --- Cache-first: use stored polyline if available ---
      if (route.cachedPolyline.isNotEmpty) {
        _routePolylines[route.routeId] = route.cachedPolyline
            .map((p) => LatLng(p.lat, p.lon))
            .toList();
        continue;
      }

      // --- Fetch from OSRM ---
      try {
        final polyline = <LatLng>[];

        for (var index = 0; index < anchors.length - 1; index++) {
          final segment = await _routingService.getRoute(
            anchors[index],
            anchors[index + 1],
          );

          if (segment.isEmpty) continue;

          if (polyline.isEmpty) {
            polyline.addAll(segment);
          } else {
            polyline.addAll(segment.skip(1));
          }
        }

        if (polyline.isNotEmpty) {
          _routePolylines[route.routeId] = polyline;
          // Persist to Firestore so future loads work offline.
          final cachePoints = polyline
              .map((ll) => CachedPolylinePoint(lat: ll.latitude, lon: ll.longitude))
              .toList();
          _firestoreService
              .savePolylineCache(route.routeId, cachePoints)
              .catchError((_) {});
        } else {
          // OSRM returned empty segments — fall back to anchors.
          _routePolylines[route.routeId] = anchors;
          _approximatePolylines.add(route.routeId);
        }
      } catch (_) {
        // No internet or OSRM error — fall back to straight-line anchors.
        _routePolylines[route.routeId] = anchors;
        _approximatePolylines.add(route.routeId);
      }
    }
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
