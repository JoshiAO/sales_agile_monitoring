import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/agile_export_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/date_selector_widget.dart';

enum _SupervisorAgileViewMode { wide, compact }

enum _AgileExportChoice { selectedDate, dateRange }

class SupervisorAgilePage extends StatefulWidget {
  const SupervisorAgilePage({super.key});

  @override
  State<SupervisorAgilePage> createState() => _SupervisorAgilePageState();
}

class _SupervisorAgilePageState extends State<SupervisorAgilePage> {
  final FirestoreService _firestoreService = FirestoreService();
  final AgileExportService _agileExportService = AgileExportService();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late DateTime _selectedDate;
  late Future<_SupervisorAgileData> _pageFuture;
  _SupervisorAgileViewMode _viewMode = _SupervisorAgileViewMode.wide;
  bool _isSavingTargets = false;
  bool _isExporting = false;

  final Map<String, TextEditingController> _productiveTargetControllers = {};
  final Map<String, TextEditingController> _sttTargetControllers = {};

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _pageFuture = _loadPageData();
  }

  @override
  void dispose() {
    for (final controller in _productiveTargetControllers.values) {
      controller.dispose();
    }
    for (final controller in _sttTargetControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<_SupervisorAgileData> _loadPageData() async {
    final currentUser = context.read<AuthProvider>().currentUser;
    if (currentUser == null) {
      throw StateError('No authenticated supervisor found.');
    }

    final date = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final results = await Future.wait([
      _firestoreService.getSupervisorTeam(currentUser.uid),
      _firestoreService.getAgileTargetsForSupervisorByDate(
        supervisorId: currentUser.uid,
        date: date,
      ),
      _firestoreService.getAgileSubmissionsForSupervisorByDate(
        supervisorId: currentUser.uid,
        date: date,
      ),
    ]);

    final team = (results[0] as List<AppUser>).toList()
      ..sort(
        (left, right) => _displayName(left).compareTo(_displayName(right)),
      );
    final targetsBySalesman = results[1] as Map<String, AgileTarget>;
    final submissionsBySalesman = results[2] as Map<String, AgileSubmission>;

    _syncControllers(team, targetsBySalesman);

    return _SupervisorAgileData(
      date: date,
      team: team,
      targetsBySalesman: targetsBySalesman,
      submissionsBySalesman: submissionsBySalesman,
    );
  }

  void _syncControllers(
    List<AppUser> team,
    Map<String, AgileTarget> targetsBySalesman,
  ) {
    final activeIds = team.map((salesman) => salesman.uid).toSet();

    final staleProductiveIds = _productiveTargetControllers.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in staleProductiveIds) {
      _productiveTargetControllers.remove(id)?.dispose();
    }

    final staleSttIds = _sttTargetControllers.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in staleSttIds) {
      _sttTargetControllers.remove(id)?.dispose();
    }

    for (final salesman in team) {
      final target = targetsBySalesman[salesman.uid];
      _productiveTargetControllers.putIfAbsent(
        salesman.uid,
        () => TextEditingController(
          text: target?.productiveCallsTarget.toString() ?? '0',
        ),
      );
      _sttTargetControllers.putIfAbsent(
        salesman.uid,
        () => TextEditingController(
          text: (target?.sttTarget ?? 0.0).toStringAsFixed(2),
        ),
      );

      final productiveController = _productiveTargetControllers[salesman.uid]!;
      final sttController = _sttTargetControllers[salesman.uid]!;
      final expectedProductive =
          target?.productiveCallsTarget.toString() ?? '0';
      final expectedStt = (target?.sttTarget ?? 0.0).toStringAsFixed(2);

      if (productiveController.text != expectedProductive) {
        productiveController.text = expectedProductive;
      }
      if (sttController.text != expectedStt) {
        sttController.text = expectedStt;
      }
    }
  }

  String _displayName(AppUser user) {
    final trimmedName = user.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : user.email;
  }

  int _productiveTargetFor(String salesmanId) {
    final parsed = int.tryParse(
      _productiveTargetControllers[salesmanId]?.text ?? '',
    );
    if (parsed == null) return 0;
    return parsed.clamp(0, 100);
  }

  double _sttTargetFor(String salesmanId) {
    final parsed = double.tryParse(
      _sttTargetControllers[salesmanId]?.text ?? '',
    );
    if (parsed == null) return 0;
    return double.parse(parsed.toStringAsFixed(2));
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

    final compact = _viewMode == _SupervisorAgileViewMode.compact;
    final minCardWidth = compact ? 320.0 : 360.0;
    final columns = ((maxWidth + 12) / (minCardWidth + 12)).floor();
    return columns.clamp(2, 4);
  }

  void _onDateChanged(DateTime newDate) {
    setState(() {
      _selectedDate = newDate;
      _pageFuture = _loadPageData();
    });
  }

  Future<void> _saveAllTargets(_SupervisorAgileData data) async {
    final formValid = _formKey.currentState?.validate() ?? false;
    if (!formValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fix target validation errors.')),
      );
      return;
    }

    final currentUser = context.read<AuthProvider>().currentUser;
    if (currentUser == null) return;

    setState(() => _isSavingTargets = true);
    try {
      for (final salesman in data.team) {
        await _firestoreService.upsertAgileTarget(
          supervisorId: currentUser.uid,
          salesmanId: salesman.uid,
          date: data.date,
          productiveCallsTarget: _productiveTargetFor(salesman.uid),
          sttTarget: _sttTargetFor(salesman.uid),
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Targets saved successfully.')),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save targets: $error')));
    } finally {
      if (mounted) {
        setState(() => _isSavingTargets = false);
      }
    }
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

  Future<void> _exportAgile() async {
    if (_isExporting) return;
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) return;

    final range = await _pickExportRange();
    if (range == null || !mounted) return;

    setState(() => _isExporting = true);
    try {
      final result = await _agileExportService.exportSupervisorAgile(
        supervisor: user,
        startDate: range.start,
        endDate: range.end,
      );

      if (!mounted) return;
      await _showExportSuccessDialog(
        title: 'Export Complete',
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
    final compactActions = MediaQuery.sizeOf(context).width < 680;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agile'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: compactActions
                  ? IconButton(
                      tooltip: 'Export',
                      onPressed: _isExporting ? null : _exportAgile,
                      icon: _isExporting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.file_download_outlined),
                    )
                  : OutlinedButton.icon(
                      onPressed: _isExporting ? null : _exportAgile,
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: compactActions
                  ? IconButton(
                      tooltip: 'Save',
                      onPressed: _isSavingTargets
                          ? null
                          : () async {
                              try {
                                final data = await _pageFuture;
                                if (!context.mounted) return;
                                await _saveAllTargets(data);
                              } catch (_) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Unable to save targets right now.',
                                    ),
                                  ),
                                );
                              }
                            },
                      icon: _isSavingTargets
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                    )
                  : FilledButton.icon(
                      onPressed: _isSavingTargets
                          ? null
                          : () async {
                              try {
                                final data = await _pageFuture;
                                if (!context.mounted) return;
                                await _saveAllTargets(data);
                              } catch (_) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Unable to save targets right now.',
                                    ),
                                  ),
                                );
                              }
                            },
                      icon: _isSavingTargets
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined, size: 18),
                      label: const Text('Save'),
                    ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<_SupervisorAgileData>(
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
                      'Unable to load supervisor agile data.',
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
          final totalProductive = data.team
              .map(
                (salesman) =>
                    data.submissionsBySalesman[salesman.uid]?.productiveCalls ??
                    0,
              )
              .fold<int>(0, (sum, value) => sum + value);
          final totalActualSale = data.team
              .map(
                (salesman) =>
                    data.submissionsBySalesman[salesman.uid]?.sttActual ?? 0.0,
              )
              .fold<double>(0.0, (sum, value) => sum + value);

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

          return RefreshIndicator(
            onRefresh: _refresh,
            child: Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = _cardsPerRow(constraints.maxWidth);
                  const spacing = 12.0;
                  final cardExtent = _viewMode == _SupervisorAgileViewMode.wide
                      ? 294.0
                      : 118.0;

                  return ListView(
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
                                final compactHeader =
                                    headerConstraints.maxWidth < 760;

                                final headerText = Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Agile Team Performance',
                                      style:
                                          Theme.of(context).textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${data.team.length} team member${data.team.length == 1 ? '' : 's'} • Date: ${data.date}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Colors.grey.shade700,
                                          ),
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                  label: 'Team Total Productive Calls',
                                  value: '$totalProductive',
                                  icon: Icons.storefront,
                                  color: Colors.blue,
                                );
                                final second = _SummaryMetricCard(
                                  label: 'Team Total Actual Sale',
                                  value: currency.format(totalActualSale),
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
                          final submission =
                              data.submissionsBySalesman[salesman.uid];
                          final productiveActual =
                              submission?.productiveCalls ?? 0;
                          final sttActual = submission?.sttActual ?? 0.0;
                          final productiveTarget = _productiveTargetFor(
                            salesman.uid,
                          );
                          final sttTarget = _sttTargetFor(salesman.uid);

                          return _SupervisorSalesmanAgileCard(
                            salesman: salesman,
                            productiveTargetController:
                                _productiveTargetControllers[salesman.uid]!,
                            sttTargetController:
                                _sttTargetControllers[salesman.uid]!,
                            productiveActual: productiveActual,
                            sttActual: sttActual,
                            productiveTarget: productiveTarget,
                            sttTarget: sttTarget,
                            mode: _viewMode,
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SupervisorSalesmanAgileCard extends StatelessWidget {
  final AppUser salesman;
  final TextEditingController productiveTargetController;
  final TextEditingController sttTargetController;
  final int productiveActual;
  final double sttActual;
  final int productiveTarget;
  final double sttTarget;
  final _SupervisorAgileViewMode mode;

  const _SupervisorSalesmanAgileCard({
    required this.salesman,
    required this.productiveTargetController,
    required this.sttTargetController,
    required this.productiveActual,
    required this.sttActual,
    required this.productiveTarget,
    required this.sttTarget,
    required this.mode,
  });

  String get _displayName {
    final trimmedName = salesman.name?.trim() ?? '';
    return trimmedName.isNotEmpty ? trimmedName : salesman.email;
  }

  bool get _showEmailLine {
    return _displayName.toLowerCase() != salesman.email.trim().toLowerCase();
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
                        _displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (_showEmailLine) ...[
                        const SizedBox(height: 4),
                        Text(
                          salesman.email,
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
                _StatusTag(active: salesman.active),
              ],
            ),
            const SizedBox(height: 10),
            if (mode == _SupervisorAgileViewMode.wide) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 620;

                  final productiveField = TextFormField(
                    controller: productiveTargetController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Productive Calls Target',
                      hintText: 'Enter target (0-100)',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    validator: (value) {
                      final parsed = int.tryParse((value ?? '').trim());
                      if (parsed == null) return 'Target is required';
                      if (parsed < 0 || parsed > 100) {
                        return 'Target must be between 0 and 100';
                      }
                      return null;
                    },
                  );

                  final sttField = TextFormField(
                    controller: sttTargetController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: const [_TwoDecimalInputFormatter()],
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'STT Target for today',
                      hintText: 'e.g. 5000.00',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    validator: (value) {
                      final text = (value ?? '').trim();
                      if (text.isEmpty) return 'STT target is required';
                      if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text)) {
                        return 'Use numeric format, max 2 decimals';
                      }
                      return null;
                    },
                  );

                  if (stacked) {
                    return Column(
                      children: [
                        productiveField,
                        const SizedBox(height: 10),
                        sttField,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: productiveField),
                      const SizedBox(width: 10),
                      Expanded(child: sttField),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: LayoutBuilder(
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
                  ),
                ],
              ),
            ],
            if (mode == _SupervisorAgileViewMode.compact) ...[
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

class _AgileViewToggle extends StatelessWidget {
  final _SupervisorAgileViewMode mode;
  final ValueChanged<_SupervisorAgileViewMode> onChanged;

  const _AgileViewToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isExpanded = MediaQuery.sizeOf(context).width >= 700;
    return ToggleButtons(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      isSelected: [
        mode == _SupervisorAgileViewMode.wide,
        mode == _SupervisorAgileViewMode.compact,
      ],
      onPressed: (index) {
        onChanged(
          index == 0
              ? _SupervisorAgileViewMode.wide
              : _SupervisorAgileViewMode.compact,
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

class _TwoDecimalInputFormatter extends TextInputFormatter {
  const _TwoDecimalInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;

    final isValid = RegExp(r'^\d*(\.\d{0,2})?$').hasMatch(newValue.text);
    return isValid ? newValue : oldValue;
  }
}

class _SupervisorAgileData {
  final String date;
  final List<AppUser> team;
  final Map<String, AgileTarget> targetsBySalesman;
  final Map<String, AgileSubmission> submissionsBySalesman;

  const _SupervisorAgileData({
    required this.date,
    required this.team,
    required this.targetsBySalesman,
    required this.submissionsBySalesman,
  });
}
