import 'dart:math' as math;
import 'dart:developer' as developer;
import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

class RoutingService {
  static final RoutingService _instance = RoutingService._internal();

  factory RoutingService() {
    return _instance;
  }

  RoutingService._internal();

  final Dio _dio = Dio();

  // Uses the OSRM public demo server — no API key required.
  // Endpoint: /route/v1/driving/{lon1},{lat1};{lon2},{lat2}
  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    try {
      final url =
          'https://router.project-osrm.org/route/v1/driving'
          '/${start.longitude},${start.latitude}'
          ';${end.longitude},${end.latitude}';

      final response = await _dio.get<Map<String, dynamic>>(
        url,
        queryParameters: {
          'overview': 'full',
          'geometries': 'geojson',
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data!;
        final routes = data['routes'] as List?;

        if (routes == null || routes.isEmpty) return [];

        final geometry = routes[0]['geometry'] as Map<String, dynamic>;
        final coordinates = geometry['coordinates'] as List;

        return coordinates
            .cast<List>()
            .map((coord) => LatLng(
                  (coord[1] as num).toDouble(),
                  (coord[0] as num).toDouble(),
                ))
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
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
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
