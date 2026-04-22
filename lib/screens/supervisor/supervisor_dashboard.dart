import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
  late DateTime _selectedDate;
  final FirestoreService _firestoreService = FirestoreService();
  late MapController _mapController;
  final Map<String, AppUser> _salesmenCache = {};

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

  Widget _buildSalesmanMarker(SalesRoute route, RoutePoint callPoint,
      {required bool isFirstCall}) {
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isFirstCall ? Colors.green.shade500 : Colors.red.shade500,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 4,
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                  ],
                ),
                child: CircleAvatar(
                  radius: 24,
                  backgroundColor:
                    isFirstCall ? Colors.green.shade50 : Colors.red.shade50,
                  backgroundImage: callPoint.imageUrl.isNotEmpty
                    ? CachedNetworkImageProvider(callPoint.imageUrl)
                      : null,
                  child: callPoint.imageUrl.isEmpty
                    ? Icon(
                      isFirstCall ? Icons.flag : Icons.person_pin_circle,
                      color: isFirstCall
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                    )
                      : null,
                ),
              ),
            ],
          ),
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
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Supervisor Dashboard'),
            Text(
              'First/Last Call',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: Color(0xFFF5F5F5),
              ),
            ),
          ],
        ),
        elevation: 0,

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
                  return const Center(
                    child: Text('No routes for this date'),
                  );
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
                            userAgentPackageName: AppConstants.osmUserAgentPackage,
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
                              .where((r) => !routeProvider.isApproximate(r.routeId))
                              .map((route) {
                            final polyline =
                                routeProvider.routePolylines[route.routeId];
                            return Polyline(
                              points: polyline ?? [LatLng(route.first.lat, route.first.lon)],
                              color: Colors.blue.withValues(alpha: 0.7),
                              strokeWidth: 4,
                            );
                          }).toList(),
                        ),

                        // Polylines — approximate (offline fallback) routes
                        PolylineLayer(
                          polylines: routeProvider.routes
                              .where((r) => routeProvider.isApproximate(r.routeId))
                              .map((route) {
                            final polyline =
                                routeProvider.routePolylines[route.routeId];
                            return Polyline(
                              points: polyline ?? [LatLng(route.first.lat, route.first.lon)],
                              color: Colors.grey.withValues(alpha: 0.8),
                              strokeWidth: 3,
                              isDotted: true,
                            );
                          }).toList(),
                        ),

                        // Markers
                        MarkerLayer(
                          markers: routeProvider.routes
                              .expand((route) => [
                                    Marker(
                                      point:
                                          LatLng(route.first.lat, route.first.lon),
                                      width: 180,
                                      height: 110,
                                      rotate: true,
                                      child: _buildSalesmanMarker(
                                          route, route.first,
                                          isFirstCall: true),
                                    ),
                                    if (route.hasLastCall)
                                      Marker(
                                        point: LatLng(route.last.lat, route.last.lon),
                                        width: 180,
                                        height: 110,
                                        rotate: true,
                                        child: _buildSalesmanMarker(route, route.last,
                                            isFirstCall: false),
                                      ),
                                  ])
                              .toList(),
                        ),
                      ],
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _LegendItem(color: Colors.green, label: 'First Call'),
                            SizedBox(height: 6),
                            _LegendItem(color: Colors.red, label: 'Last Call'),
                            SizedBox(height: 6),
                            _LegendItem(
                              color: Colors.grey,
                              label: 'Approximate (offline)',
                              isDashed: true,
                            ),
                          ],
                        ),
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
  final Color color;
  final String label;
  final bool isDashed;

  const _LegendItem({
    required this.color,
    required this.label,
    this.isDashed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        isDashed
            ? SizedBox(
                width: 24,
                height: 12,
                child: CustomPaint(
                  painter: _DashPainter(color: color),
                ),
              )
            : Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  final Color color;
  const _DashPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const dashWidth = 4.0;
    const dashSpace = 3.0;
    double x = 0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset(x + dashWidth, y), paint);
      x += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
