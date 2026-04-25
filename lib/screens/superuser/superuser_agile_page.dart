import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/date_selector_widget.dart';

enum _SuperuserAgileViewMode { wide, compact }

class SuperuserAgilePage extends StatefulWidget {
  const SuperuserAgilePage({super.key});

  @override
  State<SuperuserAgilePage> createState() => _SuperuserAgilePageState();
}

class _SuperuserAgilePageState extends State<SuperuserAgilePage> {
  final FirestoreService _firestoreService = FirestoreService();

  late DateTime _selectedDate;
  late Future<_SuperuserAgileData> _pageFuture;
  _SuperuserAgileViewMode _viewMode = _SuperuserAgileViewMode.wide;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _pageFuture = _loadPageData();
  }

  Future<_SuperuserAgileData> _loadPageData() async {
    final date = DateFormat('yyyy-MM-dd').format(_selectedDate);

    final results = await Future.wait([
      _firestoreService.getUsersByRole(UserRole.supervisor),
      _firestoreService.getUsersByRole(UserRole.salesman),
      _firestoreService.getAgileTargetsByDate(date: date),
      _firestoreService.getAllAgileSubmissionsByDate(date: date),
    ]);

    final supervisors = (results[0] as List<AppUser>).toList()
      ..sort((left, right) => _displayName(left).compareTo(_displayName(right)));
    final salesmen = results[1] as List<AppUser>;
    final targetsBySalesman = results[2] as Map<String, AgileTarget>;
    final submissionsBySalesman = results[3] as Map<String, AgileSubmission>;

    final salesmenBySupervisor = <String, List<AppUser>>{};
    for (final salesman in salesmen) {
      final supervisorId = salesman.supervisorId;
      if (supervisorId == null || supervisorId.isEmpty) {
        continue;
      }
      salesmenBySupervisor.putIfAbsent(supervisorId, () => []).add(salesman);
    }

    for (final team in salesmenBySupervisor.values) {
      team.sort((left, right) => _displayName(left).compareTo(_displayName(right)));
    }

    final summaries = supervisors
        .map(
          (supervisor) => _SupervisorAgileSummary(
            supervisor: supervisor,
            team: salesmenBySupervisor[supervisor.uid] ?? const [],
          ),
        )
        .toList();

    return _SuperuserAgileData(
      date: date,
      summaries: summaries,
      targetsBySalesman: targetsBySalesman,
      submissionsBySalesman: submissionsBySalesman,
    );
  }

  String _displayName(AppUser user) {
    final trimmedName = user.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : user.email;
  }

  Future<void> _refresh() async {
    final nextFuture = _loadPageData();
    setState(() {
      _pageFuture = nextFuture;
    });
    await nextFuture;
  }

  void _onDateChanged(DateTime newDate) {
    setState(() {
      _selectedDate = newDate;
      _pageFuture = _loadPageData();
    });
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '', decimalDigits: 2);

    return Scaffold(
      appBar: AppBar(title: const Text('Agile')),
      body: FutureBuilder<_SuperuserAgileData>(
        future: _pageFuture,
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
                      'Unable to load superuser agile data.',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _refresh, child: const Text('Retry')),
                  ],
                ),
              ),
            );
          }

          final data = snapshot.data!;
          final filtered = data.summaries;

          final overallProductive = data.summaries
              .expand((summary) => summary.team)
              .map((salesman) => data.submissionsBySalesman[salesman.uid]?.productiveCalls ?? 0)
              .fold<int>(0, (sum, value) => sum + value);
          final overallSale = data.summaries
              .expand((summary) => summary.team)
              .map((salesman) => data.submissionsBySalesman[salesman.uid]?.sttActual ?? 0.0)
              .fold<double>(0.0, (sum, value) => sum + value);

          if (data.summaries.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: const [
                  SizedBox(height: 120),
                  Icon(Icons.supervisor_account_outlined, size: 48),
                  SizedBox(height: 16),
                  Text(
                    'No supervisors found.',
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
              itemCount: filtered.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
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
                                    'Supervisor Agile Overview',
                                    style: Theme.of(context).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${data.summaries.length} supervisor${data.summaries.length == 1 ? '' : 's'} • Date: ${data.date}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: Colors.grey.shade700),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            _AgileViewToggle(
                              mode: _viewMode,
                              onChanged: (mode) {
                                setState(() {
                                  _viewMode = mode;
                                });
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final stacked = constraints.maxWidth < 560;
                            final first = _SummaryMetricCard(
                              label: 'Overall Total Productive Calls',
                              value: '$overallProductive',
                              icon: Icons.storefront,
                              color: Colors.blue,
                            );
                            final second = _SummaryMetricCard(
                              label: 'Overall Total Actual Sale',
                              value: currency.format(overallSale),
                              icon: Icons.payments_outlined,
                              color: Colors.teal,
                            );

                            if (stacked) {
                              return Column(
                                children: [
                                  first,
                                  const SizedBox(height: 10),
                                  second,
                                ],
                              );
                            }

                            return Row(
                              children: [
                                Expanded(child: first),
                                const SizedBox(width: 10),
                                Expanded(child: second),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  );
                }

                final summary = filtered[index - 1];
                final teamProductiveTarget = summary.team
                    .map((salesman) => data.targetsBySalesman[salesman.uid]?.productiveCallsTarget ?? 0)
                    .fold<int>(0, (sum, value) => sum + value);
                final teamProductiveActual = summary.team
                    .map((salesman) => data.submissionsBySalesman[salesman.uid]?.productiveCalls ?? 0)
                    .fold<int>(0, (sum, value) => sum + value);
                final teamSttTarget = summary.team
                    .map((salesman) => data.targetsBySalesman[salesman.uid]?.sttTarget ?? 0.0)
                    .fold<double>(0.0, (sum, value) => sum + value);
                final teamSttActual = summary.team
                    .map((salesman) => data.submissionsBySalesman[salesman.uid]?.sttActual ?? 0.0)
                    .fold<double>(0.0, (sum, value) => sum + value);

                return _SupervisorAggregateCard(
                  summary: summary,
                  mode: _viewMode,
                  productiveTarget: teamProductiveTarget,
                  productiveActual: teamProductiveActual,
                  sttTarget: teamSttTarget,
                  sttActual: teamSttActual,
                  targetsBySalesman: data.targetsBySalesman,
                  submissionsBySalesman: data.submissionsBySalesman,
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _SupervisorAggregateCard extends StatelessWidget {
  final _SupervisorAgileSummary summary;
  final _SuperuserAgileViewMode mode;
  final int productiveTarget;
  final int productiveActual;
  final double sttTarget;
  final double sttActual;
  final Map<String, AgileTarget> targetsBySalesman;
  final Map<String, AgileSubmission> submissionsBySalesman;

  const _SupervisorAggregateCard({
    required this.summary,
    required this.mode,
    required this.productiveTarget,
    required this.productiveActual,
    required this.sttTarget,
    required this.sttActual,
    required this.targetsBySalesman,
    required this.submissionsBySalesman,
  });

  void _openSalesmanPreview(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SalesmanPerformancePreviewPage(
          summary: summary,
          targetsBySalesman: targetsBySalesman,
          submissionsBySalesman: submissionsBySalesman,
        ),
      ),
    );
  }

  String _displayName(AppUser user) {
    final trimmedName = user.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : user.email;
  }

  double _indexValue({required double actual, required double target}) {
    if (target <= 0) return 0;
    return actual / target;
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '', decimalDigits: 2);
    final productiveIndex = _indexValue(
      actual: productiveActual.toDouble(),
      target: productiveTarget.toDouble(),
    );
    final sttIndex = _indexValue(actual: sttActual, target: sttTarget);
    final productivePercent = productiveIndex * 100;
    final sttPercent = sttIndex * 100;

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
                        _displayName(summary.supervisor),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        summary.supervisor.email,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey.shade700,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _StatusTag(active: summary.supervisor.active),
              ],
            ),
            const SizedBox(height: 12),
            if (mode == _SuperuserAgileViewMode.wide) ...[
              Row(
                children: [
                  Expanded(
                    child: _MetricWithIndexBox(
                      icon: Icons.storefront,
                      iconColor: Colors.blue.shade700,
                      label: 'Productive Calls Target / Actual',
                      value: '$productiveTarget / $productiveActual',
                      indexValue: productiveIndex,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MetricWithIndexBox(
                      icon: Icons.payments_outlined,
                      iconColor: Colors.teal.shade700,
                      label: 'STT Target / Actual',
                      value: '${currency.format(sttTarget)} / ${currency.format(sttActual)}',
                      indexValue: sttIndex,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            if (mode == _SuperuserAgileViewMode.compact) ...[
              Row(
                children: [
                  Expanded(
                    child: _CompactIndexIcon(
                      icon: Icons.storefront,
                      label: 'Productive',
                      percent: productivePercent,
                      color: Colors.blue.shade700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _CompactIndexIcon(
                      icon: Icons.payments_outlined,
                      label: 'STT',
                      percent: sttPercent,
                      color: Colors.teal.shade700,
                    ),
                  ),
                ],
              ),
            ],
            if (mode == _SuperuserAgileViewMode.wide) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _openSalesmanPreview(context),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Preview Salesman Performance'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SalesmanPerformancePreviewPage extends StatelessWidget {
  final _SupervisorAgileSummary summary;
  final Map<String, AgileTarget> targetsBySalesman;
  final Map<String, AgileSubmission> submissionsBySalesman;

  const _SalesmanPerformancePreviewPage({
    required this.summary,
    required this.targetsBySalesman,
    required this.submissionsBySalesman,
  });

  String _displayName(AppUser user) {
    final trimmedName = user.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : user.email;
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '', decimalDigits: 2);
    return Scaffold(
      appBar: AppBar(
        title: Text('Salesmen: ${_displayName(summary.supervisor)}'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: summary.team.length,
        itemBuilder: (context, index) {
          final salesman = summary.team[index];
          final submission = submissionsBySalesman[salesman.uid];
          final target = targetsBySalesman[salesman.uid];
          final productiveActual = submission?.productiveCalls ?? 0;
          final sttActual = submission?.sttActual ?? 0.0;
          final productiveTarget = target?.productiveCallsTarget ?? 0;
          final sttTarget = target?.sttTarget ?? 0.0;
          final productiveIndex =
              productiveTarget == 0 ? 0.0 : productiveActual / productiveTarget;
          final sttIndex = sttTarget == 0 ? 0.0 : sttActual / sttTarget;

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
                              _displayName(salesman),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              salesman.email,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey.shade700,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      _StatusTag(active: salesman.active),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _MetricWithIndexBox(
                          icon: Icons.storefront,
                          iconColor: Colors.blue.shade700,
                          label: 'Productive Calls Target / Actual',
                          value: '$productiveTarget / $productiveActual',
                          indexValue: productiveIndex,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _MetricWithIndexBox(
                          icon: Icons.payments_outlined,
                          iconColor: Colors.teal.shade700,
                          label: 'STT Target / Actual',
                          value: '${currency.format(sttTarget)} / ${currency.format(sttActual)}',
                          indexValue: sttIndex,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AgileViewToggle extends StatelessWidget {
  final _SuperuserAgileViewMode mode;
  final ValueChanged<_SuperuserAgileViewMode> onChanged;

  const _AgileViewToggle({
    required this.mode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isExpanded = MediaQuery.sizeOf(context).width >= 700;
    return ToggleButtons(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      isSelected: [
        mode == _SuperuserAgileViewMode.wide,
        mode == _SuperuserAgileViewMode.compact,
      ],
      onPressed: (index) {
        onChanged(
          index == 0
              ? _SuperuserAgileViewMode.wide
              : _SuperuserAgileViewMode.compact,
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

class _SummaryMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryMetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.16),
              foregroundColor: color,
              child: Icon(icon),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
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

class _MetricWithIndexBox extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final double indexValue;

  const _MetricWithIndexBox({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.indexValue,
  });

  @override
  Widget build(BuildContext context) {
    final percent = (indexValue * 100).toStringAsFixed(1);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              'Index ${indexValue.toStringAsFixed(2)}x • $percent%',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.blueGrey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactIndexIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final double percent;
  final Color color;

  const _CompactIndexIcon({
    required this.icon,
    required this.label,
    required this.percent,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$label ${percent.toStringAsFixed(1)}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.blueGrey.shade700,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  final bool active;

  const _StatusTag({required this.active});

  @override
  Widget build(BuildContext context) {
    final bgColor = active ? Colors.green.shade50 : Colors.orange.shade50;
    final fgColor = active ? Colors.green.shade700 : Colors.orange.shade700;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        active ? 'Active' : 'Inactive',
        style: TextStyle(color: fgColor, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SuperuserAgileData {
  final String date;
  final List<_SupervisorAgileSummary> summaries;
  final Map<String, AgileTarget> targetsBySalesman;
  final Map<String, AgileSubmission> submissionsBySalesman;

  const _SuperuserAgileData({
    required this.date,
    required this.summaries,
    required this.targetsBySalesman,
    required this.submissionsBySalesman,
  });
}

class _SupervisorAgileSummary {
  final AppUser supervisor;
  final List<AppUser> team;

  const _SupervisorAgileSummary({
    required this.supervisor,
    required this.team,
  });
}
