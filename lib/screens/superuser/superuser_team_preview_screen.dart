import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/route_detail_modal.dart';

enum _TeamPreviewFilter { all, active, inactive }

class SuperuserTeamPreviewScreen extends StatefulWidget {
  final AppUser supervisor;
  final DateTime selectedDate;

  const SuperuserTeamPreviewScreen({
    super.key,
    required this.supervisor,
    required this.selectedDate,
  });

  @override
  State<SuperuserTeamPreviewScreen> createState() =>
      _SuperuserTeamPreviewScreenState();
}

class _SuperuserTeamPreviewScreenState
    extends State<SuperuserTeamPreviewScreen> {
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
      _firestoreService.getAgileSubmissionsForSupervisorByDate(
        supervisorId: widget.supervisor.uid,
        date: dateStr,
      ),
    ]);

    final team = (results[0] as List<AppUser>).toList()
      ..sort(
        (left, right) => _displayName(left).compareTo(_displayName(right)),
      );
    final routes = results[1] as List<SalesRoute>;
    final submissionsBySalesman = results[2] as Map<String, AgileSubmission>;

    final routesBySalesman = <String, SalesRoute>{};
    for (final route in routes) {
      final existing = routesBySalesman[route.salesmanId];
      if (existing == null ||
          _routeSortTime(route).isAfter(_routeSortTime(existing))) {
        routesBySalesman[route.salesmanId] = route;
      }
    }

    return _TeamPreviewData(
      team: team,
      routesBySalesman: routesBySalesman,
      submissionsBySalesman: submissionsBySalesman,
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

  String _formatCallTime({required bool hasCall, required DateTime timestamp}) {
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

  int _cardsPerRow(double maxWidth) {
    final isMobileLayout = !kIsWeb && maxWidth < 700;
    if (isMobileLayout) {
      return 1;
    }

    const minCardWidth = 360.0;
    final columns = ((maxWidth + 12) / (minCardWidth + 12)).floor();
    return columns.clamp(2, 4);
  }

  @override
  Widget build(BuildContext context) {
    final supervisorName = _displayName(widget.supervisor);
    final selectedDateText = DateFormat(
      'yyyy-MM-dd',
    ).format(widget.selectedDate);

    return Scaffold(
      appBar: AppBar(title: Text('Team Preview: $supervisorName')),
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
          final activeCount = data.team
              .where((salesman) => salesman.active)
              .length;
          final inactiveCount = data.team.length - activeCount;
          final totalActualProductiveCalls = data.team.fold<int>(
            0,
            (sum, salesman) =>
                sum +
                (data.submissionsBySalesman[salesman.uid]?.productiveCalls ??
                    0),
          );
          final totalActualStt = data.team.fold<double>(
            0.0,
            (sum, salesman) =>
                sum +
                (data.submissionsBySalesman[salesman.uid]?.sttActual ?? 0.0),
          );
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

          return LayoutBuilder(
            builder: (context, constraints) {
              final columns = _cardsPerRow(constraints.maxWidth);
              final isCompactHeader = constraints.maxWidth < 820;
              const spacing = 12.0;

              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!isCompactHeader)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Assigned Salesmen',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${data.team.length} team member${data.team.length == 1 ? '' : 's'} • Date: $selectedDateText',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
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
                                            backgroundColor:
                                                Colors.green.shade50,
                                            foregroundColor:
                                                Colors.green.shade700,
                                          ),
                                          _StatusBadge(
                                            label: 'Inactive: $inactiveCount',
                                            backgroundColor:
                                                Colors.orange.shade50,
                                            foregroundColor:
                                                Colors.orange.shade700,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Align(
                                  alignment: Alignment.topRight,
                                  child: SegmentedButton<_TeamPreviewFilter>(
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
                                ),
                              ],
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Assigned Salesmen',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${data.team.length} team member${data.team.length == 1 ? '' : 's'} • Date: $selectedDateText',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: Colors.grey.shade700),
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
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: SegmentedButton<_TeamPreviewFilter>(
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
                                ),
                              ],
                            ),
                          const SizedBox(height: 12),
                          LayoutBuilder(
                            builder: (context, statConstraints) {
                              final statColumns = statConstraints.maxWidth < 620
                                  ? 1
                                  : 2;
                              final statCardWidth = statColumns == 1
                                  ? statConstraints.maxWidth
                                  : (statConstraints.maxWidth - 10) / 2;
                              return Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  SizedBox(
                                    width: statCardWidth,
                                    height: 82,
                                    child: _TeamStatCard(
                                      label: 'Team Actual Productive Calls',
                                      value: '$totalActualProductiveCalls',
                                      icon: Icons.call_outlined,
                                      iconColor: Colors.blue.shade700,
                                      iconBackgroundColor: Colors.blue.shade50,
                                    ),
                                  ),
                                  SizedBox(
                                    width: statCardWidth,
                                    height: 82,
                                    child: _TeamStatCard(
                                      label: 'Team Actual STT',
                                      value: NumberFormat(
                                        '#,##0.00',
                                      ).format(totalActualStt),
                                      icon: Icons.show_chart_outlined,
                                      iconColor: Colors.teal.shade700,
                                      iconBackgroundColor: Colors.teal.shade50,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Showing ${filteredTeam.length} of ${data.team.length}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Colors.grey.shade700),
                          ),
                        ],
                      ),
                    ),
                    Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: [
                        SizedBox(
                          width: constraints.maxWidth,
                          child: GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: filteredTeam.length,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: spacing,
                                  mainAxisSpacing: spacing,
                                  mainAxisExtent: 282,
                                ),
                            itemBuilder: (context, index) {
                              final salesman = filteredTeam[index];
                              final route = data.routesBySalesman[salesman.uid];
                              return _SalesmanSummaryCard(
                                salesman: salesman,
                                route: route,
                                submission:
                                    data.submissionsBySalesman[salesman.uid],
                                formatCallTime: _formatCallTime,
                                onPreviewCalls: route == null
                                    ? null
                                    : () => _openRoutePreview(salesman, route),
                              );
                            },
                          ),
                        ),
                      ],
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

