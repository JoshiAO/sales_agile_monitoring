import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

enum CallsFilter { allWithCalls, completedFirstAndLast, onlyFirstCall }
enum CallsSort { firstCallAsc, firstCallDesc, lastCallAsc, lastCallDesc }

class SuperuserCallsViewScreen extends StatefulWidget {
  final AppUser supervisor;
  final DateTime selectedDate;

  const SuperuserCallsViewScreen({
    super.key,
    required this.supervisor,
    required this.selectedDate,
  });

  @override
  State<SuperuserCallsViewScreen> createState() => _SuperuserCallsViewScreenState();
}

class _SuperuserCallsViewScreenState extends State<SuperuserCallsViewScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  late Future<_CallsViewData> _dataFuture;

  CallsFilter _filter = CallsFilter.allWithCalls;
  CallsSort _sort = CallsSort.firstCallAsc;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  Future<_CallsViewData> _loadData() async {
    final dateStr = DateFormat('yyyy-MM-dd').format(widget.selectedDate);
    final results = await Future.wait([
      _firestoreService.getSupervisorTeam(widget.supervisor.uid),
      _firestoreService.getRoutesByDate(widget.supervisor.uid, dateStr),
    ]);

    final team = (results[0] as List<AppUser>).toList()
      ..sort((a, b) => _displayName(a).compareTo(_displayName(b)));
    final routes = results[1] as List<SalesRoute>;

    final routesBySalesman = <String, SalesRoute>{};
    for (final route in routes) {
      final existing = routesBySalesman[route.salesmanId];
      if (existing == null || _routeSortTime(route).isAfter(_routeSortTime(existing))) {
        routesBySalesman[route.salesmanId] = route;
      }
    }

    return _CallsViewData(team: team, routesBySalesman: routesBySalesman);
  }

  DateTime _routeSortTime(SalesRoute route) {
    if (route.hasLastCall) return route.last.timestamp;
    if (route.hasFirstCall) return route.first.timestamp;
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _displayName(AppUser salesman) {
    final trimmedName = salesman.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : salesman.email;
  }

  Future<void> _refresh() async {
    final nextFuture = _loadData();
    setState(() {
      _dataFuture = nextFuture;
    });
    await nextFuture;
  }

  @override
  Widget build(BuildContext context) {
    final supervisorName = _displayName(widget.supervisor);

    return Scaffold(
      appBar: AppBar(title: Text('Calls View: $supervisorName')),
      body: FutureBuilder<_CallsViewData>(
        future: _dataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Failed to load calls.', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('${snapshot.error}'),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _refresh, child: const Text('Retry')),
                ],
              ),
            );
          }

          final data = snapshot.data!;
          final allTeam = data.team;
          
          final withCalls = <AppUser>[];
          final nonCalls = <AppUser>[];

          // Separate users into with calls and non calls based on filter
          for (final user in allTeam) {
            final route = data.routesBySalesman[user.uid];
            if (route == null || !route.hasFirstCall) {
              nonCalls.add(user);
            } else {
              // Apply filter
              bool include = false;
              if (_filter == CallsFilter.allWithCalls) {
                include = true;
              } else if (_filter == CallsFilter.completedFirstAndLast) {
                include = route.hasFirstCall && route.hasLastCall;
              } else if (_filter == CallsFilter.onlyFirstCall) {
                include = route.hasFirstCall && !route.hasLastCall;
              }

              if (include) {
                withCalls.add(user);
              }
            }
          }

          // Sort withCalls
          withCalls.sort((a, b) {
            final routeA = data.routesBySalesman[a.uid]!;
            final routeB = data.routesBySalesman[b.uid]!;
            
            DateTime timeA;
            DateTime timeB;
            
            if (_sort == CallsSort.firstCallAsc || _sort == CallsSort.firstCallDesc) {
              timeA = routeA.first.timestamp;
              timeB = routeB.first.timestamp;
            } else {
              timeA = routeA.hasLastCall ? routeA.last.timestamp : DateTime.fromMillisecondsSinceEpoch(0);
              timeB = routeB.hasLastCall ? routeB.last.timestamp : DateTime.fromMillisecondsSinceEpoch(0);
            }

            if (_sort == CallsSort.firstCallAsc || _sort == CallsSort.lastCallAsc) {
              return timeA.compareTo(timeB);
            } else {
              return timeB.compareTo(timeA);
            }
          });

          return LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth < 700 ? 1 : (constraints.maxWidth / 360).floor();
              final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                mainAxisExtent: 200,
              );

              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Controls
                    Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        DropdownMenu<CallsFilter>(
                          label: const Text('Filter'),
                          initialSelection: _filter,
                          onSelected: (val) {
                            if (val != null) setState(() => _filter = val);
                          },
                          dropdownMenuEntries: const [
                            DropdownMenuEntry(value: CallsFilter.allWithCalls, label: 'All With Calls'),
                            DropdownMenuEntry(value: CallsFilter.completedFirstAndLast, label: 'Completed First & Last'),
                            DropdownMenuEntry(value: CallsFilter.onlyFirstCall, label: 'Only First Call'),
                          ],
                        ),
                        DropdownMenu<CallsSort>(
                          label: const Text('Sort By'),
                          initialSelection: _sort,
                          onSelected: (val) {
                            if (val != null) setState(() => _sort = val);
                          },
                          dropdownMenuEntries: const [
                            DropdownMenuEntry(value: CallsSort.firstCallAsc, label: 'First Call (Ascending)'),
                            DropdownMenuEntry(value: CallsSort.firstCallDesc, label: 'First Call (Descending)'),
                            DropdownMenuEntry(value: CallsSort.lastCallAsc, label: 'Last Call (Ascending)'),
                            DropdownMenuEntry(value: CallsSort.lastCallDesc, label: 'Last Call (Descending)'),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    
                    // With Calls Section
                    _SectionHeader(title: '--- With Calls (${withCalls.length}) ---'),
                    const SizedBox(height: 12),
                    if (withCalls.isEmpty)
                      const Center(child: Text('No salesmen match the filter.'))
                    else
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: gridDelegate,
                        itemCount: withCalls.length,
                        itemBuilder: (context, index) {
                          final user = withCalls[index];
                          final route = data.routesBySalesman[user.uid];
                          return _SalesmanCallCard(salesman: user, route: route);
                        },
                      ),
                    
                    const SizedBox(height: 32),

                    // Non Calls Section
                    _SectionHeader(title: '--- Non Calls (${nonCalls.length}) ---'),
                    const SizedBox(height: 12),
                    if (nonCalls.isEmpty)
                      const Center(child: Text('All salesmen have calls.'))
                    else
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: gridDelegate,
                        itemCount: nonCalls.length,
                        itemBuilder: (context, index) {
                          final user = nonCalls[index];
                          return _SalesmanCallCard(salesman: user, route: null);
                        },
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.grey.shade700,
        ),
      ),
    );
  }
}

