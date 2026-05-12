import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/route_provider.dart';
import 'package:compact_sales_monitoring/services/archive_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/date_selector_widget.dart';
import 'package:compact_sales_monitoring/widgets/route_detail_modal.dart';
import 'package:compact_sales_monitoring/widgets/loading_skeletons.dart';
import 'package:compact_sales_monitoring/constants/app_constants.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';

class SuperUserDashboard extends StatefulWidget {
  const SuperUserDashboard({super.key});

  @override
  State<SuperUserDashboard> createState() => _SuperUserDashboardState();
}

class _SuperUserDashboardState extends State<SuperUserDashboard> {
  static const double _checkpointZoomThreshold = 13.5;
  static const double _checkpointEndpointOverlapMeters = 85;
  late DateTime _selectedDate;
  final FirestoreService _firestoreService = FirestoreService();
  final ArchiveService _archiveService = ArchiveService();
  late MapController _mapController;
  final Map<String, AppUser> _salesmenCache = {};
  bool _isArchiving = false;
  bool _showLegend = false;
  bool _showRouteStatusPanel = true;
  bool _showRouteLabels = true;
  bool _showFirstCallMarkers = true;
  bool _showLastCallMarkers = true;
  double _flagPinScale = 1.0;
  double _currentZoom = 12;
  String? _selectedCheckpointId;
  String? _focusedRouteId;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _mapController = MapController();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    context.read<RouteProvider>().fetchAllRoutesByDate(dateStr);
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