class _SalesmanSummaryCard extends StatelessWidget {
  final AppUser salesman;
  final SalesRoute? route;
  final AgileSubmission? submission;
  final String Function({required bool hasCall, required DateTime timestamp})
  formatCallTime;
  final Future<void> Function()? onPreviewCalls;

  const _SalesmanSummaryCard({
    required this.salesman,
    required this.route,
    required this.submission,
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

  String get _actualProductiveCallsText {
    if (submission == null) {
      return '--';
    }
    return '${submission!.productiveCalls}';
  }

  String get _actualSttText {
    if (submission == null) {
      return '--';
    }
    return NumberFormat('#,##0.00').format(submission!.sttActual);
  }

  bool get _showEmailLine {
    return _displayName.toLowerCase() != salesman.email.trim().toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = salesman.active;
    final badgeBg = isActive ? Colors.green.shade50 : Colors.orange.shade50;
    final badgeFg = isActive ? Colors.green.shade700 : Colors.orange.shade700;

    return Card(
      margin: EdgeInsets.zero,
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    _displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _StatusBadge(
                  label: isActive ? 'Active' : 'Inactive',
                  backgroundColor: badgeBg,
                  foregroundColor: badgeFg,
                ),
              ],
            ),
            if (_showEmailLine) ...[
              const SizedBox(height: 4),
              Text(
                salesman.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700),
              ),
            ] else ...[
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _MetricCell(label: 'First Call', value: _firstCallText),
                _MetricCell(label: 'Last Call', value: _lastCallText),
                _MetricCell(
                  label: 'Actual Productive Calls',
                  value: _actualProductiveCallsText,
                ),
                _MetricCell(label: 'Actual STT', value: _actualSttText),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
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

  const _MetricCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade900,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeamStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final Color iconBackgroundColor;

  const _TeamStatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
    required this.iconBackgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconBackgroundColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
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
  final Map<String, AgileSubmission> submissionsBySalesman;

  const _TeamPreviewData({
    required this.team,
    required this.routesBySalesman,
    required this.submissionsBySalesman,
  });
}
