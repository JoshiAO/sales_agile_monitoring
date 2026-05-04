import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/constants/app_constants.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/providers/route_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/date_selector_widget.dart';
import 'package:compact_sales_monitoring/widgets/loading_skeletons.dart';
import 'package:compact_sales_monitoring/widgets/route_detail_modal.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';

class SupervisorDashboard extends StatefulWidget {
  const SupervisorDashboard({super.key});

  @override
  State<SupervisorDashboard> createState() => _SupervisorDashboardState();
}

class _SupervisorDashboardState extends State<SupervisorDashboard> {
  static const double _checkpointZoomThreshold = 13.5;
  static const double _checkpointEndpointOverlapMeters = 85;
  late DateTime _selectedDate;
  final FirestoreService _firestoreService = FirestoreService();
  late MapController _mapController;
  final Map<String, AppUser> _salesmenCache = {};
  bool _showLegend = false;
  double _currentZoom = 12;
  String? _selectedCheckpointId;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _mapController = MapController();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;

    if (user != null) {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      context.read<RouteProvider>().fetchRoutesByDate(user.uid, dateStr);
    }
  }

  Future<AppUser?> _getSalesmanDetails(String salesmanId) async {
    if (_salesmenCache.containsKey(salesmanId)) {
      return _salesmenCache[salesmanId];
    }

    final user = await _firestoreService.getUser(salesmanId);
    if (user != null) {
      _salesmenCache[salesmanId] = user;
    }
    return user;
  }

  void _onDateChanged(DateTime newDate) {
    setState(() => _selectedDate = newDate);
    _loadRoutes();
  }

  Future<void> _realignRoutesToRoads() async {
    final routeProvider = context.read<RouteProvider>();
    try {
      final result = await routeProvider.realignRoutesToRoads();
      if (!mounted) return;

      final message = result.fallbackRoutes == 0
          ? 'All ${result.totalRoutes} routes are now road-aligned.'
          : '${result.roadAlignedRoutes}/${result.totalRoutes} road-aligned. ${result.fallbackRoutes} still fallback.';

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Route realignment failed: $error')),
      );
    }
  }

  Widget _buildSalesmanMarker(
    SalesRoute route,
    RoutePoint callPoint, {
    required bool isFirstCall,
  }) {
    return FutureBuilder<AppUser?>(
      future: _getSalesmanDetails(route.salesmanId),
      builder: (context, snapshot) {
        final salesman = snapshot.data;
        final trimmedName = salesman?.name?.trim() ?? '';
        final displayName = trimmedName.isNotEmpty
            ? trimmedName
            : (salesman?.email.isNotEmpty == true
                  ? salesman!.email
                  : route.salesmanId);

        return GestureDetector(
          onTap: () async {
            final salesmanDetails = await _getSalesmanDetails(route.salesmanId);
            if (!mounted || salesmanDetails == null) return;
            await showDialog(
              context: this.context,
              builder: (dialogContext) => RouteDetailModal(
                route: route,
                salesman: salesmanDetails,
                onRouteChanged: _loadRoutes,
              ),
            );
            _loadRoutes();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 170,
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 165),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 6,
                      color: Colors.black.withValues(alpha: 0.25),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.flag,
                  size: 34,
                  color: isFirstCall
                      ? Colors.green.shade700
                      : Colors.red.shade700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCheckpointMarker(
    BuildContext context,
    SalesRoute route,
    RouteCheckpoint checkpoint,
    bool isSelected,
  ) {
    final checkpointTime = DateFormat('hh:mm a').format(checkpoint.timestamp);
    final routeColor = context.read<RouteProvider>().routeColorForSalesman(
      route.salesmanId,
    );

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedCheckpointId = _checkpointId(route, checkpoint);
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                checkpointTime,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (isSelected) const SizedBox(height: 4),
          Container(
            width: isSelected ? 22 : 18,
            height: isSelected ? 22 : 18,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(
                color: routeColor,
                width: isSelected ? 3.5 : 2,
              ),
              boxShadow: [
                if (isSelected)
                  BoxShadow(
                    blurRadius: 10,
                    spreadRadius: 2,
                    color: routeColor.withValues(alpha: 0.5),
                  ),
                BoxShadow(
                  blurRadius: 4,
                  color: Colors.black.withValues(alpha: 0.25),
                ),
              ],
            ),
            child: Icon(
              Icons.place,
              size: isSelected ? 13 : 10,
              color: routeColor,
            ),
          ),
        ],
      ),
    );
  }

  String _checkpointId(SalesRoute route, RouteCheckpoint checkpoint) {
    return '${route.routeId}_${checkpoint.timestamp.millisecondsSinceEpoch}_${checkpoint.lat}_${checkpoint.lon}';
  }

  bool _shouldShowCheckpoint(SalesRoute route, RouteCheckpoint checkpoint) {
    if (_currentZoom < _checkpointZoomThreshold) {
      return false;
    }

    final distance = const Distance();
    final checkpointPoint = LatLng(checkpoint.lat, checkpoint.lon);
    final firstPoint = LatLng(route.first.lat, route.first.lon);
    final firstDistanceMeters = distance.as(
      LengthUnit.Meter,
      checkpointPoint,
      firstPoint,
    );

    if (firstDistanceMeters <= _checkpointEndpointOverlapMeters) {
      return false;
    }

    if (!route.hasLastCall) {
      return true;
    }

    final lastPoint = LatLng(route.last.lat, route.last.lon);
    final lastDistanceMeters = distance.as(
      LengthUnit.Meter,
      checkpointPoint,
      lastPoint,
    );
    return lastDistanceMeters > _checkpointEndpointOverlapMeters;
  }

  Widget _buildRouteStatusChip(SalesRoute route, RouteProvider routeProvider) {
    return FutureBuilder<AppUser?>(
      future: _getSalesmanDetails(route.salesmanId),
      builder: (context, snapshot) {
        final salesman = snapshot.data;
        final trimmedName = salesman?.name?.trim() ?? '';
        final salesmanLabel = trimmedName.isNotEmpty
            ? trimmedName
            : (salesman?.email.isNotEmpty == true
                  ? salesman!.email
                  : route.salesmanId);

        final isFallback = routeProvider.isApproximate(route.routeId);
        final lineColor = routeProvider.routeColorForSalesman(route.salesmanId);

        return _RouteStatusChip(
          salesmanLabel: salesmanLabel,
          routeColor: lineColor,
          isFallback: isFallback,
        );
      },
    );
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        elevation: 0,
        actions: [
          Consumer<RouteProvider>(
            builder: (context, routeProvider, _) => IconButton(
              onPressed: routeProvider.isLoading ? null : _realignRoutesToRoads,
              tooltip: 'Re-align all routes to roads',
              icon: const Icon(Icons.alt_route),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Date Selector
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: DateSelectorWidget(
              initialDate: _selectedDate,
              onDateChanged: _onDateChanged,
            ),
          ),

          // Map and Routes
          Expanded(
            child: Consumer<RouteProvider>(
              builder: (context, routeProvider, _) {
                if (routeProvider.isLoading) {
                  return const MapLoadingSkeleton();
                }

                if (routeProvider.routes.isEmpty) {
                  return const Center(child: Text('No routes for this date'));
                }

                // Calculate initial map bounds
                double minLat = 90, maxLat = -90;
                double minLon = 180, maxLon = -180;

                for (final route in routeProvider.routes) {
                  minLat = minLat > route.first.lat ? route.first.lat : minLat;
                  maxLat = maxLat < route.first.lat ? route.first.lat : maxLat;
                  minLon = minLon > route.first.lon ? route.first.lon : minLon;
                  maxLon = maxLon < route.first.lon ? route.first.lon : maxLon;

                  for (final checkpoint in route.sortedCheckpoints) {
                    minLat = minLat > checkpoint.lat ? checkpoint.lat : minLat;
                    maxLat = maxLat < checkpoint.lat ? checkpoint.lat : maxLat;
                    minLon = minLon > checkpoint.lon ? checkpoint.lon : minLon;
                    maxLon = maxLon < checkpoint.lon ? checkpoint.lon : maxLon;
                  }

                  if (route.hasLastCall) {
                    minLat = minLat > route.last.lat ? route.last.lat : minLat;
                    maxLat = maxLat < route.last.lat ? route.last.lat : maxLat;
                    minLon = minLon > route.last.lon ? route.last.lon : minLon;
                    maxLon = maxLon < route.last.lon ? route.last.lon : maxLon;
                  }
                }

                return Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: LatLng(
                          (minLat + maxLat) / 2,
                          (minLon + maxLon) / 2,
                        ),
                        initialZoom: 12,
                        onTap: (tapPosition, point) {
                          if (_selectedCheckpointId != null) {
                            setState(() => _selectedCheckpointId = null);
                          }
                        },
                        onPositionChanged: (position, hasGesture) {
                          final zoom = position.zoom;
                          if (zoom != null && zoom != _currentZoom && mounted) {
                            setState(() {
                              _currentZoom = zoom;
                              if (_currentZoom < _checkpointZoomThreshold) {
                                _selectedCheckpointId = null;
                              }
                            });
                          }
                        },
                      ),
                      children: [
                        // Tile Layer
                        TileLayer(
                          urlTemplate: AppConstants.useOfflineTiles
                              ? AppConstants.offlineTileUrl
                              : AppConstants.osmTileUrl,
                          tileProvider: AppConstants.useOfflineTiles
                              ? AssetTileProvider()
                              : null,
                          userAgentPackageName:
                              AppConstants.osmUserAgentPackage,
                        ),
                        RichAttributionWidget(
                          attributions: [
                            TextSourceAttribution(
                              AppConstants.useOfflineTiles
                                  ? AppConstants.offlineAttribution
                                  : AppConstants.osmAttribution,
                            ),
                          ],
                        ),

                        // Polylines — road-accurate routes
                        PolylineLayer(
                          polylines: routeProvider.routes
                              .where(
                                (r) => !routeProvider.isApproximate(r.routeId),
                              )
                              .map((route) {
                                final polyline =
                                    routeProvider.routePolylines[route.routeId];
                                final routeColor = routeProvider
                                    .routeColorForSalesman(route.salesmanId);
                                return Polyline(
                                  points:
                                      polyline ??
                                      [
                                        LatLng(
                                          route.first.lat,
                                          route.first.lon,
                                        ),
                                      ],
                                  color: routeColor.withValues(alpha: 0.78),
                                  strokeWidth: 4,
                                );
                              })
                              .toList(),
                        ),

                        // Polylines — approximate (offline fallback) routes
                        PolylineLayer(
                          polylines: routeProvider.routes
                              .where(
                                (r) => routeProvider.isApproximate(r.routeId),
                              )
                              .map((route) {
                                final polyline =
                                    routeProvider.routePolylines[route.routeId];
                                final routeColor = routeProvider
                                    .routeColorForSalesman(route.salesmanId);
                                return Polyline(
                                  points:
                                      polyline ??
                                      [
                                        LatLng(
                                          route.first.lat,
                                          route.first.lon,
                                        ),
                                      ],
                                  color: routeColor.withValues(alpha: 0.62),
                                  strokeWidth: 3,
                                  isDotted: true,
                                );
                              })
                              .toList(),
                        ),

                        // Checkpoints under endpoint flags.
                        MarkerLayer(
                          markers: routeProvider.routes
                              .expand(
                                (route) => [
                                  ...route.sortedCheckpoints
                                      .where(
                                        (checkpoint) => _shouldShowCheckpoint(
                                          route,
                                          checkpoint,
                                        ),
                                      )
                                      .map((checkpoint) {
                                        final checkpointId = _checkpointId(
                                          route,
                                          checkpoint,
                                        );
                                        final isSelected =
                                            checkpointId ==
                                            _selectedCheckpointId;
                                        return Marker(
                                          point: LatLng(
                                            checkpoint.lat,
                                            checkpoint.lon,
                                          ),
                                          width: isSelected ? 90 : 24,
                                          height: isSelected ? 48 : 24,
                                          rotate: true,
                                          child: _buildCheckpointMarker(
                                            context,
                                            route,
                                            checkpoint,
                                            isSelected,
                                          ),
                                        );
                                      }),
                                ],
                              )
                              .toList(),
                        ),

                        // First/last flags are rendered above checkpoints.
                        MarkerLayer(
                          markers: routeProvider.routes
                              .expand(
                                (route) => [
                                  Marker(
                                    point: LatLng(
                                      route.first.lat,
                                      route.first.lon,
                                    ),
                                    width: 180,
                                    height: 110,
                                    rotate: true,
                                    child: _buildSalesmanMarker(
                                      route,
                                      route.first,
                                      isFirstCall: true,
                                    ),
                                  ),
                                  if (route.hasLastCall)
                                    Marker(
                                      point: LatLng(
                                        route.last.lat,
                                        route.last.lon,
                                      ),
                                      width: 180,
                                      height: 110,
                                      rotate: true,
                                      child: _buildSalesmanMarker(
                                        route,
                                        route.last,
                                        isFirstCall: false,
                                      ),
                                    ),
                                ],
                              )
                              .toList(),
                        ),
                      ],
                    ),
                    Positioned(
                      top: 12,
                      left: 12,
                      child: Container(
                        width: 240,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 6,
                              color: Colors.black.withValues(alpha: 0.2),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Route Status',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 180),
                              child: SingleChildScrollView(
                                child: Column(
                                  children: routeProvider.routes
                                      .map(
                                        (route) => _buildRouteStatusChip(
                                          route,
                                          routeProvider,
                                        ),
                                      )
                                      .toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.92),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  blurRadius: 6,
                                  color: Colors.black.withValues(alpha: 0.2),
                                ),
                              ],
                            ),
                            child: IconButton(
                              tooltip: _showLegend
                                  ? 'Hide legend'
                                  : 'Show legend',
                              icon: const Icon(Icons.info_outline),
                              onPressed: () {
                                setState(() => _showLegend = !_showLegend);
                              },
                            ),
                          ),
                          if (_showLegend) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: [
                                  BoxShadow(
                                    blurRadius: 6,
                                    color: Colors.black.withValues(alpha: 0.2),
                                  ),
                                ],
                              ),
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _LegendItem(
                                    icon: Icons.flag,
                                    color: Colors.green,
                                    label: 'First Call',
                                  ),
                                  SizedBox(height: 6),
                                  _LegendItem(
                                    icon: Icons.flag,
                                    color: Colors.red,
                                    label: 'Last Call',
                                  ),
                                  SizedBox(height: 6),
                                  _LegendItem(
                                    icon: Icons.place,
                                    color: Colors.blueGrey,
                                    label: 'Checkpoint (tap for time)',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;

  const _LegendItem({
    required this.icon,
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _RouteStatusChip extends StatelessWidget {
  final String salesmanLabel;
  final Color routeColor;
  final bool isFallback;

  const _RouteStatusChip({
    required this.salesmanLabel,
    required this.routeColor,
    required this.isFallback,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = isFallback
        ? Colors.orange.shade700
        : Colors.green.shade700;
    final bgColor = isFallback ? Colors.orange.shade50 : Colors.green.shade50;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: routeColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                salesmanLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isFallback ? 'Fallback' : 'Road',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: statusColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
