import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/widgets/device_activation_banner.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/constants/app_constants.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/transaction_export_service.dart';
import 'package:compact_sales_monitoring/widgets/fullscreen_invoice_lightbox.dart';

enum _SalesmanSortOption {
  nameAsc,
  nameDesc,
  emailAsc,
  emailDesc,
}

class WebTransactionsPage extends StatefulWidget {
  final String? initialSelectedSalesmanId;

  const WebTransactionsPage({
    super.key,
    this.initialSelectedSalesmanId,
  });

  @override
  State<WebTransactionsPage> createState() => _WebTransactionsPageState();
}

class _WebTransactionsPageState extends State<WebTransactionsPage> {
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');
  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd');
  static final DateFormat _displayDateFormat = DateFormat('MMM d, yyyy');
  static final DateFormat _timeFormat = DateFormat('h:mm a');

  final FirestoreService _firestoreService = FirestoreService();
  final TransactionExportService _exportService = TransactionExportService();
  final TextEditingController _searchController = TextEditingController();

  DateTime _startDate = _normalizeDate(DateTime.now());
  DateTime _endDate = _normalizeDate(DateTime.now());
  _SalesmanSortOption _sortOption = _SalesmanSortOption.nameAsc;
  String _searchQuery = '';

  List<AppUser> _coveredSalesmen = [];
  Map<String, List<RouteTransaction>> _transactionsBySalesman = {};
  String? _selectedSalesmanId;
  bool _isLoading = true;
  bool _isExporting = false;
  String? _errorMessage;

  static DateTime _normalizeDate(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    _selectedSalesmanId = widget.initialSelectedSalesmanId;
    _searchController.addListener(() {
      final next = _searchController.text.trim();
      if (next != _searchQuery) {
        setState(() => _searchQuery = next);
      }
    });
    if (AppConstants.enableTransactionsFeature) {
      _loadData();
    } else {
      _isLoading = false;
    }
  }

