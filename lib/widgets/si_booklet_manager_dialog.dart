import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/si_series_engine.dart';

/// Opens the SI Booklet management dialog for [salesman].
/// Returns `true` if any booklet was added, edited, or deleted.
Future<bool> showSiBookletManagerDialog(
  BuildContext context, {
  required AppUser salesman,
  required AppUser actor,
  bool hasActiveRouteToday = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => SiBookletManagerDialog(
      salesman: salesman,
      actor: actor,
      hasActiveRouteToday: hasActiveRouteToday,
    ),
  );
  return result == true;
}

class SiBookletManagerDialog extends StatefulWidget {
  final AppUser salesman;
  final AppUser actor;
  final bool hasActiveRouteToday;

  const SiBookletManagerDialog({
    super.key,
    required this.salesman,
    required this.actor,
    this.hasActiveRouteToday = false,
  });

  @override
  State<SiBookletManagerDialog> createState() => _SiBookletManagerDialogState();
}

class _SiBookletManagerDialogState extends State<SiBookletManagerDialog> {
  static final DateFormat _dateTimeFmt = DateFormat('MMM d, yyyy h:mm a');
  final FirestoreService _firestore = FirestoreService();

  SalesmanSiBookletState? _state;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _didChange = false;
  String? _error;
  int _selectedTab = 0; // 0 = Booklets, 1 = Recent Voids

  String get _salesmanLabel {
    final name = widget.salesman.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    return widget.salesman.email;
  }

  String get _companyId =>
      (widget.salesman.companyId?.trim().isNotEmpty == true)
          ? widget.salesman.companyId!.trim()
          : (widget.actor.companyId?.trim() ?? '');

  @override
  void initState() {
    super.initState();
    _loadBooklets();
  }

