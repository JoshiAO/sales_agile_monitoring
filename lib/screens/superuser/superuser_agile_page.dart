import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/agile_export_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/date_selector_widget.dart';
import 'package:url_launcher/url_launcher.dart';

enum _SuperuserAgileViewMode { wide, compact }

enum _AgileExportChoice { selectedDate, dateRange }

class SuperuserAgilePage extends StatefulWidget {
  const SuperuserAgilePage({super.key});

  @override
  State<SuperuserAgilePage> createState() => _SuperuserAgilePageState();
}

class _SuperuserAgilePageState extends State<SuperuserAgilePage> {
  final FirestoreService _firestoreService = FirestoreService();
  final AgileExportService _agileExportService = AgileExportService();

  late DateTime _selectedDate;
  late Future<_SuperuserAgileData> _pageFuture;
  _SuperuserAgileViewMode _viewMode = _SuperuserAgileViewMode.wide;
  bool _isExporting = false;

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
      ..sort(
        (left, right) => _displayName(left).compareTo(_displayName(right)),
      );
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
      team.sort(
        (left, right) => _displayName(left).compareTo(_displayName(right)),
      );
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

  int _cardsPerRow(double maxWidth) {
    final isMobileLayout = maxWidth < 700;
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
      _pageFuture = _loadPageData();
    });
  }

  Future<DateTimeRange?> _pickExportRange() async {
    final choice = await showDialog<_AgileExportChoice>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Export Agile Data'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(_AgileExportChoice.selectedDate),
            child: const Text('Present Date'),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_AgileExportChoice.dateRange),
            child: const Text('Specific Date Range'),
          ),
        ],
      ),
    );

    if (choice == null) return null;
    if (choice == _AgileExportChoice.selectedDate) {
      return DateTimeRange(start: _selectedDate, end: _selectedDate);
    }
    if (!mounted) return null;

    final now = DateTime.now();
    return showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: DateTimeRange(start: _selectedDate, end: _selectedDate),
      saveText: 'Export',
    );
  }

  Future<void> _exportAgileZip() async {
    if (_isExporting) return;

    final range = await _pickExportRange();
    if (range == null || !mounted) return;

    setState(() => _isExporting = true);
    try {
      final result = await _agileExportService.exportSuperuserAgileZip(
        startDate: range.start,
        endDate: range.end,
      );

      if (!mounted) return;
      await _showExportSuccessDialog(
        title: 'ZIP Export Complete',
        fileName: result.fileName,
        outputPath: result.outputPath,
        rowCount: result.rowCount,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _showExportSuccessDialog({
    required String title,
    required String fileName,
    required String outputPath,
    required int rowCount,
  }) async {
    final normalizedOutputPath = outputPath.replaceAll('\\', '/');
    final separatorIndex = normalizedOutputPath.lastIndexOf('/');
    final normalizedFolderPath = separatorIndex > 0
        ? normalizedOutputPath.substring(0, separatorIndex)
        : normalizedOutputPath;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Rows exported: $rowCount'),
              const SizedBox(height: 8),
              Text('File: $fileName'),
              const SizedBox(height: 8),
              const Text(
                'Saved to:',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              SelectableText(outputPath),
            ],
          ),
          actions: [
            if (!kIsWeb)
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: outputPath));
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(const SnackBar(content: Text('Path copied')));
                },
                child: const Text('Copy Path'),
              ),
            if (!kIsWeb)
              TextButton(
                onPressed: () =>
                    _openExportFolder(dialogContext, normalizedFolderPath),
                child: const Text('Open Folder'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openExportFolder(
    BuildContext dialogContext,
    String folderPath,
  ) async {
    final normalized = folderPath.replaceAll('\\', '/');

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        const intent = AndroidIntent(
          action: 'android.intent.action.VIEW_DOWNLOADS',
        );
        await intent.launch();
        return;
      } catch (_) {
        // Fallback to URL launcher below.
      }
    }

    Uri? uri;
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux) {
      uri = Uri.file(normalized);
    }

    if (uri == null) {
      if (!dialogContext.mounted) return;
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(
          content: Text('Open folder is not supported on this platform.'),
        ),
      );
      return;
    }

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && dialogContext.mounted) {
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(content: Text('Unable to open folder. Try Copy Path.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '', decimalDigits: 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agile'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: OutlinedButton.icon(
                onPressed: _isExporting ? null : _exportAgileZip,
                icon: _isExporting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Export'),
              ),
            ),
          ),
        ],
      ),
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
          final filtered = data.summaries;

          final overallProductive = data.summaries
              .expand((summary) => summary.team)
              .map(
                (salesman) =>
                    data.submissionsBySalesman[salesman.uid]?.productiveCalls ??
                    0,
              )
              .fold<int>(0, (sum, value) => sum + value);
          final overallSale = data.summaries
              .expand((summary) => summary.team)
              .map(
                (salesman) =>
                    data.submissionsBySalesman[salesman.uid]?.sttActual ?? 0.0,
              )
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
                  Text('No supervisors found.', textAlign: TextAlign.center),
                ],
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final columns = _cardsPerRow(constraints.maxWidth);
              const spacing = 12.0;
              const horizontalListPadding = 32.0;
              final scrollbarCompensation = kIsWeb ? 14.0 : 0.0;
              final availableWidth =
                  constraints.maxWidth -
                  horizontalListPadding -
                  ((columns - 1) * spacing) -
                  scrollbarCompensation;
              final cardWidth = (availableWidth / columns)
                  .floorToDouble()
                  .clamp(0.0, constraints.maxWidth);

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
                          LayoutBuilder(
                            builder: (context, headerConstraints) {
                              final compactHeader = headerConstraints.maxWidth <
                                  760;

                              final headerText = Column(
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
                              );

                              final toggle = _AgileViewToggle(
                                mode: _viewMode,
                                onChanged: (mode) {
                                  setState(() {
                                    _viewMode = mode;
                                  });
                                },
                              );

                              if (compactHeader) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    headerText,
                                    const SizedBox(height: 10),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: toggle,
                                    ),
                                  ],
                                );
                              }

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: headerText),
                                  const SizedBox(width: 12),
                                  toggle,
                                ],
                              );
                            },
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
                    ),
                    Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: filtered.map((summary) {
                        final teamProductiveTarget = summary.team
                            .map(
                              (salesman) =>
                                  data
                                      .targetsBySalesman[salesman.uid]
                                      ?.productiveCallsTarget ??
                                  0,
                            )
                            .fold<int>(0, (sum, value) => sum + value);
                        final teamProductiveActual = summary.team
                            .map(
                              (salesman) =>
                                  data
                                      .submissionsBySalesman[salesman.uid]
                                      ?.productiveCalls ??
                                  0,
                            )
                            .fold<int>(0, (sum, value) => sum + value);
                        final teamSttTarget = summary.team
                            .map(
                              (salesman) =>
                                  data
                                      .targetsBySalesman[salesman.uid]
                                      ?.sttTarget ??
                                  0.0,
                            )
                            .fold<double>(0.0, (sum, value) => sum + value);
                        final teamSttActual = summary.team
                            .map(
                              (salesman) =>
                                  data
                                      .submissionsBySalesman[salesman.uid]
                                      ?.sttActual ??
                                  0.0,
                            )
                            .fold<double>(0.0, (sum, value) => sum + value);

                        return SizedBox(
                          width: cardWidth,
                          child: _SupervisorAggregateCard(
                            summary: summary,
                            mode: _viewMode,
                            productiveTarget: teamProductiveTarget,
                            productiveActual: teamProductiveActual,
                            sttTarget: teamSttTarget,
                            sttActual: teamSttActual,
                            targetsBySalesman: data.targetsBySalesman,
                            submissionsBySalesman: data.submissionsBySalesman,
                          ),
                        );
                      }).toList(),
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

  bool get _showEmailLine {
    return _displayName(summary.supervisor).toLowerCase() !=
        summary.supervisor.email.trim().toLowerCase();
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayName(summary.supervisor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (_showEmailLine) ...[
                        const SizedBox(height: 4),
                        Text(
                          summary.supervisor.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey.shade700),
                        ),
                      ] else ...[
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _StatusTag(active: summary.supervisor.active),
              ],
            ),
            const SizedBox(height: 10),
            if (mode == _SuperuserAgileViewMode.wide) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 560;

                  final productiveBox = _MetricWithIndexBox(
                    icon: Icons.storefront,
                    iconColor: Colors.blue.shade700,
                    label: 'Productive Calls Target / Actual',
                    value: '$productiveTarget / $productiveActual',
                    indexValue: productiveIndex,
                  );

                  final sttBox = _MetricWithIndexBox(
                    icon: Icons.payments_outlined,
                    iconColor: Colors.teal.shade700,
                    label: 'STT Target / Actual',
                    value:
                        '${currency.format(sttTarget)} / ${currency.format(sttActual)}',
                    indexValue: sttIndex,
                  );

                  if (stacked) {
                    return Column(
                      children: [
                        productiveBox,
                        const SizedBox(height: 10),
                        sttBox,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: productiveBox),
                      const SizedBox(width: 10),
                      Expanded(child: sttBox),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
            ],
            if (mode == _SuperuserAgileViewMode.compact) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 460;

                  final productiveIcon = _CompactIndexIcon(
                    icon: Icons.storefront,
                    label: 'Productive',
                    percent: productivePercent,
                    color: Colors.blue.shade700,
                  );
                  final sttIcon = _CompactIndexIcon(
                    icon: Icons.payments_outlined,
                    label: 'STT',
                    percent: sttPercent,
                    color: Colors.teal.shade700,
                  );

                  if (stacked) {
                    return Column(
                      children: [
                        productiveIcon,
                        const SizedBox(height: 10),
                        sttIcon,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: productiveIcon),
                      const SizedBox(width: 10),
                      Expanded(child: sttIcon),
                    ],
                  );
                },
              ),
            ],
            if (mode == _SuperuserAgileViewMode.wide) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: () => _openSalesmanPreview(context),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Preview Salesman Performance'),
                ),
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          final columns = maxWidth >= 1200
              ? 4
              : maxWidth >= 920
              ? 3
              : maxWidth >= 620
              ? 2
              : 1;
          final cardExtent = columns == 1 ? 312.0 : 278.0;

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              mainAxisExtent: cardExtent,
            ),
            itemCount: summary.team.length,
            itemBuilder: (context, index) {
              final salesman = summary.team[index];
              final submission = submissionsBySalesman[salesman.uid];
              final target = targetsBySalesman[salesman.uid];
              final productiveActual = submission?.productiveCalls ?? 0;
              final sttActual = submission?.sttActual ?? 0.0;
              final productiveTarget = target?.productiveCallsTarget ?? 0;
              final sttTarget = target?.sttTarget ?? 0.0;
              final productiveIndex = productiveTarget == 0
                  ? 0.0
                  : productiveActual / productiveTarget;
              final sttIndex = sttTarget == 0 ? 0.0 : sttActual / sttTarget;
              return Card(
                margin: EdgeInsets.zero,
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
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  salesman.email,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: Colors.grey.shade700),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          _StatusTag(active: salesman.active),
                        ],
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, metricConstraints) {
                          final stacked = metricConstraints.maxWidth < 560;

                          final productiveBox = _MetricWithIndexBox(
                            icon: Icons.storefront,
                            iconColor: Colors.blue.shade700,
                            label: 'Productive Calls Target / Actual',
                            value: '$productiveTarget / $productiveActual',
                            indexValue: productiveIndex,
                          );
                          final sttBox = _MetricWithIndexBox(
                            icon: Icons.payments_outlined,
                            iconColor: Colors.teal.shade700,
                            label: 'STT Target / Actual',
                            value:
                                '${currency.format(sttTarget)} / ${currency.format(sttActual)}',
                            indexValue: sttIndex,
                          );

                          if (stacked) {
                            return Column(
                              children: [
                                productiveBox,
                                const SizedBox(height: 10),
                                sttBox,
                              ],
                            );
                          }

                          return Row(
                            children: [
                              Expanded(child: productiveBox),
                              const SizedBox(width: 10),
                              Expanded(child: sttBox),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AgileViewToggle extends StatelessWidget {
  final _SuperuserAgileViewMode mode;
  final ValueChanged<_SuperuserAgileViewMode> onChanged;

  const _AgileViewToggle({required this.mode, required this.onChanged});

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
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
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
        padding: const EdgeInsets.all(10),
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
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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

  const _SupervisorAgileSummary({required this.supervisor, required this.team});
}
