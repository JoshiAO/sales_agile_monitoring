import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/route_detail_modal.dart';

enum _TeamPreviewFilter {
  all,
  active,
  inactive,
}

class SuperuserTeamPreviewScreen extends StatefulWidget {
  final AppUser supervisor;
  final DateTime selectedDate;

  const SuperuserTeamPreviewScreen({
    super.key,
    required this.supervisor,
    required this.selectedDate,
  });

  @override
  State<SuperuserTeamPreviewScreen> createState() => _SuperuserTeamPreviewScreenState();
}

class _SuperuserTeamPreviewScreenState extends State<SuperuserTeamPreviewScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  late Future<_TeamPreviewData> _previewFuture;
  _TeamPreviewFilter _filter = _TeamPreviewFilter.all;

  @override
  void initState() {
    super.initState();
    _previewFuture = _loadPreviewData();
  }

  Future<_TeamPreviewData> _loadPreviewData() async {
    final dateStr = DateFormat('yyyy-MM-dd').format(widget.selectedDate);
    final results = await Future.wait([
      _firestoreService.getSupervisorTeam(widget.supervisor.uid),
      _firestoreService.getRoutesByDate(widget.supervisor.uid, dateStr),
    ]);

    final team = (results[0] as List<AppUser>)
        .toList()
      ..sort((left, right) => _displayName(left).compareTo(_displayName(right)));
    final routes = results[1] as List<SalesRoute>;

    final routesBySalesman = <String, SalesRoute>{};
    for (final route in routes) {
      final existing = routesBySalesman[route.salesmanId];
      if (existing == null || _routeSortTime(route).isAfter(_routeSortTime(existing))) {
        routesBySalesman[route.salesmanId] = route;
      }
    }

    return _TeamPreviewData(
      team: team,
      routesBySalesman: routesBySalesman,
    );
  }

  DateTime _routeSortTime(SalesRoute route) {
    if (route.hasLastCall) {
      return route.last.timestamp;
    }
    if (route.hasFirstCall) {
      return route.first.timestamp;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _displayName(AppUser salesman) {
    final trimmedName = salesman.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : salesman.email;
  }

  String _formatCallTime({
    required bool hasCall,
    required DateTime timestamp,
  }) {
    if (!hasCall) {
      return '--';
    }
    return DateFormat('h:mm a').format(timestamp);
  }

  Future<void> _refresh() async {
    final nextFuture = _loadPreviewData();
    setState(() {
      _previewFuture = nextFuture;
    });
    await nextFuture;
  }

  Future<void> _openRoutePreview(AppUser salesman, SalesRoute route) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => RouteDetailModal(
        route: route,
        salesman: salesman,
        onRouteChanged: _refresh,
      ),
    );

    if (!mounted) {
      return;
    }

    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final supervisorName = _displayName(widget.supervisor);
    final selectedDateText = DateFormat('yyyy-MM-dd').format(widget.selectedDate);

    return Scaffold(
      appBar: AppBar(
        title: Text('Team Preview: $supervisorName'),
      ),
      body: FutureBuilder<_TeamPreviewData>(
        future: _previewFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Unable to load team preview.',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final data = snapshot.data!;
          final activeCount = data.team.where((salesman) => salesman.active).length;
          final inactiveCount = data.team.length - activeCount;
          final filteredTeam = data.team.where((salesman) {
            switch (_filter) {
              case _TeamPreviewFilter.active:
                return salesman.active;
              case _TeamPreviewFilter.inactive:
                return !salesman.active;
              case _TeamPreviewFilter.all:
                return true;
            }
          }).toList();

          if (data.team.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: const [
                  SizedBox(height: 120),
                  Icon(Icons.group_off, size: 48),
                  SizedBox(height: 16),
                  Text(
                    'No assigned salesmen for this supervisor.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: filteredTeam.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Assigned Salesmen',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${data.team.length} team member${data.team.length == 1 ? '' : 's'} • Date: $selectedDateText',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey.shade700,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            _StatusBadge(
                              label: 'Active: $activeCount',
                              backgroundColor: Colors.green.shade50,
                              foregroundColor: Colors.green.shade700,
                            ),
                            _StatusBadge(
                              label: 'Inactive: $inactiveCount',
                              backgroundColor: Colors.orange.shade50,
                              foregroundColor: Colors.orange.shade700,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SegmentedButton<_TeamPreviewFilter>(
                          showSelectedIcon: false,
                          selected: {_filter},
                          onSelectionChanged: (selection) {
                            setState(() {
                              _filter = selection.first;
                            });
                          },
                          segments: const [
                            ButtonSegment<_TeamPreviewFilter>(
                              value: _TeamPreviewFilter.all,
                              icon: Icon(Icons.groups_2_outlined),
                              label: Text('All'),
                            ),
                            ButtonSegment<_TeamPreviewFilter>(
                              value: _TeamPreviewFilter.active,
                              icon: Icon(Icons.person_outline),
                              label: Text('Active'),
                            ),
                            ButtonSegment<_TeamPreviewFilter>(
                              value: _TeamPreviewFilter.inactive,
                              icon: Icon(Icons.person_off_outlined),
                              label: Text('Inactive'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Showing ${filteredTeam.length} of ${data.team.length}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade700,
                              ),
                        ),
                      ],
                    ),
                  );
                }

                final salesman = filteredTeam[index - 1];
                final route = data.routesBySalesman[salesman.uid];
                return _SalesmanSummaryCard(
                  salesman: salesman,
                  route: route,
                  formatCallTime: _formatCallTime,
                  onPreviewCalls: route == null
                      ? null
                      : () => _openRoutePreview(salesman, route),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _SalesmanSummaryCard extends StatelessWidget {
  final AppUser salesman;
  final SalesRoute? route;
  final String Function({required bool hasCall, required DateTime timestamp})
      formatCallTime;
  final Future<void> Function()? onPreviewCalls;

  const _SalesmanSummaryCard({
    required this.salesman,
    required this.route,
    required this.formatCallTime,
    required this.onPreviewCalls,
  });

  String get _displayName {
    final trimmedName = salesman.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : salesman.email;
  }

  String get _firstCallText {
    if (route == null) {
      return '--';
    }
    return formatCallTime(
      hasCall: route!.hasFirstCall,
      timestamp: route!.first.timestamp,
    );
  }

  String get _lastCallText {
    if (route == null) {
      return '--';
    }
    return formatCallTime(
      hasCall: route!.hasLastCall,
      timestamp: route!.last.timestamp,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayName,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      if (!salesman.active) ...[
                        const SizedBox(height: 6),
                        _StatusBadge(
                          label: 'Inactive',
                          backgroundColor: Colors.orange.shade50,
                          foregroundColor: Colors.orange.shade700,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    salesman.email,
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade700,
                          fontSize: 11,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _MetricCell(
                      label: 'First Call',
                      value: _firstCallText,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _MetricCell(
                      label: 'Last Call',
                      value: _lastCallText,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  const Expanded(
                    child: _MetricCell(
                      label: 'Productive Calls',
                      value: 'Under Development',
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  const Expanded(
                    child: _MetricCell(
                      label: 'STT for today',
                      value: 'Under Development',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: onPreviewCalls == null
                    ? null
                    : () {
                        onPreviewCalls!();
                      },
                child: Text(route == null ? 'No Calls Yet' : 'Preview Calls'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCell extends StatelessWidget {
  final String label;
  final String value;

  const _MetricCell({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade800,
                ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  const _StatusBadge({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foregroundColor,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _TeamPreviewData {
  final List<AppUser> team;
  final Map<String, SalesRoute> routesBySalesman;

  const _TeamPreviewData({
    required this.team,
    required this.routesBySalesman,
  });
}
