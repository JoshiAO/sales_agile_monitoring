import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/si_series_engine.dart';

/// Opens a confirmation & diff-preview dialog for an Encoder/Superuser to
/// **Void** a specific SI page OR **Un-Void** a mistakenly voided SI number,
/// cascading chronologically within the same route date by default (with an
/// explicit opt-in checkbox if later dates exist in [salesmanRoutes]).
///
/// Returns the updated target [RouteTransaction] when confirmed & applied, or `null` if cancelled.
Future<RouteTransaction?> showEncoderSiCascadeDialog(
  BuildContext context, {
  required AppUser salesman,
  required AppUser actor,
  required List<SalesRoute> salesmanRoutes,
  required RouteTransaction targetTransaction,
  int? voidPageNo,
  String? unvoidSiNumber,
}) async {
  assert(
    (voidPageNo != null) ^ (unvoidSiNumber != null),
    'Specify either voidPageNo or unvoidSiNumber.',
  );
  return showDialog<RouteTransaction?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _EncoderSiCascadeDialog(
      salesman: salesman,
      actor: actor,
      salesmanRoutes: salesmanRoutes,
      targetTransaction: targetTransaction,
      voidPageNo: voidPageNo,
      unvoidSiNumber: unvoidSiNumber,
    ),
  );
}

class _EncoderSiCascadeDialog extends StatefulWidget {
  final AppUser salesman;
  final AppUser actor;
  final List<SalesRoute> salesmanRoutes;
  final RouteTransaction targetTransaction;
  final int? voidPageNo;
  final String? unvoidSiNumber;

  const _EncoderSiCascadeDialog({
    required this.salesman,
    required this.actor,
    required this.salesmanRoutes,
    required this.targetTransaction,
    this.voidPageNo,
    this.unvoidSiNumber,
  });

  @override
  State<_EncoderSiCascadeDialog> createState() =>
      _EncoderSiCascadeDialogState();
}

class _EncoderSiCascadeDialogState extends State<_EncoderSiCascadeDialog> {
  final FirestoreService _firestore = FirestoreService();
  final TextEditingController _reasonController = TextEditingController();

  bool _isLoading = true;
  bool _isApplying = false;
  bool _includeLaterDates = false;
  String? _error;
  SalesmanSiBookletState? _bookletState;
  EncoderCascadePreview? _preview;

  bool get _isUnvoid => widget.unvoidSiNumber != null;

  List<SalesRoute> get _laterRoutes {
    final targetDate = widget.targetTransaction.routeDate;
    return widget.salesmanRoutes
        .where((r) => r.date.compareTo(targetDate) > 0)
        .toList();
  }

  List<SalesRoute> get _scopedRoutes {
    final targetDate = widget.targetTransaction.routeDate;
    return widget.salesmanRoutes.where((r) {
      if (_includeLaterDates) {
        return r.date.compareTo(targetDate) >= 0;
      }
      return r.date == targetDate;
    }).toList();
  }

  String get _salesmanLabel {
    final name = widget.salesman.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    return widget.salesman.email;
  }

