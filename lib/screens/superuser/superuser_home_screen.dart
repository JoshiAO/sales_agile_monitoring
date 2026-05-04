import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/date_selector_widget.dart';
import 'package:compact_sales_monitoring/widgets/loading_skeletons.dart';
import 'package:compact_sales_monitoring/screens/superuser/superuser_team_preview_screen.dart';

enum _SuperuserCardMode { wide, compact }

class SuperuserHomeScreen extends StatefulWidget {
  const SuperuserHomeScreen({super.key});

  @override
  State<SuperuserHomeScreen> createState() => _SuperuserHomeScreenState();
}

class _SuperuserHomeScreenState extends State<SuperuserHomeScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  late DateTime _selectedDate;
  late Future<_SuperuserHomeData> _homeDataFuture;
  _SuperuserCardMode _cardMode = _SuperuserCardMode.wide;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _homeDataFuture = _loadHomeData();
  }

  Future<_SuperuserHomeData> _loadHomeData() async {
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);

    final results = await Future.wait([
      _firestoreService.getUsersByRole(UserRole.supervisor),
      _firestoreService.getUsersByRole(UserRole.salesman),
      _firestoreService.getAllRoutesByDate(dateStr),
      _firestoreService.getAllAgileSubmissionsByDate(date: dateStr),
    ]);

    final supervisors = (results[0] as List<AppUser>).toList();
    final salesmen = (results[1] as List<AppUser>).toList();
    final routes = results[2] as List<SalesRoute>;
    final submissionsBySalesman = results[3] as Map<String, AgileSubmission>;

    final salesmenBySupervisor = <String, List<AppUser>>{};
    for (final salesman in salesmen) {
      final supervisorId = salesman.supervisorId;
      if (supervisorId == null || supervisorId.isEmpty) {
        continue;
      }
      salesmenBySupervisor.putIfAbsent(supervisorId, () => []).add(salesman);
    }

    final routesBySalesman = <String, SalesRoute>{};
    for (final route in routes) {
      final existing = routesBySalesman[route.salesmanId];
      if (existing == null ||
          _routeSortTime(route).isAfter(_routeSortTime(existing))) {
        routesBySalesman[route.salesmanId] = route;
      }
    }

    supervisors.sort(
      (left, right) => _displayName(left).compareTo(_displayName(right)),
    );

    final summaries = supervisors
        .map(
          (supervisor) => _SupervisorSummary(
            supervisor: supervisor,
            assignedSalesmen: (salesmenBySupervisor[supervisor.uid] ?? [])
              ..sort(
                (left, right) =>
                    _displayName(left).compareTo(_displayName(right)),
              ),
          ),
        )
        .toList();

    return _SuperuserHomeData(
      selectedDate: _selectedDate,
      routesBySalesman: routesBySalesman,
      submissionsBySalesman: submissionsBySalesman,
      supervisorSummaries: summaries,
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

  String _displayName(AppUser user) {
    final trimmedName = user.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : user.email;
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
      if (maxWidth >= 1500) return 4;
      if (maxWidth >= 760) return 3;
      if (maxWidth >= 560) return 2;
      return 1;
    }

    if (maxWidth >= 1200) return 4;
    if (maxWidth >= 900) return 3;
    if (maxWidth >= 600) return 2;
    return 1;
  }

  void _onDateChanged(DateTime newDate) {
    setState(() {
      _selectedDate = newDate;
      _homeDataFuture = _loadHomeData();
    });
  }

  void _openTeamPreview({
    required AppUser supervisor,
    required DateTime selectedDate,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SuperuserTeamPreviewScreen(
          supervisor: supervisor,
          selectedDate: selectedDate,
        ),
      ),
    );
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
      body: FutureBuilder<_SuperuserHomeData>(
        future: _homeDataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const CardsLoadingSkeleton(cardCount: 5);
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Unable to load supervisor team summaries.',
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

          return LayoutBuilder(
            builder: (context, constraints) {
              final columns = _cardsPerRow(constraints.maxWidth);
              const spacing = 12.0;
              final cardExtent = _cardMode == _SuperuserCardMode.wide
                  ? (columns == 1 ? 520.0 : 460.0)
                  : 112.0;

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
                          DateSelectorWidget(
                            initialDate: _selectedDate,
                            onDateChanged: _onDateChanged,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Supervisor Team Summary',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${data.supervisorSummaries.length} supervisor${data.supervisorSummaries.length == 1 ? '' : 's'}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Colors.grey.shade700,
                                          ),
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
                        ],
                      ),
                    ),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: data.supervisorSummaries.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                        mainAxisExtent: cardExtent,
                      ),
                      itemBuilder: (context, index) {
                        final summary = data.supervisorSummaries[index];
                        return _SupervisorSummaryCard(
                          summary: summary,
                          cardMode: _cardMode,
                          routesBySalesman: data.routesBySalesman,
                          submissionsBySalesman: data.submissionsBySalesman,
                          onPreviewTeam: () {
                            _openTeamPreview(
                              supervisor: summary.supervisor,
                              selectedDate: data.selectedDate,
                            );
                          },
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

class _SupervisorSummaryCard extends StatelessWidget {
  final _SupervisorSummary summary;
  final _SuperuserCardMode cardMode;
  final Map<String, SalesRoute> routesBySalesman;
  final Map<String, AgileSubmission> submissionsBySalesman;
  final VoidCallback onPreviewTeam;

  const _SupervisorSummaryCard({
    required this.summary,
    required this.cardMode,
    required this.routesBySalesman,
    required this.submissionsBySalesman,
    required this.onPreviewTeam,
  });

  String get _displayName {
    final trimmedName = summary.supervisor.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : summary.supervisor.email;
  }

  int get _teamSize => summary.assignedSalesmen.length;

  int get _activeTeamSize =>
      summary.assignedSalesmen.where((salesman) => salesman.active).length;

  int get _inactiveTeamSize => _teamSize - _activeTeamSize;

  int get _firstCallSuccessCount => summary.assignedSalesmen
      .where((salesman) => routesBySalesman[salesman.uid]?.hasFirstCall == true)
      .length;

  int get _lastCallSuccessCount => summary.assignedSalesmen
      .where((salesman) => routesBySalesman[salesman.uid]?.hasLastCall == true)
      .length;

  int get _actualProductiveCallsTotal => summary.assignedSalesmen.fold(
    0,
    (total, salesman) =>
        total + (submissionsBySalesman[salesman.uid]?.productiveCalls ?? 0),
  );

  double get _actualSttTotal => summary.assignedSalesmen.fold(
    0.0,
    (total, salesman) =>
        total + (submissionsBySalesman[salesman.uid]?.sttActual ?? 0.0),
  );

  String get _actualSttTotalText =>
      NumberFormat('#,##0.00').format(_actualSttTotal);

  String get _actualSttCompactText {
    if (_actualSttTotal >= 1000000) {
      return '${NumberFormat('#,##0.00').format(_actualSttTotal / 1000000)}M';
    } else if (_actualSttTotal >= 1000) {
      return '${NumberFormat('#,##0.00').format(_actualSttTotal / 1000)}K';
    } else {
      return NumberFormat('#,##0.00').format(_actualSttTotal);
    }
  }

  Widget _buildWideCard(BuildContext context) {
    return Column(
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
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _TeamStatusChip(
                        label: 'Active: $_activeTeamSize',
                        backgroundColor: Colors.green.shade50,
                        foregroundColor: Colors.green.shade700,
                      ),
                      _TeamStatusChip(
                        label: 'Inactive: $_inactiveTeamSize',
                        backgroundColor: Colors.orange.shade50,
                        foregroundColor: Colors.orange.shade700,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                summary.supervisor.email,
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
        LayoutBuilder(
          builder: (context, constraints) {
            final isWideLayout = constraints.maxWidth >= 860;

            Widget buildGroup({
              required String title,
              required List<Widget> metrics,
            }) {
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    IntrinsicHeight(
                      child: Row(
                        children: [
                          for (int i = 0; i < metrics.length; i++) ...[
                            Expanded(child: metrics[i]),
                            if (i < metrics.length - 1)
                              const VerticalDivider(width: 1),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            final assignedAndActualGroup = buildGroup(
              title: 'Assigned And Actual Metrics',
              metrics: [
                _MetricCell(label: 'Assigned Salesmen', value: '$_teamSize'),
                _MetricCell(
                  label: 'Actual Productive Calls',
                  value: '$_actualProductiveCallsTotal',
                ),
                _MetricCell(label: 'Actual STT', value: _actualSttTotalText),
              ],
            );

            final successfulCallsGroup = buildGroup(
              title: 'Successful Calls',
              metrics: [
                _MetricCell(
                  label: 'Successful First Calls',
                  value: '$_firstCallSuccessCount',
                ),
                _MetricCell(
                  label: 'Successful Last Calls',
                  value: '$_lastCallSuccessCount',
                ),
              ],
            );

            if (isWideLayout) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: assignedAndActualGroup),
                  const SizedBox(width: 10),
                  Expanded(flex: 2, child: successfulCallsGroup),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                assignedAndActualGroup,
                const SizedBox(height: 8),
                successfulCallsGroup,
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: onPreviewTeam,
            child: const Text('Team Preview'),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactCard(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onPreviewTeam,
      child: Column(
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
                  icon: Icons.groups_outlined,
                  value: '$_teamSize',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _CompactMetric(
                  icon: Icons.outlined_flag,
                  iconColor: Colors.green.shade700,
                  value: '$_firstCallSuccessCount',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _CompactMetric(
                  icon: Icons.flag,
                  iconColor: Colors.red.shade700,
                  value: '$_lastCallSuccessCount',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: _CompactMetric(
                  icon: Icons.trending_up_outlined,
                  value: 'PC $_actualProductiveCallsTotal',
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: cardMode == _SuperuserCardMode.wide
            ? _buildWideCard(context)
            : _buildCompactCard(context),
      ),
    );
  }
}

class _CardModeToggle extends StatelessWidget {
  final _SuperuserCardMode mode;
  final ValueChanged<_SuperuserCardMode> onModeChanged;

  const _CardModeToggle({required this.mode, required this.onModeChanged});

  @override
  Widget build(BuildContext context) {
    final isExpanded = MediaQuery.sizeOf(context).width >= 700;
    return ToggleButtons(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      isSelected: [
        mode == _SuperuserCardMode.wide,
        mode == _SuperuserCardMode.compact,
      ],
      onPressed: (index) {
        onModeChanged(
          index == 0 ? _SuperuserCardMode.wide : _SuperuserCardMode.compact,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade800),
          ),
        ],
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

class _TeamStatusChip extends StatelessWidget {
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  const _TeamStatusChip({
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

class _SuperuserHomeData {
  final DateTime selectedDate;
  final Map<String, SalesRoute> routesBySalesman;
  final Map<String, AgileSubmission> submissionsBySalesman;
  final List<_SupervisorSummary> supervisorSummaries;

  const _SuperuserHomeData({
    required this.selectedDate,
    required this.routesBySalesman,
    required this.submissionsBySalesman,
    required this.supervisorSummaries,
  });
}

class _SupervisorSummary {
  final AppUser supervisor;
  final List<AppUser> assignedSalesmen;

  const _SupervisorSummary({
    required this.supervisor,
    required this.assignedSalesmen,
  });
}
