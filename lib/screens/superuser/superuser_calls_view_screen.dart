import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/calls_grid_export_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

enum CallsFilter { allWithCalls, allSalesmen, completedFirstAndLast, onlyFirstCall }
enum CallsSort {
  firstCallAsc,
  firstCallDesc,
  lastCallAsc,
  lastCallDesc,
  salesmanEmailAsc,
  salesmanEmailDesc,
  salesmanNameAsc,
  salesmanNameDesc,
}

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
  final CallsGridExportService _gridExportService = CallsGridExportService();
  late Future<_CallsViewData> _dataFuture;
  Future<_WeeklyCallsViewData>? _weeklyDataFuture;
  List<AppUser>? _cachedTeam;

  CallsFilter _filter = CallsFilter.allWithCalls;
  CallsSort _sort = CallsSort.firstCallAsc;

  // View mode toggle (card-based vs tabular grid view, shown on web)
  bool _isTabularView = false;
  bool _isExporting = false;
  late DateTime _selectedMonth; // First day of selected month
  late int _selectedWeek; // 1-based Sunday..Saturday calendar row in month

  @override
  void initState() {
    super.initState();
    _selectedMonth = DateTime(widget.selectedDate.year, widget.selectedDate.month, 1);
    _selectedWeek = _weekIndexForDate(widget.selectedDate, _selectedMonth);
    _dataFuture = _loadData();
  }

  /// Sunday starting Week 1 of [month] (first day of month minus its Sunday offset).
  DateTime _firstWeekSunday(DateTime month) {
    final firstDay = DateTime(month.year, month.month, 1);
    final sundayOffset = firstDay.weekday % 7; // Sun=0, Mon=1, ..., Sat=6
    return firstDay.subtract(Duration(days: sundayOffset));
  }

  /// Total Sunday..Saturday weeks overlapping [month].
  int _weeksInMonth(DateTime month) {
    final firstDay = DateTime(month.year, month.month, 1);
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final sundayOffset = firstDay.weekday % 7;
    return ((daysInMonth + sundayOffset - 1) ~/ 7) + 1;
  }

  /// 1-based week index in [month] containing [date].
  int _weekIndexForDate(DateTime date, DateTime month) {
    final firstDay = DateTime(month.year, month.month, 1);
    final sundayOffset = firstDay.weekday % 7;
    final week = ((date.day + sundayOffset - 1) ~/ 7) + 1;
    return week.clamp(1, _weeksInMonth(month));
  }

  /// Returns the 7 consecutive calendar dates (Sun..Sat) for [month] & [week].
  List<DateTime> _daysInSelectedWeek(DateTime month, int week) {
    final sunday = _firstWeekSunday(month).add(Duration(days: (week - 1) * 7));
    return List.generate(7, (i) => DateTime(sunday.year, sunday.month, sunday.day + i));
  }

  /// Month options for dropdown (last 12 months through current/selected month).
  List<DateTime> _monthOptions() {
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month, 1);
    final selectedNormalized = DateTime(widget.selectedDate.year, widget.selectedDate.month, 1);
    final latestMonth = currentMonth.isAfter(selectedNormalized) ? currentMonth : selectedNormalized;

    final months = <DateTime>[];
    for (int i = 11; i >= 0; i--) {
      months.add(DateTime(latestMonth.year, latestMonth.month - i, 1));
    }
    if (!months.any((m) => m.year == _selectedMonth.year && m.month == _selectedMonth.month)) {
      months.add(_selectedMonth);
      months.sort();
    }
    return months;
  }

  Future<List<AppUser>> _getTeam({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedTeam != null) {
      return _cachedTeam!;
    }
    final team = (await _firestoreService.getSupervisorTeam(widget.supervisor.uid)).toList()
      ..sort((a, b) => _displayName(a).compareTo(_displayName(b)));
    _cachedTeam = team;
    return team;
  }

  Future<_CallsViewData> _loadData({bool forceRefresh = false}) async {
    final dateStr = DateFormat('yyyy-MM-dd').format(widget.selectedDate);
    final results = await Future.wait([
      _getTeam(forceRefresh: forceRefresh),
      _firestoreService.getRoutesByDate(widget.supervisor.uid, dateStr),
    ]);

    final team = results[0] as List<AppUser>;
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

  Future<_WeeklyCallsViewData> _loadWeeklyData({bool forceRefresh = false}) async {
    final weekDays = _daysInSelectedWeek(_selectedMonth, _selectedWeek);
    final dateFmt = DateFormat('yyyy-MM-dd');
    final startDateStr = dateFmt.format(weekDays.first);
    final endDateStr = dateFmt.format(weekDays.last);

    final results = await Future.wait([
      _getTeam(forceRefresh: forceRefresh),
      _firestoreService.getRoutesForSupervisorByDateRange(
        supervisorId: widget.supervisor.uid,
        startDate: startDateStr,
        endDate: endDateStr,
      ),
    ]);

    final team = results[0] as List<AppUser>;
    final routes = results[1] as List<SalesRoute>;

    // Keyed by salesmanId -> ('yyyy-MM-dd' -> best SalesRoute for that day)
    final routesBySalesmanByDate = <String, Map<String, SalesRoute>>{};
    for (final route in routes) {
      final byDate = routesBySalesmanByDate.putIfAbsent(route.salesmanId, () => <String, SalesRoute>{});
      final existing = byDate[route.date];
      if (existing == null || _routePreferenceScore(route, existing) > 0) {
        byDate[route.date] = route;
      }
    }

    return _WeeklyCallsViewData(
      team: team,
      weekDays: weekDays,
      routesBySalesmanByDate: routesBySalesmanByDate,
    );
  }

  /// Prefers completed routes (both F & L), then latest call timestamp.
  int _routePreferenceScore(SalesRoute candidate, SalesRoute existing) {
    final candidateCalls = (candidate.hasFirstCall ? 1 : 0) + (candidate.hasLastCall ? 1 : 0);
    final existingCalls = (existing.hasFirstCall ? 1 : 0) + (existing.hasLastCall ? 1 : 0);
    if (candidateCalls != existingCalls) {
      return candidateCalls.compareTo(existingCalls);
    }
    return _routeSortTime(candidate).compareTo(_routeSortTime(existing));
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

  void _toggleViewMode(bool tabular) {
    if (_isTabularView == tabular) return;
    setState(() {
      _isTabularView = tabular;
      if (_isTabularView) {
        _weeklyDataFuture ??= _loadWeeklyData();
      }
    });
  }

  void _onMonthChanged(DateTime? month) {
    if (month == null) return;
    if (month.year == _selectedMonth.year && month.month == _selectedMonth.month) return;
    final now = DateTime.now();
    final isCurrentMonth = month.year == now.year && month.month == now.month;
    final nextWeek = isCurrentMonth ? _weekIndexForDate(now, month) : 1;
    setState(() {
      _selectedMonth = month;
      _selectedWeek = nextWeek.clamp(1, _weeksInMonth(month));
      _weeklyDataFuture = _loadWeeklyData();
    });
  }

  void _onWeekChanged(int? week) {
    if (week == null || week == _selectedWeek) return;
    setState(() {
      _selectedWeek = week;
      _weeklyDataFuture = _loadWeeklyData();
    });
  }

  Future<void> _refresh() async {
    if (_isTabularView) {
      final nextWeekly = _loadWeeklyData(forceRefresh: true);
      setState(() {
        _weeklyDataFuture = nextWeekly;
        _dataFuture = _loadData();
      });
      await nextWeekly;
    } else {
      final nextFuture = _loadData(forceRefresh: true);
      setState(() {
        _dataFuture = nextFuture;
        if (_weeklyDataFuture != null) {
          _weeklyDataFuture = _loadWeeklyData();
        }
      });
      await nextFuture;
    }
  }

  String _filterLabel(CallsFilter filter) {
    switch (filter) {
      case CallsFilter.allWithCalls:
        return 'All With Calls';
      case CallsFilter.allSalesmen:
        return 'All Salesmen';
      case CallsFilter.completedFirstAndLast:
        return 'Completed First & Last';
      case CallsFilter.onlyFirstCall:
        return 'Only First Call';
    }
  }

  String _sortLabel(CallsSort sort) {
    switch (sort) {
      case CallsSort.firstCallAsc:
        return 'First Call (Ascending)';
      case CallsSort.firstCallDesc:
        return 'First Call (Descending)';
      case CallsSort.lastCallAsc:
        return 'Last Call (Ascending)';
      case CallsSort.lastCallDesc:
        return 'Last Call (Descending)';
      case CallsSort.salesmanEmailAsc:
        return 'Salesman Email (A - Z)';
      case CallsSort.salesmanEmailDesc:
        return 'Salesman Email (Z - A)';
      case CallsSort.salesmanNameAsc:
        return 'Salesman Name (A - Z)';
      case CallsSort.salesmanNameDesc:
        return 'Salesman Name (Z - A)';
    }
  }

  void _toggleSortByEmail() {
    setState(() {
      _sort = _sort == CallsSort.salesmanEmailAsc
          ? CallsSort.salesmanEmailDesc
          : CallsSort.salesmanEmailAsc;
    });
  }

  void _toggleSortByName() {
    setState(() {
      _sort = _sort == CallsSort.salesmanNameAsc
          ? CallsSort.salesmanNameDesc
          : CallsSort.salesmanNameAsc;
    });
  }

  Future<void> _exportWeeklyGridToExcel(
    _WeeklyCallsViewData data,
    List<AppUser> orderedSalesmen,
  ) async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final result = await _gridExportService.exportWeeklyCallsGrid(
        supervisorName: _displayName(widget.supervisor),
        selectedMonth: _selectedMonth,
        selectedWeek: _selectedWeek,
        weekDays: data.weekDays,
        orderedSalesmen: orderedSalesmen,
        routesBySalesmanByDate: data.routesBySalesmanByDate,
        filterLabel: _filterLabel(_filter),
        sortLabel: _sortLabel(_sort),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exported ${result.rowCount} row(s) to ${result.fileName}',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supervisorName = _displayName(widget.supervisor);
    final showGridSwitch = kIsWeb || MediaQuery.sizeOf(context).width >= 600;

    return Scaffold(
      appBar: AppBar(
        title: Text('Calls View: $supervisorName'),
        actions: [
          if (showGridSwitch) ...[
            _ViewModeToggle(
              isTabularView: _isTabularView,
              onChanged: _toggleViewMode,
            ),
            const SizedBox(width: 8),
          ],
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isTabularView ? _buildTabularBody(context) : _buildCardBody(context),
    );
  }

  Widget _buildControlsBar({
    required bool includeDateRangeControls,
    VoidCallback? onExportPressed,
  }) {
    final months = _monthOptions();
    final totalWeeks = _weeksInMonth(_selectedMonth);
    final dateRangeFmt = DateFormat('MMM d');

    return Wrap(
      spacing: 16,
      runSpacing: 16,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DropdownMenu<CallsFilter>(
          key: ValueKey('filter_${_filter.name}'),
          label: const Text('Filter'),
          initialSelection: _filter,
          onSelected: (val) {
            if (val != null) setState(() => _filter = val);
          },
          dropdownMenuEntries: CallsFilter.values
              .map((f) => DropdownMenuEntry(value: f, label: _filterLabel(f)))
              .toList(),
        ),
        DropdownMenu<CallsSort>(
          key: ValueKey('sort_${_sort.name}'),
          label: const Text('Sort By'),
          initialSelection: _sort,
          onSelected: (val) {
            if (val != null) setState(() => _sort = val);
          },
          dropdownMenuEntries: CallsSort.values
              .map((s) => DropdownMenuEntry(value: s, label: _sortLabel(s)))
              .toList(),
        ),
        if (includeDateRangeControls) ...[
          DropdownMenu<DateTime>(
            key: ValueKey('month_${_selectedMonth.year}_${_selectedMonth.month}'),
            label: const Text('Month'),
            initialSelection: _selectedMonth,
            onSelected: _onMonthChanged,
            dropdownMenuEntries: months.map((m) {
              return DropdownMenuEntry<DateTime>(
                value: m,
                label: DateFormat('MMM yyyy').format(m),
              );
            }).toList(),
          ),
          DropdownMenu<int>(
            key: ValueKey('week_${_selectedMonth.year}_${_selectedMonth.month}_$_selectedWeek'),
            label: const Text('Week'),
            initialSelection: _selectedWeek,
            onSelected: _onWeekChanged,
            dropdownMenuEntries: List.generate(totalWeeks, (index) {
              final w = index + 1;
              final days = _daysInSelectedWeek(_selectedMonth, w);
              final label = 'Week $w (${dateRangeFmt.format(days.first)} - ${dateRangeFmt.format(days.last)})';
              return DropdownMenuEntry<int>(value: w, label: label);
            }),
          ),
          FilledButton.icon(
            onPressed: _isExporting ? null : onExportPressed,
            icon: _isExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download_rounded, size: 18),
            label: Text(_isExporting ? 'Exporting...' : 'Export Excel'),
          ),
        ],
      ],
    );
  }

  Widget _buildCardBody(BuildContext context) {
    return FutureBuilder<_CallsViewData>(
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
            bool include = false;
            if (_filter == CallsFilter.allWithCalls || _filter == CallsFilter.allSalesmen) {
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
          switch (_sort) {
            case CallsSort.salesmanEmailAsc:
              return a.email.toLowerCase().compareTo(b.email.toLowerCase());
            case CallsSort.salesmanEmailDesc:
              return b.email.toLowerCase().compareTo(a.email.toLowerCase());
            case CallsSort.salesmanNameAsc:
              return _displayName(a).toLowerCase().compareTo(_displayName(b).toLowerCase());
            case CallsSort.salesmanNameDesc:
              return _displayName(b).toLowerCase().compareTo(_displayName(a).toLowerCase());
            case CallsSort.firstCallAsc:
            case CallsSort.firstCallDesc:
            case CallsSort.lastCallAsc:
            case CallsSort.lastCallDesc:
              final routeA = data.routesBySalesman[a.uid]!;
              final routeB = data.routesBySalesman[b.uid]!;

              final DateTime timeA;
              final DateTime timeB;

              if (_sort == CallsSort.firstCallAsc || _sort == CallsSort.firstCallDesc) {
                timeA = routeA.first.timestamp;
                timeB = routeB.first.timestamp;
              } else {
                timeA = routeA.hasLastCall
                    ? routeA.last.timestamp
                    : DateTime.fromMillisecondsSinceEpoch(0);
                timeB = routeB.hasLastCall
                    ? routeB.last.timestamp
                    : DateTime.fromMillisecondsSinceEpoch(0);
              }

              if (_sort == CallsSort.firstCallAsc || _sort == CallsSort.lastCallAsc) {
                return timeA.compareTo(timeB);
              } else {
                return timeB.compareTo(timeA);
              }
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
                  _buildControlsBar(includeDateRangeControls: false),
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
    );
  }

  Widget _buildTabularBody(BuildContext context) {
    return FutureBuilder<_WeeklyCallsViewData>(
      future: _weeklyDataFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildControlsBar(includeDateRangeControls: true),
              const SizedBox(height: 48),
              const Center(child: CircularProgressIndicator()),
            ],
          );
        }
        if (snapshot.hasError) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildControlsBar(includeDateRangeControls: true),
              const SizedBox(height: 48),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Failed to load weekly calls.', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('${snapshot.error}'),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _refresh, child: const Text('Retry')),
                  ],
                ),
              ),
            ],
          );
        }

        final data = snapshot.data!;
        final dateFmt = DateFormat('yyyy-MM-dd');
        final focusDateStr = dateFmt.format(widget.selectedDate);
        final weekDateKeys = data.weekDays.map(dateFmt.format).toList();

        // Filter team for the weekly grid
        int zeroCallCount = 0;
        final filteredTeam = <AppUser>[];
        for (final user in data.team) {
          final byDate = data.routesBySalesmanByDate[user.uid] ?? const <String, SalesRoute>{};
          final hasAnyCallInWeek = byDate.values.any((r) => r.hasFirstCall || r.hasLastCall);
          if (!hasAnyCallInWeek) {
            zeroCallCount++;
          }

          bool include;
          switch (_filter) {
            case CallsFilter.allSalesmen:
              include = true;
              break;
            case CallsFilter.allWithCalls:
              include = hasAnyCallInWeek;
              break;
            case CallsFilter.completedFirstAndLast:
              include = byDate.values.any((r) => r.hasFirstCall && r.hasLastCall);
              break;
            case CallsFilter.onlyFirstCall:
              include = byDate.values.any((r) => r.hasFirstCall && !r.hasLastCall);
              break;
          }
          if (include) {
            filteredTeam.add(user);
          }
        }

        // Sort filteredTeam using the focus day's call time (or latest active day in the week)
        DateTime? sortKeyForSalesman(AppUser user) {
          final byDate = data.routesBySalesmanByDate[user.uid];
          if (byDate == null || byDate.isEmpty) return null;

          SalesRoute? referenceRoute = byDate[focusDateStr];
          if (referenceRoute == null) {
            for (final key in weekDateKeys.reversed) {
              final r = byDate[key];
              if (r != null && (r.hasFirstCall || r.hasLastCall)) {
                referenceRoute = r;
                break;
              }
            }
          }
          if (referenceRoute == null) return null;

          if (_sort == CallsSort.firstCallAsc || _sort == CallsSort.firstCallDesc) {
            return referenceRoute.hasFirstCall ? referenceRoute.first.timestamp : null;
          } else {
            return referenceRoute.hasLastCall ? referenceRoute.last.timestamp : null;
          }
        }

        filteredTeam.sort((a, b) {
          switch (_sort) {
            case CallsSort.salesmanEmailAsc:
              return a.email.toLowerCase().compareTo(b.email.toLowerCase());
            case CallsSort.salesmanEmailDesc:
              return b.email.toLowerCase().compareTo(a.email.toLowerCase());
            case CallsSort.salesmanNameAsc:
              return _displayName(a).toLowerCase().compareTo(_displayName(b).toLowerCase());
            case CallsSort.salesmanNameDesc:
              return _displayName(b).toLowerCase().compareTo(_displayName(a).toLowerCase());
            case CallsSort.firstCallAsc:
            case CallsSort.firstCallDesc:
            case CallsSort.lastCallAsc:
            case CallsSort.lastCallDesc:
              final timeA = sortKeyForSalesman(a);
              final timeB = sortKeyForSalesman(b);
              if (timeA == null && timeB == null) {
                return _displayName(a).toLowerCase().compareTo(_displayName(b).toLowerCase());
              }
              if (timeA == null) return 1;
              if (timeB == null) return -1;

              final cmp = (_sort == CallsSort.firstCallAsc || _sort == CallsSort.lastCallAsc)
                  ? timeA.compareTo(timeB)
                  : timeB.compareTo(timeA);
              return cmp != 0
                  ? cmp
                  : _displayName(a).toLowerCase().compareTo(_displayName(b).toLowerCase());
          }
        });

        final headerRangeStr =
            '${DateFormat('MMM d').format(data.weekDays.first)} – ${DateFormat('MMM d, yyyy').format(data.weekDays.last)}';

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildControlsBar(
                includeDateRangeControls: true,
                onExportPressed: filteredTeam.isEmpty
                    ? null
                    : () => _exportWeeklyGridToExcel(data, filteredTeam),
              ),
              const SizedBox(height: 16),
              _WeeklyLegendBar(
                weekSummary: 'Week $_selectedWeek ($headerRangeStr) • ${filteredTeam.length} salesman(s)',
                zeroCallCount: _filter == CallsFilter.allWithCalls ? zeroCallCount : 0,
                onShowAllPressed: () => setState(() => _filter = CallsFilter.allSalesmen),
              ),
              const SizedBox(height: 12),
              if (filteredTeam.isEmpty)
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: [
                        Text(
                          'No salesmen match the selected filter for Week $_selectedWeek.',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (_filter == CallsFilter.allWithCalls && zeroCallCount > 0) ...[
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: () => setState(() => _filter = CallsFilter.allSalesmen),
                            child: Text('Show all $zeroCallCount salesman(s) with no calls'),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              else
                _WeeklyCallsTable(
                  salesmen: filteredTeam,
                  weekDays: data.weekDays,
                  routesBySalesmanByDate: data.routesBySalesmanByDate,
                  activeSort: _sort,
                  onSortByEmail: _toggleSortByEmail,
                  onSortByName: _toggleSortByName,
                  onCellTap: _showDayCallDetailDialog,
                ),
            ],
          ),
        );
      },
    );
  }

  void _showDayCallDetailDialog(AppUser salesman, DateTime day, SalesRoute route) {
    final formattedDate = DateFormat('EEEE, MMM d, yyyy').format(day);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          formattedDate,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 200,
                    child: _SalesmanCallCard(salesman: salesman, route: route),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
            if (name.toLowerCase() != salesman.email.toLowerCase())
              Text(
                salesman.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
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
                      imageUrl: (route != null && route!.hasFirstCall) ? route!.first.imageUrl : null,
                    ),
                  ),
                  const VerticalDivider(width: 16),
                  Expanded(
                    child: _CallInfoBlock(
                      title: 'Last Call',
                      timeText: (route != null && route!.hasLastCall) ? timeFormat.format(route!.last.timestamp) : '--',
                      hasCall: route != null && route!.hasLastCall,
                      onMapTap: (route != null && route!.hasLastCall) ? () => _launchMap(route!.last.lat, route!.last.lon) : null,
                      imageUrl: (route != null && route!.hasLastCall) ? route!.last.imageUrl : null,
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
  final String? imageUrl;

  const _CallInfoBlock({
    required this.title,
    required this.timeText,
    required this.hasCall,
    this.onMapTap,
    this.imageUrl,
  });

  void _showImageDialog(BuildContext context, String url) {
    if (url.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Stack(
          children: [
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (context, url) => const Padding(
                padding: EdgeInsets.all(48.0),
                child: CircularProgressIndicator(),
              ),
              errorWidget: (context, url, error) => const Padding(
                padding: EdgeInsets.all(48.0),
                child: Icon(Icons.broken_image_outlined, color: Colors.red, size: 48),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                icon: const Icon(
                  Icons.close,
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
            if (hasCall) ...[
              if (imageUrl != null && imageUrl!.isNotEmpty)
                InkWell(
                  onTap: () => _showImageDialog(context, imageUrl!),
                  borderRadius: BorderRadius.circular(50),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(Icons.image_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
                  ),
                ),
              InkWell(
                onTap: onMapTap,
                borderRadius: BorderRadius.circular(50),
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Icon(Icons.map, size: 16, color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ],
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

class _WeeklyCallsViewData {
  final List<AppUser> team;
  final List<DateTime> weekDays;
  final Map<String, Map<String, SalesRoute>> routesBySalesmanByDate;

  const _WeeklyCallsViewData({
    required this.team,
    required this.weekDays,
    required this.routesBySalesmanByDate,
  });
}

/// Harmonized color palette for the Weekly Calls Tabular View.
class _CallsGridColors {
  static const completedBg = Color(0xFFD1FAE5); // Fresh Mint Green
  static const completedIcon = Color(0xFF15803D); // Deep Forest Green

  static const partialBg = Color(0xFFFEF3C7); // Warm Amber
  static const partialIcon = Color(0xFFB45309); // Deep Amber-Orange

  static const missedBg = Color(0xFFFEE2E2); // Soft Coral Rose
  static const missedIcon = Color(0xFFB91C1C); // Muted Crimson

  static const futureBg = Color(0xFFE5E7EB); // Neutral Cool Slate Gray
}

class _ViewModeToggle extends StatelessWidget {
  final bool isTabularView;
  final ValueChanged<bool> onChanged;

  const _ViewModeToggle({
    required this.isTabularView,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = colorScheme.outline.withValues(alpha: 0.6);

    Widget buildSegment({
      required bool selected,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      required BorderRadius borderRadius,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? colorScheme.primaryContainer : Colors.transparent,
            borderRadius: borderRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          buildSegment(
            selected: !isTabularView,
            icon: Icons.grid_view_rounded,
            label: 'Cards',
            onTap: () => onChanged(false),
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(19)),
          ),
          Container(width: 1, height: 24, color: borderColor),
          buildSegment(
            selected: isTabularView,
            icon: Icons.table_chart_rounded,
            label: 'Grid',
            onTap: () => onChanged(true),
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(19)),
          ),
        ],
      ),
    );
  }
}

/// Vector check (✓) or cross (✕) icon drawn with CustomPaint so it never
/// depends on font subsetting/caches on web.
class _CallStatusGlyph extends StatelessWidget {
  final bool isCheck;
  final Color color;
  final double size;

  const _CallStatusGlyph({
    required this.isCheck,
    required this.color,
    this.size = 15,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _CallStatusGlyphPainter(isCheck: isCheck, color: color),
    );
  }
}

class _CallStatusGlyphPainter extends CustomPainter {
  final bool isCheck;
  final Color color;

  const _CallStatusGlyphPainter({
    required this.isCheck,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.17
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    if (isCheck) {
      final path = Path()
        ..moveTo(w * 0.16, h * 0.54)
        ..lineTo(w * 0.40, h * 0.78)
        ..lineTo(w * 0.85, h * 0.24);
      canvas.drawPath(path, paint);
    } else {
      canvas.drawLine(
        Offset(w * 0.24, h * 0.24),
        Offset(w * 0.76, h * 0.76),
        paint,
      );
      canvas.drawLine(
        Offset(w * 0.76, h * 0.24),
        Offset(w * 0.24, h * 0.76),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CallStatusGlyphPainter oldDelegate) {
    return oldDelegate.isCheck != isCheck || oldDelegate.color != color;
  }
}

class _WeeklyLegendBar extends StatelessWidget {
  final String weekSummary;
  final int zeroCallCount;
  final VoidCallback onShowAllPressed;

  const _WeeklyLegendBar({
    required this.weekSummary,
    required this.zeroCallCount,
    required this.onShowAllPressed,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_view_week_rounded, size: 18, color: primary),
                const SizedBox(width: 8),
                Text(
                  weekSummary,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                if (zeroCallCount > 0) ...[
                  const SizedBox(width: 10),
                  ActionChip(
                    label: Text(
                      '+$zeroCallCount with 0 calls',
                      style: const TextStyle(fontSize: 12),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: onShowAllPressed,
                  ),
                ],
              ],
            ),
            const Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _LegendItem(
                  color: _CallsGridColors.completedBg,
                  isCheck: true,
                  glyphColor: _CallsGridColors.completedIcon,
                  label: 'Completed (F & L)',
                ),
                _LegendItem(
                  color: _CallsGridColors.partialBg,
                  isCheck: true,
                  glyphColor: _CallsGridColors.completedIcon,
                  label: '1 Call Only',
                ),
                _LegendItem(
                  color: _CallsGridColors.missedBg,
                  isCheck: false,
                  glyphColor: _CallsGridColors.missedIcon,
                  label: 'No Calls',
                ),
                _LegendItem(
                  color: _CallsGridColors.futureBg,
                  label: 'Upcoming',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final bool? isCheck;
  final Color? glyphColor;
  final String label;

  const _LegendItem({
    required this.color,
    this.isCheck,
    this.glyphColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade400, width: 0.8),
          ),
          child: isCheck != null && glyphColor != null
              ? _CallStatusGlyph(
                  isCheck: isCheck!,
                  color: glyphColor!,
                  size: 12,
                )
              : null,
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade800,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _WeeklyCallsTable extends StatefulWidget {
  final List<AppUser> salesmen;
  final List<DateTime> weekDays;
  final Map<String, Map<String, SalesRoute>> routesBySalesmanByDate;
  final CallsSort activeSort;
  final VoidCallback onSortByEmail;
  final VoidCallback onSortByName;
  final void Function(AppUser salesman, DateTime day, SalesRoute route) onCellTap;

  const _WeeklyCallsTable({
    required this.salesmen,
    required this.weekDays,
    required this.routesBySalesmanByDate,
    required this.activeSort,
    required this.onSortByEmail,
    required this.onSortByName,
    required this.onCellTap,
  });

  @override
  State<_WeeklyCallsTable> createState() => _WeeklyCallsTableState();
}

class _WeeklyCallsTableState extends State<_WeeklyCallsTable> {
  final ScrollController _horizontalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final todayDateOnly = DateTime(now.year, now.month, now.day);
    final dayNameFmt = DateFormat('EEE');
    final dateKeyFmt = DateFormat('yyyy-MM-dd');
    final timeFmt = DateFormat('h:mm a');
    final colorScheme = Theme.of(context).colorScheme;
    final headerBg = Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.08),
      Colors.white,
    );
    final todayHeaderBg = colorScheme.primary.withValues(alpha: 0.18);
    final borderColor = Colors.grey.shade400;

    return LayoutBuilder(
      builder: (context, constraints) {
        const minEmailWidth = 200.0;
        const minNameWidth = 210.0;
        const minDayWidth = 96.0; // 48px for F + 48px for L
        const minTableWidth = minEmailWidth + minNameWidth + (minDayWidth * 7);

        final availableWidth = constraints.maxWidth;
        final tableWidth = availableWidth > minTableWidth ? availableWidth : minTableWidth;
        final extraPerColumn = (tableWidth - minTableWidth) / 9.0;
        final emailWidth = minEmailWidth + extraPerColumn;
        final nameWidth = minNameWidth + extraPerColumn;
        final dayWidth = minDayWidth + extraPerColumn;

        return Card(
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: borderColor),
          ),
          child: Scrollbar(
            controller: _horizontalController,
            thumbVisibility: tableWidth > availableWidth,
            child: SingleChildScrollView(
              controller: _horizontalController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: tableWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Table Header (3 Tiers: Day Name, Day Number, F | L) ──
                    Container(
                      color: headerBg,
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _HeaderTitleCell(
                              width: emailWidth,
                              label: 'Salesman Email',
                              borderColor: borderColor,
                              isSortedAsc: widget.activeSort == CallsSort.salesmanEmailAsc
                                  ? true
                                  : (widget.activeSort == CallsSort.salesmanEmailDesc ? false : null),
                              onTap: widget.onSortByEmail,
                            ),
                            _HeaderTitleCell(
                              width: nameWidth,
                              label: 'Salesman Name',
                              borderColor: borderColor,
                              showLeftBorder: true,
                              isSortedAsc: widget.activeSort == CallsSort.salesmanNameAsc
                                  ? true
                                  : (widget.activeSort == CallsSort.salesmanNameDesc ? false : null),
                              onTap: widget.onSortByName,
                            ),
                            ...widget.weekDays.map((day) {
                              final dateOnly = DateTime(day.year, day.month, day.day);
                              final isToday = dateOnly == todayDateOnly;
                              return Container(
                                width: dayWidth,
                                decoration: BoxDecoration(
                                  color: isToday ? todayHeaderBg : null,
                                  border: Border(
                                    left: BorderSide(color: borderColor, width: 1),
                                    bottom: BorderSide(color: borderColor, width: 1.2),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(vertical: 5),
                                      decoration: BoxDecoration(
                                        border: Border(
                                          bottom: BorderSide(
                                            color: borderColor.withValues(alpha: 0.5),
                                            width: 0.8,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        dayNameFmt.format(day),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: isToday ? colorScheme.primary : Colors.black87,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(vertical: 5),
                                      decoration: BoxDecoration(
                                        border: Border(
                                          bottom: BorderSide(
                                            color: borderColor.withValues(alpha: 0.6),
                                            width: 0.8,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        '${day.day}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                                          fontSize: 13,
                                          color: isToday ? colorScheme.primary : Colors.black87,
                                        ),
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        const Expanded(
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(vertical: 4),
                                            child: Text(
                                              'F',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                        Container(
                                          width: 0.8,
                                          height: 22,
                                          color: borderColor.withValues(alpha: 0.6),
                                        ),
                                        const Expanded(
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(vertical: 4),
                                            child: Text(
                                              'L',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),

                    // ── Table Body Rows ───────────────────────────────────────
                    ...List.generate(widget.salesmen.length, (rowIndex) {
                      final salesman = widget.salesmen[rowIndex];
                      final name = (salesman.name?.trim().isNotEmpty == true)
                          ? salesman.name!.trim()
                          : salesman.email;
                      final rowBg = rowIndex.isEven ? Colors.white : const Color(0xFFFAF9FE);
                      final byDate = widget.routesBySalesmanByDate[salesman.uid] ??
                          const <String, SalesRoute>{};
                      final isLastRow = rowIndex == widget.salesmen.length - 1;
                      final bottomBorder = isLastRow
                          ? BorderSide.none
                          : BorderSide(color: borderColor, width: 0.9);

                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              width: emailWidth,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                color: rowBg,
                                border: Border(bottom: bottomBorder),
                              ),
                              child: Text(
                                salesman.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.grey.shade800,
                                ),
                              ),
                            ),
                            Container(
                              width: nameWidth,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                color: rowBg,
                                border: Border(
                                  left: BorderSide(color: borderColor, width: 1),
                                  bottom: bottomBorder,
                                ),
                              ),
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            ...widget.weekDays.map((day) {
                              final dateKey = dateKeyFmt.format(day);
                              final dateOnly = DateTime(day.year, day.month, day.day);
                              final isFuture = dateOnly.isAfter(todayDateOnly);
                              final route = byDate[dateKey];
                              final hasFirst = !isFuture && route != null && route.hasFirstCall;
                              final hasLast = !isFuture && route != null && route.hasLastCall;

                              late final Color cellBg;
                              if (isFuture) {
                                cellBg = _CallsGridColors.futureBg;
                              } else if (hasFirst && hasLast) {
                                cellBg = _CallsGridColors.completedBg;
                              } else if (hasFirst || hasLast) {
                                cellBg = _CallsGridColors.partialBg;
                              } else {
                                cellBg = _CallsGridColors.missedBg;
                              }

                              final tooltipMessage = isFuture
                                  ? '$name • ${DateFormat('EEE, MMM d').format(day)}\nUpcoming date'
                                  : (hasFirst || hasLast)
                                      ? '$name • ${DateFormat('EEE, MMM d').format(day)}\n'
                                          'First Call: ${hasFirst ? timeFmt.format(route.first.timestamp) : '--'}\n'
                                          'Last Call: ${hasLast ? timeFmt.format(route.last.timestamp) : '--'}\n'
                                          'Distance: ${route.estimatedDistanceKm.toStringAsFixed(2)} km'
                                      : '$name • ${DateFormat('EEE, MMM d').format(day)}\nNo calls recorded';

                              final cellContent = Container(
                                width: dayWidth,
                                decoration: BoxDecoration(
                                  color: cellBg,
                                  border: Border(
                                    left: BorderSide(color: borderColor, width: 1),
                                    bottom: bottomBorder,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Center(
                                        child: isFuture
                                            ? const SizedBox.shrink()
                                            : _CallStatusGlyph(
                                                isCheck: hasFirst,
                                                color: hasFirst
                                                    ? _CallsGridColors.completedIcon
                                                    : _CallsGridColors.missedIcon,
                                                size: 14,
                                              ),
                                      ),
                                    ),
                                    Container(
                                      width: 0.7,
                                      color: borderColor.withValues(alpha: 0.35),
                                    ),
                                    Expanded(
                                      child: Center(
                                        child: isFuture
                                            ? const SizedBox.shrink()
                                            : _CallStatusGlyph(
                                                isCheck: hasLast,
                                                color: hasLast
                                                    ? _CallsGridColors.completedIcon
                                                    : _CallsGridColors.missedIcon,
                                                size: 14,
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              );

                              return Tooltip(
                                message: tooltipMessage,
                                child: (hasFirst || hasLast)
                                    ? InkWell(
                                        onTap: () => widget.onCellTap(salesman, day, route),
                                        child: cellContent,
                                      )
                                    : cellContent,
                              );
                            }),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HeaderTitleCell extends StatelessWidget {
  final double width;
  final String label;
  final Color borderColor;
  final bool showLeftBorder;
  final bool? isSortedAsc;
  final VoidCallback onTap;

  const _HeaderTitleCell({
    required this.width,
    required this.label,
    required this.borderColor,
    this.showLeftBorder = false,
    required this.isSortedAsc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isActive = isSortedAsc != null;

    return Tooltip(
      message: 'Click to sort by $label',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          child: Container(
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                left: showLeftBorder
                    ? BorderSide(color: borderColor, width: 1)
                    : BorderSide.none,
                bottom: BorderSide(color: borderColor, width: 1.2),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: isActive ? colorScheme.primary : Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  isSortedAsc == null
                      ? Icons.unfold_more_rounded
                      : (isSortedAsc!
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded),
                  size: 16,
                  color: isActive ? colorScheme.primary : Colors.grey.shade600,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