  Future<void> _showArchiveCompleteDialog(ArchiveResult result) async {
    final dateFolderLabel = result.dateFolders.length <= 3
        ? result.dateFolders.join(', ')
        : '${result.dateFolders.first}, ${result.dateFolders[1]}, +${result.dateFolders.length - 2} more';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive Complete'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Date range: ${result.startDate} to ${result.endDate}'),
              const SizedBox(height: 8),
              Text('Routes archived: ${result.routeCount}'),
              Text('Images exported: ${result.imageCount}'),
              const SizedBox(height: 12),
              const Text(
                'Saved ZIP path',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              SelectableText(result.zipPath),
              const SizedBox(height: 12),
              const Text(
                'ZIP structure',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text('- ${result.workbookFileName}'),
              Text('- Date folders: $dateFolderLabel'),
              const Text(
                '- Inside each date: salesman folders with first/last call images',
              ),
            ],
          ),
        ),
        actions: [
          if (!kIsWeb)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.zipPath));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Archive path copied')),
                );
              },
              child: const Text('Copy Path'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openArchivePicker() async {
    if (_isArchiving) return;

    final now = DateTime.now();
    final pickedRange = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: DateTimeRange(start: _selectedDate, end: _selectedDate),
      helpText: 'Archive routes',
      saveText: 'Archive',
    );

    if (pickedRange == null || !mounted) return;

    setState(() => _isArchiving = true);
    try {
      final result = await _archiveService.archiveRoutes(
        startDate: pickedRange.start,
        endDate: pickedRange.end,
      );
      await _loadRoutes();
      if (!mounted) return;
      await _showArchiveCompleteDialog(result);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Archive failed: $error')));
    } finally {
      if (mounted) {
        setState(() => _isArchiving = false);
      }
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
        final flagSize = (34 * _flagPinScale).clamp(18.0, 52.0);
        final flagPadding = (6 * _flagPinScale).clamp(4.0, 10.0);

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
              if (_showRouteLabels)
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
              SizedBox(height: _showRouteLabels ? 6 : 2),
              Container(
                padding: EdgeInsets.all(flagPadding),
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
                  size: flagSize,
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

  bool _shouldShowOngoingArrow(SalesRoute route) {
    return _currentZoom >= _checkpointZoomThreshold &&
        route.hasFirstCall &&
        !route.hasLastCall;
  }

  RouteCheckpoint? _latestCheckpoint(SalesRoute route) {
    final checkpoints = route.sortedCheckpoints;
    if (checkpoints.isEmpty) {
      return null;
    }
    return checkpoints.last;
  }

  LatLng _ongoingArrowPoint(SalesRoute route) {
    final latestCheckpoint = _latestCheckpoint(route);
    if (latestCheckpoint != null) {
      return LatLng(latestCheckpoint.lat, latestCheckpoint.lon);
    }

    return LatLng(route.first.lat, route.first.lon);
  }

  bool _isArrowCheckpoint(SalesRoute route, RouteCheckpoint checkpoint) {
    if (!_shouldShowOngoingArrow(route)) {
      return false;
    }

    final latestCheckpoint = _latestCheckpoint(route);
    if (latestCheckpoint == null) {
      return false;
    }

    return identical(latestCheckpoint, checkpoint);
  }

  bool _shouldShowCheckpoint(SalesRoute route, RouteCheckpoint checkpoint) {
    if (_currentZoom < _checkpointZoomThreshold) {
      return false;
    }

    if (_isArrowCheckpoint(route, checkpoint)) {
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

  /// Returns checkpoints synthesised from [route.cachedPolyline] for offline
  /// routes where explicit checkpoints were not persisted.
  /// Same-timestamp cache points are still accepted because legacy data often
  /// stores all cached points with one timestamp.
  List<RouteCheckpoint> _cachedPolylineAsCheckpoints(
    SalesRoute route, {
    List<LatLng>? renderedPolyline,
  }) {
    final fromCache = route.cachedPolyline;
    final fromRendered = renderedPolyline ?? const <LatLng>[];
    final useCache = fromCache.length >= 2;
    if (!useCache && fromRendered.length < 2) return [];

    final distance = const Distance();
    const dedupeMeters = 30.0;
    const minSpacingMeters = 120.0;

    final realAnchors = <LatLng>[
      if (route.hasFirstCall) LatLng(route.first.lat, route.first.lon),
      ...route.sortedCheckpoints.map((c) => LatLng(c.lat, c.lon)),
      if (route.hasLastCall) LatLng(route.last.lat, route.last.lon),
    ];

    final result = <RouteCheckpoint>[];
    LatLng? lastAdded;

    final sourceLength = useCache ? fromCache.length : fromRendered.length;
    for (var i = 0; i < sourceLength; i++) {
      final pLat = useCache ? fromCache[i].lat : fromRendered[i].latitude;
      final pLon = useCache ? fromCache[i].lon : fromRendered[i].longitude;
      final pTimestamp = useCache ? fromCache[i].timestamp : null;
      final pt = LatLng(pLat, pLon);

      final tooCloseToReal = realAnchors.any(
        (anchor) => distance.as(LengthUnit.Meter, pt, anchor) <= dedupeMeters,
      );
      if (tooCloseToReal) {
        continue;
      }

      if (lastAdded != null) {
        final spacing = distance.as(LengthUnit.Meter, lastAdded, pt);
        if (spacing < minSpacingMeters) {
          continue;
        }
      }

      result.add(
        RouteCheckpoint(
          lat: pLat,
          lon: pLon,
          timestamp:
              pTimestamp ??
              route.first.timestamp.add(Duration(seconds: i + 1)),
        ),
      );
      lastAdded = pt;
    }

    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
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
          isSelected: _focusedRouteId == route.routeId,
          onTap: () => _focusRoute(route, routeProvider),
        );
      },
    );
  }

  List<LatLng> _routeViewportPoints(
    SalesRoute route,
    RouteProvider routeProvider,
  ) {
    final cached = routeProvider.routePolylines[route.routeId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    return [
      LatLng(route.first.lat, route.first.lon),
      ...route.sortedCheckpoints.map((c) => LatLng(c.lat, c.lon)),
      if (route.hasLastCall) LatLng(route.last.lat, route.last.lon),
    ];
  }

  void _focusRoute(SalesRoute route, RouteProvider routeProvider) {
    final points = _routeViewportPoints(route, routeProvider);
    if (points.isEmpty) return;

    setState(() {
      _focusedRouteId = route.routeId;
    });

    if (points.length == 1) {
      _mapController.move(points.first, 15);
      return;
    }

    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.all(44),
      ),
    );
  }

  double _flagMarkerWidth() => _showRouteLabels ? 180 : 92;
  double _flagMarkerHeight() => _showRouteLabels ? 110 : 84;

  Widget _buildOngoingArrowMarker(SalesRoute route) {
    final routeColor = context.read<RouteProvider>().routeColorForSalesman(
      route.salesmanId,
    );

    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: routeColor, width: 2.5),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            color: Colors.black.withValues(alpha: 0.24),
          ),
        ],
      ),
      child: Icon(Icons.navigation, color: routeColor, size: 20),
    );
  }

  Widget _buildRouteStatusPanel(RouteProvider routeProvider) {
    final panel = Container(
      width: 260,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(10),
          bottomRight: Radius.circular(10),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 6,
            color: Colors.black.withValues(alpha: 0.2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Route Status',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: routeProvider.routes
                    .map((route) => _buildRouteStatusChip(route, routeProvider))
                    .toList(),
              ),
            ),
          ),
          if (_focusedRouteId != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _focusedRouteId = null),
                icon: const Icon(Icons.layers, size: 14),
                label: const Text('Show All'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Positioned(
      top: 12,
      left: 0,
      bottom: 12,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_showRouteStatusPanel) panel,
          Container(
            width: 32,
            height: 116,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.96),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(10),
                bottomRight: Radius.circular(10),
              ),
              boxShadow: [
                BoxShadow(
                  blurRadius: 6,
                  color: Colors.black.withValues(alpha: 0.2),
                ),
              ],
            ),
            child: IconButton(
              tooltip: _showRouteStatusPanel
                  ? 'Hide route status'
                  : 'Show route status',
              icon: Icon(
                _showRouteStatusPanel
                    ? Icons.keyboard_double_arrow_left
                    : Icons.keyboard_double_arrow_right,
                size: 18,
              ),
              onPressed: () {
                setState(() {
                  _showRouteStatusPanel = !_showRouteStatusPanel;
                });
              },
            ),
          ),
        ],
      ),
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
          IconButton(
            onPressed: _isArchiving ? null : _openArchivePicker,
            tooltip: 'Archive',
            icon: const Icon(Icons.archive_outlined),
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
                                (r) =>
                                  (_focusedRouteId == null ||
                                    r.routeId == _focusedRouteId) &&
                                  !routeProvider.isApproximate(r.routeId),
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
                                (r) =>
                                  (_focusedRouteId == null ||
                                    r.routeId == _focusedRouteId) &&
                                  routeProvider.isApproximate(r.routeId),
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
                              .where(
                              (r) =>
                                _focusedRouteId == null ||
                                r.routeId == _focusedRouteId,
                              )
                              .expand(
                                (route) => [
                                  ...[
                                    ...route.sortedCheckpoints,
                                    ..._cachedPolylineAsCheckpoints(
                                      route,
                                      renderedPolyline: routeProvider
                                          .routePolylines[route.routeId],
                                    ),
                                  ]
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
                              .where(
                              (r) =>
                                _focusedRouteId == null ||
                                r.routeId == _focusedRouteId,
                              )
                              .expand(
                                (route) => [
                                  if (_shouldShowOngoingArrow(route))
                                    Marker(
                                      point: _ongoingArrowPoint(route),
                                      width: 40,
                                      height: 40,
                                      rotate: true,
                                      child: _buildOngoingArrowMarker(route),
                                    ),
                                  if (_showFirstCallMarkers &&
                                      route.hasFirstCall)
                                    Marker(
                                      point: LatLng(
                                        route.first.lat,
                                        route.first.lon,
                                      ),
                                      width: _flagMarkerWidth(),
                                      height: _flagMarkerHeight(),
                                      rotate: true,
                                      child: _buildSalesmanMarker(
                                        route,
                                        route.first,
                                        isFirstCall: true,
                                      ),
                                    ),
                                  if (_showLastCallMarkers &&
                                      route.hasLastCall)
                                    Marker(
                                      point: LatLng(
                                        route.last.lat,
                                        route.last.lon,
                                      ),
                                      width: _flagMarkerWidth(),
                                      height: _flagMarkerHeight(),
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
                    _buildRouteStatusPanel(routeProvider),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_showLegend) ...[
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
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _LegendItem(
                                    color: Colors.green,
                                    label: 'First Call',
                                    icon: Icons.flag,
                                  ),
                                  SizedBox(height: 6),
                                  _LegendItem(
                                    color: Colors.red,
                                    label: 'Last Call',
                                    icon: Icons.flag,
                                  ),
                                  SizedBox(height: 6),
                                  _LegendItem(
                                    color: Colors.orange,
                                    label: 'Checkpoint',
                                    icon: Icons.circle,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  blurRadius: 6,
                                  color: Colors.black.withValues(alpha: 0.2),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: _showLegend
                                      ? 'Hide legend'
                                      : 'Show legend',
                                  icon: const Icon(Icons.info_outline),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  onPressed: () {
                                    setState(() => _showLegend = !_showLegend);
                                  },
                                ),
                                const SizedBox(height: 2),
                                IconButton(
                                  tooltip: _showRouteLabels
                                      ? 'Hide labels'
                                      : 'Show labels',
                                  icon: Icon(
                                    _showRouteLabels
                                        ? Icons.label
                                        : Icons.label_off,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _showRouteLabels = !_showRouteLabels;
                                    });
                                  },
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Pin Size',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                SizedBox(
                                  height: 140,
                                  width: 36,
                                  child: RotatedBox(
                                    quarterTurns: 3,
                                    child: Slider(
                                      value: _flagPinScale,
                                      min: 0.1,
                                      max: 1.4,
                                      divisions: 26,
                                      label: '${(_flagPinScale * 100).round()}%',
                                      onChanged: (value) {
                                        setState(() {
                                          _flagPinScale = value;
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                IconButton(
                                  tooltip: _showFirstCallMarkers
                                      ? 'Hide first call markers'
                                      : 'Show first call markers',
                                  icon: Icon(
                                    Icons.outlined_flag,
                                    color: _showFirstCallMarkers
                                        ? Colors.green
                                        : Colors.grey,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _showFirstCallMarkers =
                                          !_showFirstCallMarkers;
                                    });
                                  },
                                ),
                                IconButton(
                                  tooltip: _showLastCallMarkers
                                      ? 'Hide last call markers'
                                      : 'Show last call markers',
                                  icon: Icon(
                                    _showLastCallMarkers
                                        ? Icons.flag
                                        : Icons.flag_outlined,
                                    color: _showLastCallMarkers
                                        ? Colors.red
                                        : Colors.grey,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 30,
                                    height: 30,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _showLastCallMarkers =
                                          !_showLastCallMarkers;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_isArchiving)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.24),
                          child: const Center(
                            child: Card(
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 16,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 12),
                                    Text('Archiving selected routes...'),
                                  ],
                                ),
                              ),
                            ),
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
  final bool isSelected;
  final VoidCallback? onTap;

  const _RouteStatusChip({
    required this.salesmanLabel,
    required this.routeColor,
    required this.isFallback,
    required this.isSelected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = isFallback
        ? Colors.orange.shade700
        : Colors.green.shade700;
    final bgColor = isFallback ? Colors.orange.shade50 : Colors.green.shade50;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected ? routeColor : Colors.transparent,
                width: 1.2,
              ),
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
        ),
      ),
    );
  }
}
