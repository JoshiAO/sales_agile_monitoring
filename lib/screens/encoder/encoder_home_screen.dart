import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/widgets/device_activation_banner.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/si_booklet_manager_dialog.dart';

class EncoderHomeScreen extends StatefulWidget {
  final ValueChanged<String>? onOpenSalesmanTransactions;

  const EncoderHomeScreen({
    super.key,
    this.onOpenSalesmanTransactions,
  });

  @override
  State<EncoderHomeScreen> createState() => _EncoderHomeScreenState();
}

class _EncoderHomeScreenState extends State<EncoderHomeScreen> {
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');
  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd');
  static final DateFormat _timeFormat = DateFormat('h:mm a');

  final FirestoreService _firestoreService = FirestoreService();

  bool _isLoading = true;
  String? _errorMessage;
  List<AppUser> _assignedSalesmen = [];
  Map<String, List<RouteTransaction>> _todayTransactionsBySalesman = {};
  CompanySiRegistry _companyRegistry = const CompanySiRegistry(companyId: '');

  String get _todayStr => _dateFormat.format(DateTime.now());

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String _displayName(AppUser user) {
    final name = user.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    return user.email;
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final currentUser = context.read<AuthProvider>().currentUser;
      if (currentUser == null) {
        setState(() {
          _assignedSalesmen = [];
          _todayTransactionsBySalesman = {};
          _isLoading = false;
        });
        return;
      }

      final assigned = await _firestoreService.getSalesmenByEncoder(
        currentUser.uid,
        companyId: currentUser.companyId,
      );
      assigned.sort(
        (a, b) => _displayName(a).toLowerCase().compareTo(
          _displayName(b).toLowerCase(),
        ),
      );

      final ids = assigned.map((u) => u.uid).toList();
      final today = _todayStr;
      final companyId = currentUser.companyId?.trim() ?? '';
      final results = await Future.wait<dynamic>([
        ids.isEmpty
            ? Future.value(const <SalesRoute>[])
            : _firestoreService.getRoutesBySalesmenAndDateRange(
                salesmanIds: ids,
                startDate: today,
                endDate: today,
              ),
        companyId.isEmpty
            ? Future.value(const CompanySiRegistry(companyId: ''))
            : _firestoreService
                .getCompanySiRegistry(companyId)
                .catchError((_) => CompanySiRegistry(companyId: companyId)),
      ]);
      final routes = results[0] as List<SalesRoute>;
      final registry = results[1] as CompanySiRegistry;

      final grouped = <String, List<RouteTransaction>>{
        for (final s in assigned) s.uid: <RouteTransaction>[],
      };
      for (final route in routes) {
        grouped
            .putIfAbsent(route.salesmanId, () => <RouteTransaction>[])
            .addAll(route.transactions);
      }
      for (final list in grouped.values) {
        list.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      }

      if (!mounted) return;
      setState(() {
        _assignedSalesmen = assigned;
        _todayTransactionsBySalesman = grouped;
        _companyRegistry = registry;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load encoder overview: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allTxs = _todayTransactionsBySalesman.values
        .expand((list) => list)
        .toList();
    final totalInvoices = allTxs.length;
    final totalSales = allTxs.fold<double>(
      0.0,
      (sum, tx) => sum + tx.totalAmount,
    );
    final syncedSalesmenCount = _assignedSalesmen
        .where((s) => (_todayTransactionsBySalesman[s.uid] ?? const []).isNotEmpty)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Encoder Overview'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _loadData,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DeviceActivationBannerWrapper(
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _loadData,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      'Today\'s Transaction Summary ($_todayStr)',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _KpiCard(
                          icon: Icons.people_outline,
                          label: 'Assigned Salesmen',
                          value: '${_assignedSalesmen.length}',
                          accent: Colors.indigo,
                        ),
                        _KpiCard(
                          icon: Icons.cloud_done_outlined,
                          label: 'Active / Synced Today',
                          value:
                              '$syncedSalesmenCount / ${_assignedSalesmen.length}',
                          accent: Colors.green.shade700,
                        ),
                        _KpiCard(
                          icon: Icons.receipt_long_outlined,
                          label: 'Captured Invoices',
                          value: '$totalInvoices',
                          accent: Colors.teal.shade700,
                        ),
                        _KpiCard(
                          icon: Icons.payments_outlined,
                          label: 'Total Sales Today',
                          value: '₱${_moneyFormat.format(totalSales)}',
                          accent: Colors.deepPurple,
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'Assigned Salesmen',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_assignedSalesmen.isEmpty)
                      Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.grey.shade300),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text(
                            'No salesmen are currently assigned to your account. Ask an Admin to assign salesmen to you in User Management.',
                          ),
                        ),
                      )
                    else
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = constraints.maxWidth >= 1080
                              ? 3
                              : constraints.maxWidth >= 680
                                  ? 2
                                  : 1;
                          const spacing = 12.0;
                          final cardWidth =
                              (constraints.maxWidth - ((columns - 1) * spacing)) /
                              columns;