class _SalesmanCallCard extends StatelessWidget {
  final AppUser salesman;
  final SalesRoute? route;

  const _SalesmanCallCard({required this.salesman, this.route});

  Future<void> _launchMap(double lat, double lon) async {
    final url = 'https://www.google.com/maps/search/?api=1&query=$lat,$lon';
    if (await canLaunchUrlString(url)) {
      await launchUrlString(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = salesman.name?.trim().isNotEmpty == true ? salesman.name! : salesman.email;
    final timeFormat = DateFormat('h:mm a');

    final distanceText = route != null ? '${route!.estimatedDistanceKm.toStringAsFixed(2)} km' : '0.00 km';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              'Distance Traveled: $distanceText',
              style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const Divider(height: 16),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _CallInfoBlock(
                      title: 'First Call',
                      timeText: (route != null && route!.hasFirstCall) ? timeFormat.format(route!.first.timestamp) : '--',
                      hasCall: route != null && route!.hasFirstCall,
                      onMapTap: (route != null && route!.hasFirstCall) ? () => _launchMap(route!.first.lat, route!.first.lon) : null,
                    ),
                  ),
                  const VerticalDivider(width: 16),
                  Expanded(
                    child: _CallInfoBlock(
                      title: 'Last Call',
                      timeText: (route != null && route!.hasLastCall) ? timeFormat.format(route!.last.timestamp) : '--',
                      hasCall: route != null && route!.hasLastCall,
                      onMapTap: (route != null && route!.hasLastCall) ? () => _launchMap(route!.last.lat, route!.last.lon) : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallInfoBlock extends StatelessWidget {
  final String title;
  final String timeText;
  final bool hasCall;
  final VoidCallback? onMapTap;

  const _CallInfoBlock({
    required this.title,
    required this.timeText,
    required this.hasCall,
    this.onMapTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w600),
              ),
            ),
            if (hasCall)
              InkWell(
                onTap: onMapTap,
                borderRadius: BorderRadius.circular(50),
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Icon(Icons.map, size: 16, color: Theme.of(context).colorScheme.primary),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          timeText,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
      ],
    );
  }
}

class _CallsViewData {
  final List<AppUser> team;
  final Map<String, SalesRoute> routesBySalesman;

  const _CallsViewData({required this.team, required this.routesBySalesman});
}