  @override
  void didUpdateWidget(covariant WebTransactionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSelectedSalesmanId != null &&
        widget.initialSelectedSalesmanId != oldWidget.initialSelectedSalesmanId) {
      setState(() {
        _selectedSalesmanId = widget.initialSelectedSalesmanId;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _displayName(AppUser user) {
    final name = user.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    return user.email;
  }

  String _sortLabel(_SalesmanSortOption option) {
    switch (option) {
      case _SalesmanSortOption.nameAsc:
        return 'Name (A–Z)';
      case _SalesmanSortOption.nameDesc:
        return 'Name (Z–A)';
      case _SalesmanSortOption.emailAsc:
        return 'Email (A–Z)';
      case _SalesmanSortOption.emailDesc:
        return 'Email (Z–A)';
    }
  }

  String _dateRangeLabel() {
    if (_startDate == _endDate) {
      return _displayDateFormat.format(_startDate);
    }
    return '${_displayDateFormat.format(_startDate)} – ${_displayDateFormat.format(_endDate)}';
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
          _coveredSalesmen = [];
          _transactionsBySalesman = {};
          _isLoading = false;
        });
        return;
      }

      final companyId = currentUser.companyId;
      List<AppUser> rawSalesmen;
      switch (currentUser.role) {
        case UserRole.superuser:
        case UserRole.manager:
          rawSalesmen = (companyId != null && companyId.isNotEmpty)
              ? await _firestoreService.getUsersByRoleAndCompany(
                  UserRole.salesman,
                  companyId,
                )
              : await _firestoreService.getUsersByRole(UserRole.salesman);
          break;
        case UserRole.supervisor:
          rawSalesmen = await _firestoreService.getSupervisorTeam(
            currentUser.uid,
          );
          break;
        case UserRole.encoder:
          rawSalesmen = await _firestoreService.getSalesmenByEncoder(
            currentUser.uid,
            companyId: companyId,
          );
          break;
        case UserRole.salesman:
          rawSalesmen = const [];
          break;
      }

      // Only Van Ex-Truck salesmen capture transactions.
      final vanSalesmen = rawSalesmen.where((u) => u.isVanExTruck).toList();
      final salesmanIds = vanSalesmen.map((u) => u.uid).toList();

      final startStr = _dateFormat.format(_startDate);
      final endStr = _dateFormat.format(_endDate);

      List<SalesRoute> routes = const [];
      if (salesmanIds.isNotEmpty) {
        if ((currentUser.role == UserRole.superuser ||
                currentUser.role == UserRole.manager) &&
            companyId != null &&
            companyId.isNotEmpty) {
          routes = await _firestoreService.getAllRoutesByDateRangeAndCompany(
            companyId: companyId,
            startDate: startStr,
            endDate: endStr,
          );
        } else {
          routes = await _firestoreService.getRoutesBySalesmenAndDateRange(
            salesmanIds: salesmanIds,
            startDate: startStr,
            endDate: endStr,
          );
        }
      }

      final allowedSet = salesmanIds.toSet();
      final grouped = <String, List<RouteTransaction>>{
        for (final s in vanSalesmen) s.uid: <RouteTransaction>[],
      };

      for (final route in routes) {
        if (!allowedSet.contains(route.salesmanId)) continue;
        final list = grouped.putIfAbsent(
          route.salesmanId,
          () => <RouteTransaction>[],
        );
        list.addAll(route.transactions);
      }

      for (final entry in grouped.entries) {
        entry.value.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      }

      if (!mounted) return;
      setState(() {
        _coveredSalesmen = vanSalesmen;
        _transactionsBySalesman = grouped;
        if (_selectedSalesmanId == null ||
            !vanSalesmen.any((u) => u.uid == _selectedSalesmanId)) {
          final sorted = _sortedFilteredSalesmen(
            vanSalesmen,
            query: '',
            sort: _sortOption,
          );
          _selectedSalesmanId = sorted.isNotEmpty ? sorted.first.uid : null;
        }
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load transactions: $e';
        _isLoading = false;
      });
    }
  }

  List<AppUser> _sortedFilteredSalesmen(
    List<AppUser> source, {
    required String query,
    required _SalesmanSortOption sort,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? List<AppUser>.from(source)
        : source.where((u) {
            final name = (u.name ?? '').toLowerCase();
            final email = u.email.toLowerCase();
            return name.contains(normalizedQuery) ||
                email.contains(normalizedQuery);
          }).toList();

    filtered.sort((a, b) {
      switch (sort) {
        case _SalesmanSortOption.nameAsc:
          return _displayName(a).toLowerCase().compareTo(
            _displayName(b).toLowerCase(),
          );
        case _SalesmanSortOption.nameDesc:
          return _displayName(b).toLowerCase().compareTo(
            _displayName(a).toLowerCase(),
          );
        case _SalesmanSortOption.emailAsc:
          return a.email.toLowerCase().compareTo(b.email.toLowerCase());
        case _SalesmanSortOption.emailDesc:
          return b.email.toLowerCase().compareTo(a.email.toLowerCase());
      }
    });
    return filtered;
  }

  Future<void> _showDateSelectionDialog() async {
    var mode = _startDate == _endDate ? 'single' : 'range';
    var tempStart = _startDate;
    var tempEnd = _endDate;
    final today = _normalizeDate(DateTime.now());

    final applied = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            title: const Text('Select Transaction Date'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'single',
                        label: Text('Single Date'),
                        icon: Icon(Icons.today, size: 16),
                      ),
                      ButtonSegment(
                        value: 'range',
                        label: Text('Date Range'),
                        icon: Icon(Icons.date_range, size: 16),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (sel) {
                      setDialogState(() {
                        mode = sel.first;
                        if (mode == 'single') {
                          tempEnd = tempStart;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  if (mode == 'single')
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.calendar_today),
                      title: const Text('Date'),
                      subtitle: Text(_displayDateFormat.format(tempStart)),
                      trailing: OutlinedButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: tempStart,
                            firstDate: DateTime(2024),
                            lastDate: today,
                          );
                          if (picked != null) {
                            setDialogState(() {
                              tempStart = _normalizeDate(picked);
                              tempEnd = tempStart;
                            });
                          }
                        },
                        child: const Text('Pick'),
                      ),
                    )
                  else ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text('Start Date'),
                      subtitle: Text(_displayDateFormat.format(tempStart)),
                      trailing: OutlinedButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: tempStart,
                            firstDate: DateTime(2024),
                            lastDate: today,
                          );
                          if (picked != null) {
                            setDialogState(() {
                              tempStart = _normalizeDate(picked);
                              if (tempEnd.isBefore(tempStart)) {
                                tempEnd = tempStart;
                              }
                            });
                          }
                        },
                        child: const Text('Pick'),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event_available),
                      title: const Text('End Date'),
                      subtitle: Text(_displayDateFormat.format(tempEnd)),
                      trailing: OutlinedButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: tempEnd.isBefore(tempStart)
                                ? tempStart
                                : tempEnd,
                            firstDate: tempStart,
                            lastDate: today,
                          );
                          if (picked != null) {
                            setDialogState(() {
                              tempEnd = _normalizeDate(picked);
                            });
                          }
                        },
                        child: const Text('Pick'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );

    if (applied == true && mounted) {
      setState(() {
        _startDate = tempStart;
        _endDate = mode == 'single' ? tempStart : tempEnd;
      });
      await _loadData();
    }
  }

  Future<void> _exportSalesmen(List<AppUser> salesmen, {String? prefix}) async {
    if (_isExporting) return;

    final records = <SalesmanTransactionExportRecord>[];
    for (final s in salesmen) {
      final txs = _transactionsBySalesman[s.uid] ?? const [];
      for (final tx in txs) {
        records.add(
          SalesmanTransactionExportRecord(salesman: s, transaction: tx),
        );
      }
    }

    if (records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No transactions to export for the selected salesman/date.'),
        ),
      );
      return;
    }

    setState(() => _isExporting = true);
    try {
      final result = await _exportService.exportTransactions(
        records: records,
        startDate: _startDate,
        endDate: _endDate,
        filePrefix: prefix,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exported ${result.invoiceCount} invoice(s) (${result.lineItemCount} items) to ${result.fileName}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _showMultiSelectExportModal() async {
    final allSorted = _sortedFilteredSalesmen(
      _coveredSalesmen,
      query: '',
      sort: _sortOption,
    );
    if (allSorted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Van Ex-Truck salesmen available.')),
      );
      return;
    }

    final selectedIds = <String>{
      ?_selectedSalesmanId,
    };

    final chosen = await showDialog<List<AppUser>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final allSelected =
              allSorted.isNotEmpty && selectedIds.length == allSorted.length;

          return AlertDialog(
            title: const Text('Select Salesmen to Export'),
            content: SizedBox(
              width: 460,
              height: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${selectedIds.length} of ${allSorted.length} selected',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          setDialogState(() {
                            if (allSelected) {
                              selectedIds.clear();
                            } else {
                              selectedIds
                                ..clear()
                                ..addAll(allSorted.map((u) => u.uid));
                            }
                          });
                        },
                        icon: Icon(
                          allSelected
                              ? Icons.deselect_outlined
                              : Icons.select_all,
                          size: 18,
                        ),
                        label: Text(allSelected ? 'Deselect All' : 'Select All'),
                      ),
                    ],
                  ),
                  const Divider(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: allSorted.length,
                      itemBuilder: (context, index) {
                        final salesman = allSorted[index];
                        final txs =
                            _transactionsBySalesman[salesman.uid] ?? const [];
                        final total = txs.fold<double>(
                          0.0,
                          (sum, tx) => sum + tx.totalAmount,
                        );
                        final checked = selectedIds.contains(salesman.uid);

                        return CheckboxListTile(
                          dense: true,
                          value: checked,
                          onChanged: (val) {
                            setDialogState(() {
                              if (val == true) {
                                selectedIds.add(salesman.uid);
                              } else {
                                selectedIds.remove(salesman.uid);
                              }
                            });
                          },
                          title: Text(
                            _displayName(salesman),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${salesman.email} • ${txs.length} inv • ₱${_moneyFormat.format(total)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: selectedIds.isEmpty
                    ? null
                    : () {
                        final picked = allSorted
                            .where((u) => selectedIds.contains(u.uid))
                            .toList();
                        Navigator.pop(dialogContext, picked);
                      },
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Export Transaction Data'),
              ),
            ],
          );
        },
      ),
    );

    if (chosen != null && chosen.isNotEmpty) {
      final prefix = chosen.length == allSorted.length
          ? 'all_salesmen'
          : '${chosen.length}_salesmen';
      await _exportSalesmen(chosen, prefix: prefix);
    }
  }

  Widget _buildLeftPane(List<AppUser> visibleSalesmen) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(right: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search salesman name...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => _searchController.clear(),
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<_SalesmanSortOption>(
                  initialValue: _sortOption,
                  isDense: true,
                  decoration: InputDecoration(
                    labelText: 'Sort By',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  items: _SalesmanSortOption.values.map((opt) {
                    return DropdownMenuItem(
                      value: opt,
                      child: Text(
                        _sortLabel(opt),
                        style: const TextStyle(fontSize: 13),
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _sortOption = val);
                    }
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                Text(
                  'Van Ex-Truck Salesmen (${visibleSalesmen.length})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: visibleSalesmen.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _coveredSalesmen.isEmpty
                            ? 'No Van Ex-Truck salesmen in your scope.'
                            : 'No salesman matches "$_searchQuery".',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: visibleSalesmen.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final salesman = visibleSalesmen[index];
                      final isSelected = salesman.uid == _selectedSalesmanId;
                      final txs =
                          _transactionsBySalesman[salesman.uid] ?? const [];
                      final totalSales = txs.fold<double>(
                        0.0,
                        (sum, tx) => sum + tx.totalAmount,
                      );

                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          setState(() => _selectedSalesmanId = salesman.uid);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer.withValues(
                                    alpha: 0.45,
                                  )
                                : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey.shade300,
                              width: isSelected ? 1.5 : 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _displayName(salesman),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: txs.isNotEmpty
                                          ? Colors.teal.shade50
                                          : Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '${txs.length}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: txs.isNotEmpty
                                            ? Colors.teal.shade800
                                            : Colors.grey.shade600,
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
                                  fontSize: 11.5,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '₱${_moneyFormat.format(totalSales)}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.teal.shade800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightPane(AppUser? activeSalesman) {
    final txs = activeSalesman == null
        ? const <RouteTransaction>[]
        : (_transactionsBySalesman[activeSalesman.uid] ?? const []);
    final totalSales = txs.fold<double>(0.0, (sum, tx) => sum + tx.totalAmount);
    final totalCs = txs.fold<double>(0.0, (sum, tx) => sum + tx.csQty);
    final totalSc = txs.fold<double>(0.0, (sum, tx) => sum + tx.scQty);
    final totalPc = txs.fold<double>(0.0, (sum, tx) => sum + tx.pcQty);

    return Column(
      children: [
        // Top header bar with selected salesman + 2 Export buttons at top-right
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activeSalesman == null
                        ? 'Select a Salesman'
                        : _displayName(activeSalesman),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    activeSalesman == null
                        ? _dateRangeLabel()
                        : '${activeSalesman.email}  •  ${_dateRangeLabel()}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: (_isExporting || activeSalesman == null || txs.isEmpty)
                        ? null
                        : () => _exportSalesmen(
                              [activeSalesman],
                              prefix: _displayName(activeSalesman),
                            ),
                    icon: const Icon(Icons.table_view_outlined, size: 18),
                    label: const Text('Export Active Salesman'),
                  ),
                  FilledButton.icon(
                    onPressed: (_isExporting || _coveredSalesmen.isEmpty)
                        ? null
                        : _showMultiSelectExportModal,
                    icon: _isExporting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.file_download_outlined, size: 18),
                    label: const Text('Select Salesmen & Export'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (activeSalesman != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            color: Colors.teal.shade50.withValues(alpha: 0.45),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _SummaryBadge(
                  label: 'Total Sales',
                  value: '₱${_moneyFormat.format(totalSales)}',
                  highlight: true,
                ),
                _SummaryBadge(
                  label: 'Invoices',
                  value: '${txs.length}',
                ),
                _SummaryBadge(
                  label: 'CS',
                  value: formatQuantity(totalCs),
                ),
                _SummaryBadge(
                  label: 'SC',
                  value: formatQuantity(totalSc),
                ),
                _SummaryBadge(
                  label: 'PC',
                  value: formatQuantity(totalPc),
                ),
              ],
            ),
          ),
        Expanded(
          child: activeSalesman == null
              ? const Center(
                  child: Text('Select a salesman on the left to view transactions.'),
                )
              : txs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,
                            size: 46,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'No transactions captured for ${_displayName(activeSalesman)}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _dateRangeLabel(),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: txs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final tx = txs[index];
                        return _FullWidthTransactionCard(
                          index: index + 1,
                          transaction: tx,
                          moneyFormat: _moneyFormat,
                          timeFormat: _timeFormat,
                          onTap: () => showFullscreenInvoiceLightbox(
                            context,
                            transaction: tx,
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConstants.enableTransactionsFeature) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transactions')),
        body: DeviceActivationBannerWrapper(
          child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 36,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.amber.shade50,
                        child: Icon(
                          Icons.construction_rounded,
                          size: 32,
                          color: Colors.amber.shade800,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Under Development',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'The Transactions module is currently under development and will be enabled in an upcoming release.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: Colors.grey.shade700,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        ),
      );
    }

    final visibleSalesmen = _sortedFilteredSalesmen(
      _coveredSalesmen,
      query: _searchQuery,
      sort: _sortOption,
    );
    final activeSalesman = _coveredSalesmen
        .where((u) => u.uid == _selectedSalesmanId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: OutlinedButton.icon(
              onPressed: _showDateSelectionDialog,
              icon: const Icon(Icons.date_range, size: 18),
              label: Text(_dateRangeLabel()),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Refresh Transactions',
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
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth < 760) {
                      return Column(
                        children: [
                          SizedBox(
                            height: 230,
                            child: _buildLeftPane(visibleSalesmen),
                          ),
                          const Divider(height: 1),
                          Expanded(child: _buildRightPane(activeSalesman)),
                        ],
                      );
                    }
                    // 25% Left Pane / 75% Right Pane
                    return Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: _buildLeftPane(visibleSalesmen),
                        ),
                        Expanded(
                          flex: 3,
                          child: _buildRightPane(activeSalesman),
                        ),
                      ],
                    );
                  },
                ),
      ),
    );
  }
}