                          return Wrap(
                            spacing: spacing,
                            runSpacing: spacing,
                            children: _assignedSalesmen.map((salesman) {
                              final txs =
                                  _todayTransactionsBySalesman[salesman.uid] ??
                                  const [];
                              final salesTotal = txs.fold<double>(
                                0.0,
                                (sum, tx) => sum + tx.totalAmount,
                              );
                              final latestSync =
                                  txs.isNotEmpty ? txs.first.capturedAt : null;
                              final isSynced = txs.isNotEmpty;
                              final bookletEntries = _companyRegistry
                                  .entriesForSalesman(salesman.uid);
                              final remainingSi = bookletEntries.fold<int>(
                                0,
                                (sum, e) => sum + e.remainingPages,
                              );
                              final activeEntry = bookletEntries
                                  .where((e) => !e.isExhausted)
                                  .firstOrNull;
                              final currentUser =
                                  context.read<AuthProvider>().currentUser;

                              return SizedBox(
                                width: cardWidth,
                                child: Card(
                                  margin: EdgeInsets.zero,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(color: Colors.grey.shade300),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: widget.onOpenSalesmanTransactions ==
                                            null
                                        ? null
                                        : () => widget
                                            .onOpenSalesmanTransactions!(
                                            salesman.uid,
                                          ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(14),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _displayName(salesman),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 3,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: isSynced
                                                      ? Colors.green.shade50
                                                      : Colors.orange.shade50,
                                                  borderRadius:
                                                      BorderRadius.circular(999),
                                                ),
                                                child: Text(
                                                  isSynced
                                                      ? 'Synced'
                                                      : 'No Uploads Yet',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w700,
                                                    color: isSynced
                                                        ? Colors.green.shade800
                                                        : Colors.orange.shade800,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            salesman.email,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: _MiniStatBox(
                                                  label: 'Transactions',
                                                  value: '${txs.length}',
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: _MiniStatBox(
                                                  label: 'Total Sales',
                                                  value:
                                                      '₱${_moneyFormat.format(salesTotal)}',
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 10),
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.schedule,
                                                size: 14,
                                                color: Colors.grey.shade600,
                                              ),
                                              const SizedBox(width: 4),
                                              Expanded(
                                                child: Text(
                                                  latestSync == null
                                                      ? 'Last sync: None today'
                                                      : 'Last sync: ${_timeFormat.format(latestSync.toLocal())}',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey.shade700,
                                                  ),
                                                ),
                                              ),
                                              if (widget
                                                      .onOpenSalesmanTransactions !=
                                                  null)
                                                Text(
                                                  'View →',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.teal.shade700,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 10),
                                          const Divider(height: 1),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: activeEntry != null
                                                        ? Colors.teal.shade50
                                                        : Colors.amber.shade50,
                                                    borderRadius:
                                                        BorderRadius.circular(6),
                                                  ),
                                                  child: Text(
                                                    activeEntry != null
                                                        ? 'SI: ${activeEntry.nextFormatted} ($remainingSi left)'
                                                        : (bookletEntries
                                                                .isEmpty
                                                            ? 'No SI Booklet'
                                                            : 'SI Exhausted'),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: activeEntry != null
                                                          ? Colors.teal.shade900
                                                          : Colors
                                                              .amber.shade900,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              if (currentUser != null)
                                                OutlinedButton.icon(
                                                  style: OutlinedButton.styleFrom(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 10,
                                                      vertical: 4,
                                                    ),
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                  ),
                                                  onPressed: () async {
                                                    final changed =
                                                        await showSiBookletManagerDialog(
                                                      context,
                                                      salesman: salesman,
                                                      actor: currentUser,
                                                      hasActiveRouteToday:
                                                          isSynced,
                                                    );
                                                    if (changed && mounted) {
                                                      _loadData();
                                                    }
                                                  },
                                                  icon: const Icon(
                                                    Icons.menu_book_outlined,
                                                    size: 15,
                                                  ),
                                                  label: const Text(
                                                    'SI Booklets',
                                                    style: TextStyle(
                                                      fontSize: 11.5,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                  ],
                ),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  const _KpiCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            backgroundColor: accent.withValues(alpha: 0.12),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStatBox extends StatelessWidget {
  final String label;
  final String value;

  const _MiniStatBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

