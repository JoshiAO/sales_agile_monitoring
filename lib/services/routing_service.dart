import 'dart:math' as math;
import 'dart:developer' as developer;
import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';
import 'package:compact_sales_monitoring/constants/app_constants.dart';

class RoutingService {
  static final RoutingService _instance = RoutingService._internal();

  factory RoutingService() {
    return _instance;
  }

  RoutingService._internal();

  final Dio _dio = Dio();

  // Uses OpenRouteService when an API key is configured.
  // Falls back to OSRM for resilience.
  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    final route = await getRouteForWaypoints([start, end]);
    return route;
  }

  Future<List<LatLng>> getRouteForWaypoints(List<LatLng> waypoints) async {
    if (waypoints.length < 2) {
      return waypoints;
    }

    final orsKey = AppConstants.openRouteServiceApiKey.trim();

    if (orsKey.isNotEmpty && orsKey != 'YOUR_ORS_API_KEY_HERE') {
      try {
        final orsResponse = await _dio.post<Map<String, dynamic>>(
          '${AppConstants.openRouteServiceBaseUrl}/v2/directions/driving-car/geojson',
          options: Options(
            headers: {
              'Authorization': orsKey,
              'Content-Type': 'application/json',
            },
          ),
          data: {
            'coordinates': waypoints
                .map((point) => [point.longitude, point.latitude])
                .toList(),
          },
        );

        if (orsResponse.statusCode == 200 && orsResponse.data != null) {
          final features = orsResponse.data!['features'] as List?;
          if (features != null && features.isNotEmpty) {
            final geometry =
                features.first['geometry'] as Map<String, dynamic>?;
            final coordinates = geometry?['coordinates'] as List?;
            if (coordinates != null && coordinates.isNotEmpty) {
              return coordinates
                  .whereType<List>()
                  .map(
                    (coord) => LatLng(
                      (coord[1] as num).toDouble(),
                      (coord[0] as num).toDouble(),
                    ),
                  )
                  .toList();
            }
          }
        }
      } catch (e) {
        developer.log('OpenRouteService failed: $e', name: 'RoutingService');
      }
    }

    // OSRM fallback
    try {
      final coordinatesParam = waypoints
          .map((point) => '${point.longitude},${point.latitude}')
          .join(';');
      final url =
          'https://router.project-osrm.org/route/v1/driving/$coordinatesParam';

      final response = await _dio.get<Map<String, dynamic>>(
        url,
        queryParameters: {'overview': 'full', 'geometries': 'geojson'},
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data!;
        final routes = data['routes'] as List?;

        if (routes == null || routes.isEmpty) return [];

        final geometry = routes[0]['geometry'] as Map<String, dynamic>;
        final coordinates = geometry['coordinates'] as List;

        return coordinates
            .cast<List>()
            .map(
              (coord) => LatLng(
                (coord[1] as num).toDouble(),
                (coord[0] as num).toDouble(),
              ),
            )
            .toList();
      }

      throw Exception('Failed to fetch route: ${response.statusCode}');
    } catch (e) {
      throw Exception('Routing error: $e');
    }
  }

  Future<double> getDistance(LatLng start, LatLng end) async {
    try {
      final route = await getRoute(start, end);
      if (route.isEmpty) return 0.0;

      // Calculate total distance using Haversine formula
      double totalDistance = 0.0;
      for (int i = 0; i < route.length - 1; i++) {
        totalDistance += _calculateDistance(route[i], route[i + 1]);
      }

      return totalDistance;
    } catch (e) {
      developer.log('Distance calculation error: $e', name: 'RoutingService');
      return 0.0;
    }
  }

  double _calculateDistance(LatLng start, LatLng end) {
    const int earthRadiusKm = 6371;
    final dLat = _degreesToRadians(end.latitude - start.latitude);
    final dLon = _degreesToRadians(end.longitude - start.longitude);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(start.latitude)) *
            math.cos(_degreesToRadians(end.latitude)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * 3.141592653589793 / 180;
  }
}
