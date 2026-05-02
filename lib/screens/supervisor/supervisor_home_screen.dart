import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/route_detail_modal.dart';
import 'package:compact_sales_monitoring/widgets/loading_skeletons.dart';

class SupervisorHomeScreen extends StatefulWidget {
  const SupervisorHomeScreen({super.key});

  @override
  State<SupervisorHomeScreen> createState() => _SupervisorHomeScreenState();
}

class _SupervisorHomeScreenState extends State<SupervisorHomeScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  late Future<_SupervisorHomeData> _homeDataFuture;
  _SupervisorCardMode _cardMode = _SupervisorCardMode.wide;

  @override
  void initState() {
    super.initState();
    _homeDataFuture = _loadHomeData();
  }

  Future<_SupervisorHomeData> _loadHomeData() async {
    final currentUser = context.read<AuthProvider>().currentUser;
    if (currentUser == null) {
      throw StateError('No authenticated supervisor found.');
    }

    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final results = await Future.wait([
      _firestoreService.getSupervisorTeam(currentUser.uid),
      _firestoreService.getRoutesByDate(currentUser.uid, today),
      _firestoreService.getAgileSubmissionsForSupervisorByDate(
        supervisorId: currentUser.uid,
        date: today,
      ),
    ]);

    final team = results[0] as List<AppUser>;
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

    team.sort(
      (left, right) => _displayName(left).compareTo(_displayName(right)),
    );

    return _SupervisorHomeData(
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
    final nextFuture = _loadHomeData();
    setState(() {
      _homeDataFuture = nextFuture;
    });
    await nextFuture;
  }

  int _cardsPerRow(double maxWidth) {
    final isMobileLayout = !kIsWeb && maxWidth < 700;
    if (isMobileLayout) {
      return 1;
    }

    if (kIsWeb) {
      if (maxWidth >= 1500) {
        return 4;
      }
      if (maxWidth >= 760) {
        return 3;
      }
      if (maxWidth >= 560) {
        return 2;
      }
      return 1;
    }

    final compact = _cardMode == _SupervisorCardMode.compact;
    final minCardWidth = compact ? 300.0 : 340.0;
    final columns = ((maxWidth + 12) / (minCardWidth + 12)).floor();
    return columns.clamp(2, 4);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: GestureDetector(
                onTap: () {
                  context.read<AuthProvider>().logout();
                },
                child: const Text('Logout', style: TextStyle(fontSize: 14)),
              ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<_SupervisorHomeData>(
        future: _homeDataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const CardsLoadingSkeleton(cardCount: 6);
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Unable to load assigned salesmen.',
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
                    'No salesmen are assigned to this supervisor yet.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final columns = _cardsPerRow(constraints.maxWidth);
              const spacing = 12.0;
              final cardExtent = _cardMode == _SupervisorCardMode.wide
                  ? 284.0
                  : 110.0;

              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Assigned Salesmen',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${data.team.length} team member${data.team.length == 1 ? '' : 's'}',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: Colors.grey.shade700),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          _CardModeToggle(
                            mode: _cardMode,
                            onModeChanged: (mode) {
                              setState(() {
                                _cardMode = mode;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: data.team.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                        mainAxisExtent: cardExtent,
                      ),
                      itemBuilder: (context, index) {
                        final salesman = data.team[index];
                        final route = data.routesBySalesman[salesman.uid];
                        return _SalesmanSummaryCard(
                          salesman: salesman,
                          route: route,
                          submission: data.submissionsBySalesman[salesman.uid],
                          cardMode: _cardMode,
                          formatCallTime: _formatCallTime,
                          onPreviewCalls: route == null
                              ? null
                              : () => _openRoutePreview(salesman, route),
                        );
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

class _SalesmanSummaryCard extends StatelessWidget {
  final AppUser salesman;
  final SalesRoute? route;
  final AgileSubmission? submission;
  final _SupervisorCardMode cardMode;
  final String Function({required bool hasCall, required DateTime timestamp})
  formatCallTime;
  final Future<void> Function()? onPreviewCalls;

  const _SalesmanSummaryCard({
    required this.salesman,
    required this.route,
    required this.submission,
    required this.cardMode,
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

  String get _actualSttCompactText {
    if (submission == null) {
      return '--';
    }
    final value = submission!.sttActual;
    if (value >= 1000000) {
      return '${NumberFormat('#,##0.00').format(value / 1000000)}M';
    } else if (value >= 1000) {
      return '${NumberFormat('#,##0.00').format(value / 1000)}K';
    } else {
      return NumberFormat('#,##0.00').format(value);
    }
  }

  bool get _showEmailLine {
    return _displayName.toLowerCase() != salesman.email.trim().toLowerCase();
  }

  Widget _buildWideCard(BuildContext context) {
    return Column(
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            _StateBadge(active: salesman.active),
          ],
        ),
        if (_showEmailLine) ...[
          const SizedBox(height: 4),
          Text(
            salesman.email,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey.shade700,
              fontSize: 11,
            ),
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
    );
  }

  Widget _buildCompactCard(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _CompactMetric(
                icon: Icons.outlined_flag,
                iconColor: Colors.green.shade700,
                value: _firstCallText,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _CompactMetric(
                icon: Icons.flag,
                iconColor: Colors.red.shade700,
                value: _lastCallText,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: _CompactMetric(
                icon: Icons.trending_up_outlined,
                value: 'PC $_actualProductiveCallsText',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: _CompactMetric(
                icon: Icons.payments_outlined,
                value: 'STT $_actualSttCompactText',
              ),
            ),
          ],
        ),
      ],
    );

    if (onPreviewCalls == null) {
      return content;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        onPreviewCalls!();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: content,
      ),
    );
  }

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
        child: cardMode == _SupervisorCardMode.wide
            ? _buildWideCard(context)
            : _buildCompactCard(context),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  final bool active;

  const _StateBadge({required this.active});

  @override
  Widget build(BuildContext context) {
    final bgColor = active ? Colors.green.shade50 : Colors.orange.shade50;
    final fgColor = active ? Colors.green.shade700 : Colors.orange.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        active ? 'Active' : 'Inactive',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fgColor,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CompactMetric extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String value;

  const _CompactMetric({
    required this.icon,
    required this.value,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: iconColor ?? Colors.grey.shade700),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _CardModeToggle extends StatelessWidget {
  final _SupervisorCardMode mode;
  final ValueChanged<_SupervisorCardMode> onModeChanged;

  const _CardModeToggle({required this.mode, required this.onModeChanged});

  @override
  Widget build(BuildContext context) {
    final isExpanded = MediaQuery.sizeOf(context).width >= 700;
    return ToggleButtons(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      isSelected: [
        mode == _SupervisorCardMode.wide,
        mode == _SupervisorCardMode.compact,
      ],
      onPressed: (index) {
        onModeChanged(
          index == 0 ? _SupervisorCardMode.wide : _SupervisorCardMode.compact,
        );
      },
      children: [
        Tooltip(
          message: 'Wide view',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: isExpanded
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.view_agenda_outlined),
                      SizedBox(width: 6),
                      Text('Wide'),
                    ],
                  )
                : const Icon(Icons.view_agenda_outlined),
          ),
        ),
        Tooltip(
          message: 'Compact view',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: isExpanded
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.view_list_outlined),
                      SizedBox(width: 6),
                      Text('Compact'),
                    ],
                  )
                : const Icon(Icons.view_list_outlined),
          ),
        ),
      ],
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

class _SupervisorHomeData {
  final List<AppUser> team;
  final Map<String, SalesRoute> routesBySalesman;
  final Map<String, AgileSubmission> submissionsBySalesman;

  const _SupervisorHomeData({
    required this.team,
    required this.routesBySalesman,
    required this.submissionsBySalesman,
  });
}

enum _SupervisorCardMode { wide, compact }