  Future<void> _loadBooklets() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final state = await _firestore.getSalesmanSiBooklets(
        widget.salesman.uid,
        fallbackCompanyId: _companyId,
      );
      if (!mounted) return;
      setState(() {
        _state = state;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load SI booklets: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _openBookletFormDialog({SiBooklet? existing}) async {
    final isEdit = existing != null;

    final parsed = await showDialog<ParsedBookletRange>(
      context: context,
      builder: (_) => _SiBookletFormDialog(
        salesmanLabel: _salesmanLabel,
        existing: existing,
      ),
    );

    if (parsed == null || !mounted) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final updated = isEdit
          ? await _firestore.updateSiBookletTransactional(
              salesmanId: widget.salesman.uid,
              salesmanName: _salesmanLabel,
              companyId: _companyId,
              bookletId: existing.id,
              newRange: parsed,
            )
          : await _firestore.addSiBookletTransactional(
              salesmanId: widget.salesman.uid,
              salesmanName: _salesmanLabel,
              companyId: _companyId,
              range: parsed,
              actorUid: widget.actor.uid,
              actorName: widget.actor.name ?? widget.actor.email,
            );
      if (!mounted) return;
      setState(() {
        _state = updated;
        _didChange = true;
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEdit
                ? 'Updated SI booklet ${parsed.startFormatted}–${parsed.endFormatted}.'
                : 'Added SI booklet ${parsed.startFormatted}–${parsed.endFormatted}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final cleanMsg = e.toString().replaceFirst('Bad state: ', '');
      setState(() {
        _error = cleanMsg;
        _isSaving = false;
      });
    }
  }

  Future<void> _deleteBooklet(SiBooklet booklet) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete Unused SI Booklet?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Remove booklet ${booklet.rangeLabel} (${booklet.totalPages} pages) '
              'from $_salesmanLabel?',
            ),
            if (widget.hasActiveRouteToday) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Text(
                  'Warning: This salesman has route activity today. Make sure '
                  'they have not started writing on this booklet offline.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade900,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final updated = await _firestore.deleteSiBookletTransactional(
        salesmanId: widget.salesman.uid,
        companyId: _companyId,
        bookletId: booklet.id,
      );
      if (!mounted) return;
      setState(() {
        _state = updated;
        _didChange = true;
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted booklet ${booklet.rangeLabel}.')),
      );
    } catch (e) {
      if (!mounted) return;
      final cleanMsg = e.toString().replaceFirst('Bad state: ', '');
      setState(() {
        _error = cleanMsg;
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 32).clamp(320.0, 680.0);
    final dialogHeight = (size.height * 0.82).clamp(380.0, 660.0);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              color: const Color(0xFF0F766E),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_outlined, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Manage SI Booklets',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '$_salesmanLabel  •  ${widget.salesman.email}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: (_isLoading || _isSaving) ? null : _loadBooklets,
                    icon: const Icon(Icons.refresh, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context, _didChange),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Summary strip + Add Booklet action
            if (state != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: Colors.teal.shade50.withValues(alpha: 0.6),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _StatChip(
                          label: 'Next SI',
                          value: state.nextAvailableFormatted ?? 'None',
                          highlight: state.hasAvailablePages,
                        ),
                        _StatChip(
                          label: 'Remaining',
                          value: '${state.totalRemainingPages} pg',
                        ),
                        _StatChip(
                          label: 'Booklets',
                          value: '${state.booklets.length}',
                        ),
                      ],
                    ),
                    FilledButton.icon(
                      onPressed:
                          (_isLoading || _isSaving) ? null : () => _openBookletFormDialog(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add Booklet'),
                    ),
                  ],
                ),
              ),

            // Error banner
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 9,
                ),
                color: Colors.red.shade50,
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.red.shade900,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Tabs
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text('Booklets (${state?.booklets.length ?? 0})'),
                    selected: _selectedTab == 0,
                    onSelected: (_) => setState(() => _selectedTab = 0),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(
                      'Recent Voids (${state?.recentVoids.length ?? 0})',
                    ),
                    selected: _selectedTab == 1,
                    onSelected: (_) => setState(() => _selectedTab = 1),
                  ),
                  if (_isSaving) ...[
                    const Spacer(),
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
            ),

            const Divider(height: 1),

            // Body
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _selectedTab == 0
                      ? _buildBookletsList(state!)
                      : _buildRecentVoidsList(state!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookletsList(SalesmanSiBookletState state) {
    final booklets = state.sortedBooklets;
    if (booklets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: 48,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 10),
              const Text(
                'No SI Booklets Assigned Yet',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Add one or more booklets manually (first page to last page). '
                'Transactions will consume series numbers automatically from smallest to highest.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: booklets.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final b = booklets[index];
        final progress = b.totalPages > 0 ? b.usedPages / b.totalPages : 1.0;

        final Color statusBg;
        final Color statusFg;
        final String statusLabel;
        switch (b.status) {
          case SiBookletStatus.unused:
            statusBg = Colors.blue.shade50;
            statusFg = Colors.blue.shade800;
            statusLabel = 'Unused';
            break;
          case SiBookletStatus.active:
            statusBg = Colors.green.shade50;
            statusFg = Colors.green.shade800;
            statusLabel = 'In Use';
            break;
          case SiBookletStatus.exhausted:
            statusBg = Colors.grey.shade200;
            statusFg = Colors.grey.shade700;
            statusLabel = 'Exhausted';
            break;
        }

        return Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.teal.shade50,
                      child: Text(
                        '#${index + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.teal.shade800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        b.rangeLabel,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusBg,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: statusFg,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (!b.isExhausted)
                      IconButton(
                        tooltip: b.isUnused
                            ? 'Edit Booklet Range'
                            : 'Adjust Last Page',
                        icon: const Icon(Icons.edit_outlined, size: 19),
                        onPressed: _isSaving
                            ? null
                            : () => _openBookletFormDialog(existing: b),
                      ),
                    if (b.isUnused)
                      IconButton(
                        tooltip: 'Delete Unused Booklet',
                        icon: Icon(
                          Icons.delete_outline,
                          size: 19,
                          color: Colors.red.shade700,
                        ),
                        onPressed:
                            _isSaving ? null : () => _deleteBooklet(b),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: Colors.grey.shade200,
                    color: b.isExhausted
                        ? Colors.grey.shade500
                        : Colors.teal.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    Text(
                      'Used: ${b.usedPages} / ${b.totalPages}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    Text(
                      'Remaining: ${b.remainingPages}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: b.remainingPages > 0
                            ? Colors.teal.shade800
                            : Colors.grey.shade600,
                      ),
                    ),
                    if (b.nextFormatted != null)
                      Text(
                        'Next: ${b.nextFormatted}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Colors.red.shade800,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecentVoidsList(SalesmanSiBookletState state) {
    final voids = List<SiVoidEntry>.from(state.recentVoids)
      ..sort((a, b) => b.voidedAt.compareTo(a.voidedAt));

    if (voids.isEmpty) {
      return Center(
        child: Text(
          'No voided SI pages recorded for this salesman.',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: voids.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final v = voids[index];
        return ListTile(
          dense: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: Colors.red.shade100),
          ),
          tileColor: Colors.red.shade50.withValues(alpha: 0.45),
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: Colors.red.shade100,
            child: Icon(Icons.block, size: 16, color: Colors.red.shade800),
          ),
          title: Text(
            'SI No. ${v.siNumber}  •  Page ${v.pageNo}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: Colors.red.shade900,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Invoice: ${v.invoiceCode ?? '-'}  •  ${_dateTimeFmt.format(v.voidedAt.toLocal())}',
                style: const TextStyle(fontSize: 11.5),
              ),
              if (v.voidedByName != null || v.voidedByRole != null)
                Text(
                  'By: ${v.voidedByName ?? v.voidedBy ?? '-'} (${v.voidedByRole ?? 'user'})',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                ),
              if (v.reason != null && v.reason!.isNotEmpty)
                Text(
                  'Reason: ${v.reason}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey.shade800,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SiBookletFormDialog extends StatefulWidget {
  final String salesmanLabel;
  final SiBooklet? existing;

  const _SiBookletFormDialog({
    required this.salesmanLabel,
    this.existing,
  });

  @override
  State<_SiBookletFormDialog> createState() => _SiBookletFormDialogState();
}

class _SiBookletFormDialogState extends State<_SiBookletFormDialog> {
  late final TextEditingController _startCtrl;
  late final TextEditingController _endCtrl;
  String? _validationError;

  bool get _isEdit => widget.existing != null;
  bool get _isPartiallyUsed => _isEdit && !widget.existing!.isUnused;

  @override
  void initState() {
    super.initState();
    _startCtrl = TextEditingController(
      text: _isEdit ? widget.existing!.startFormatted : '',
    );
    _endCtrl = TextEditingController(
      text: _isEdit ? widget.existing!.endFormatted : '',
    );
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  ParsedBookletRange? _tryParsePreview() {
    try {
      return SiSeriesEngine.parseBookletInput(_startCtrl.text, _endCtrl.text);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final preview = _tryParsePreview();

    return AlertDialog(
      title: Text(_isEdit ? 'Edit SI Booklet' : 'Add SI Booklet'),
      content: SizedBox(
        width: 390,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Salesman: ${widget.salesmanLabel}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _startCtrl,
              enabled: !_isPartiallyUsed,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'First Page SI Number',
                hintText: 'e.g., 0001001 or 123456',
                helperText: _isPartiallyUsed
                    ? 'Locked — booklet already has ${existing!.usedPages} used page(s).'
                    : 'Leading zeros are preserved automatically.',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() => _validationError = null),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _endCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Last Page SI Number',
                hintText: 'e.g., 0001050 or 123500',
                helperText: _isPartiallyUsed
                    ? 'Must be >= last used SI (${existing!.formatValue(existing.lastUsedNumber!)}).'
                    : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() => _validationError = null),
            ),
            if (preview != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.shade200),
                ),
                child: Text(
                  'Range: ${preview.startFormatted} – ${preview.endFormatted}  '
                  '(${preview.totalPages} page${preview.totalPages == 1 ? '' : 's'})',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.teal.shade900,
                  ),
                ),
              ),
            ],
            if (_validationError != null) ...[
              const SizedBox(height: 10),
              Text(
                _validationError!,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            try {
              final range = SiSeriesEngine.parseBookletInput(
                _startCtrl.text,
                _endCtrl.text,
              );
              if (_isPartiallyUsed) {
                final lastUsed = existing!.lastUsedNumber!;
                if (range.endNumber < lastUsed) {
                  setState(() {
                    _validationError =
                        'Last page cannot be below last used SI '
                        '(${existing.formatValue(lastUsed)}).';
                  });
                  return;
                }
              }
              Navigator.pop(context, range);
            } on FormatException catch (e) {
              setState(() => _validationError = e.message);
            }
          },
          child: Text(_isEdit ? 'Save Changes' : 'Add Booklet'),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _StatChip({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
              fontSize: 11.5,
              color: highlight ? Colors.white70 : Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: highlight ? Colors.white : Colors.teal.shade900,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