class _SummaryBadge extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _SummaryBadge({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlight ? Colors.teal.shade700 : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: highlight ? null : Border.all(color: Colors.teal.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              color: highlight ? Colors.white70 : Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              color: highlight ? Colors.white : Colors.teal.shade900,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FullWidthTransactionCard extends StatelessWidget {
  final int index;
  final RouteTransaction transaction;
  final NumberFormat moneyFormat;
  final DateFormat timeFormat;
  final VoidCallback onTap;

  const _FullWidthTransactionCard({
    required this.index,
    required this.transaction,
    required this.moneyFormat,
    required this.timeFormat,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final uomParts = <String>[];
    if (transaction.csQty > 0) {
      uomParts.add('CS: ${formatQuantity(transaction.csQty)}');
    }
    if (transaction.scQty > 0) {
      uomParts.add('SC: ${formatQuantity(transaction.scQty)}');
    }
    if (transaction.pcQty > 0) {
      uomParts.add('PC: ${formatQuantity(transaction.pcQty)}');
    }

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Colors.teal.shade50,
                child: Text(
                  '#$index',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.teal.shade800,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            transaction.customerName.isEmpty
                                ? 'Unknown Customer'
                                : transaction.customerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '₱${moneyFormat.format(transaction.totalAmount)}',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.teal.shade800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'Invoice: ${transaction.invoiceCode}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                        ),
                        Text(
                          '• ${transaction.routeDate} ${timeFormat.format(transaction.capturedAt.toLocal())}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        Text(
                          '• ${transaction.items.length} item(s)',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        if (uomParts.isNotEmpty)
                          Text(
                            '• ${uomParts.join('  ')}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.indigo.shade700,
                            ),
                          ),
                      ],
                    ),
                    if (transaction.address.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        transaction.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.receipt_outlined, color: Colors.teal.shade700),
            ],
          ),
        ),
      ),
    );
  }
}