  @override
  void initState() {
    super.initState();
    _loadAndComputePreview();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _loadAndComputePreview() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final state = await _firestore.getSalesmanSiBooklets(
        widget.salesman.uid,
        fallbackCompanyId: widget.salesman.companyId ?? widget.actor.companyId,
      );
      if (!mounted) return;
      _bookletState = state;
      _recomputePreview();
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load booklet state: $e';
        _isLoading = false;
      });
    }
  }

  void _recomputePreview() {
    final state = _bookletState;
    if (state == null) return;
    final scopedTxs = _scopedRoutes.expand((r) => r.transactions).toList();
    try {
      final preview = _isUnvoid
          ? SiSeriesEngine.previewEncoderUnvoidCascade(
              state: state,
              scopedTransactions: scopedTxs,
              targetTransactionId: widget.targetTransaction.transactionId,
              voidedSiNumber: widget.unvoidSiNumber!,
            )
          : SiSeriesEngine.previewEncoderVoidCascade(
              state: state,
              scopedTransactions: scopedTxs,
              targetTransactionId: widget.targetTransaction.transactionId,
              targetPageNo: widget.voidPageNo!,
              reason: _reasonController.text.trim().isEmpty
                  ? null
                  : _reasonController.text.trim(),
              voidedBy: widget.actor.uid,
              voidedByName: widget.actor.name ?? widget.actor.email,
              voidedByRole: roleToString(widget.actor.role),
            );
      setState(() {
        _preview = preview;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _preview = null;
        _error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _applyCascade() async {
    if (_isApplying || _bookletState == null) return;
    // Recompute once more with latest reason text before committing.
    _recomputePreview();
    final preview = _preview;
    if (preview == null) return;

    setState(() {
      _isApplying = true;
      _error = null;
    });

    try {
      await _firestore.applyEncoderSiCascade(
        salesmanId: widget.salesman.uid,
        salesmanName: _salesmanLabel,
        companyId: widget.salesman.companyId ?? widget.actor.companyId,
        affectedRoutes: _scopedRoutes,
        preview: preview,
      );

      final updatedTarget = preview.diffs
          .firstWhere(
            (d) => d.after.transactionId == widget.targetTransaction.transactionId,
          )
          .after;

      if (!mounted) return;
      Navigator.pop(context, updatedTarget);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to apply SI update: $e';
        _isApplying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final hasLaterDates = _laterRoutes.isNotEmpty;
    final targetSi = _isUnvoid
        ? widget.unvoidSiNumber!
        : (widget.targetTransaction.siNumberForPage(widget.voidPageNo!) ?? '');

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _isUnvoid ? Icons.undo_rounded : Icons.block_rounded,
            color: _isUnvoid ? Colors.teal.shade700 : Colors.red.shade700,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isUnvoid
                  ? 'Un-Void SI No. $targetSi?'
                  : 'Void SI No. $targetSi (Page ${widget.voidPageNo})?',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!_isUnvoid) ...[
                      TextField(
                        controller: _reasonController,
                        maxLength: 80,
                        enabled: !_isApplying,
                        decoration: const InputDecoration(
                          labelText: 'Void Reason (Optional)',
                          hintText: 'e.g., Damaged paper, misprint, pen error',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (hasLaterDates)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.shade300),
                        ),
                        child: CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _includeLaterDates,
                          onChanged: _isApplying
                              ? null
                              : (val) {
                                  setState(
                                    () => _includeLaterDates = val ?? false,
                                  );
                                  _recomputePreview();
                                },
                          title: Text(
                            'Also cascade into ${_laterRoutes.length} later route date(s)',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            'Default cascades only within ${widget.targetTransaction.routeDate}. '
                            'Enable only if physical paper invoices on later days also shifted.',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Colors.amber.shade900,
                            ),
                          ),
                        ),
                      ),
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Colors.red.shade900,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (preview != null) ...[
                      if (preview.unassignedSlotsCount > 0)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange.shade300),
                          ),
                          child: Text(
                            'Warning: Booklet will run out of pages — '
                            '${preview.unassignedSlotsCount} page(s) will become unassigned.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.orange.shade900,
                            ),
                          ),
                        ),
                      Text(
                        'Affected Transactions (${preview.diffs.length}):',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: preview.diffs.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (context, idx) {
                            final diff = preview.diffs[idx];
                            final beforeStr =
                                diff.before.formattedSiSeriesSummary.isEmpty
                                    ? 'None'
                                    : diff.before.formattedSiSeriesSummary;
                            final afterStr =
                                diff.after.formattedSiSeriesSummary.isEmpty
                                    ? 'Exhausted'
                                    : diff.after.formattedSiSeriesSummary;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${diff.before.customerName}  •  ${diff.before.invoiceCode}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Text(
                                        beforeStr,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade700,
                                          decoration:
                                              TextDecoration.lineThrough,
                                        ),
                                      ),
                                      const Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        child: Icon(
                                          Icons.arrow_forward,
                                          size: 14,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          afterStr,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.teal.shade900,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.teal.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Next available SI after update: '
                          '${preview.updatedState.nextAvailableFormatted ?? 'Exhausted'} '
                          '(${preview.updatedState.totalRemainingPages} page(s) left)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.teal.shade900,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _isApplying ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor:
                _isUnvoid ? Colors.teal.shade700 : Colors.red.shade700,
            foregroundColor: Colors.white,
          ),
          onPressed: (_isLoading || _isApplying || preview == null)
              ? null
              : _applyCascade,
          icon: _isApplying
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(_isUnvoid ? Icons.undo : Icons.check, size: 18),
          label: Text(
            _isApplying
                ? 'Applying...'
                : (_isUnvoid ? 'Confirm Un-Void' : 'Confirm Void & Cascade'),
          ),
        ),
      ],
    );
  }
}

