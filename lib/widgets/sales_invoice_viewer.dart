import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/invoice_paginator.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/sfa_invoice_parser.dart';

/// Shared 9-line BIR Sales Invoice viewer with pinch-to-zoom, page navigation
/// (for 2+ pages), live SI series display, optional Void Page action, and close button.
class SalesInvoiceViewer extends StatefulWidget {
  final RouteTransaction transaction;
  final VoidCallback? onCloseRequested;
  final bool confirmOnClose;
  final bool showCloseButton;

  /// Optional callback invoked when the user confirms voiding [pageNo] (1-based).
  /// Returning the updated [RouteTransaction] immediately refreshes the viewer
  /// in-place while keeping the current page selected.
  final Future<RouteTransaction?> Function(int pageNo, String? reason)?
      onVoidPageRequested;

  const SalesInvoiceViewer({
    super.key,
    required this.transaction,
    this.onCloseRequested,
    this.confirmOnClose = false,
    this.showCloseButton = true,
    this.onVoidPageRequested,
  });

  @override
  State<SalesInvoiceViewer> createState() => _SalesInvoiceViewerState();
}

class _SalesInvoiceViewerState extends State<SalesInvoiceViewer> {
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  late RouteTransaction _transaction;
  late List<InvoicePageData> _pages;
  late final PageController _pageController;
  int _currentPage = 0;
  bool _isZoomed = false;
  bool _isVoiding = false;

  @override
  void initState() {
    super.initState();
    _transaction = widget.transaction;
    _pages = InvoicePaginator.paginate(_transaction.items);
    _pageController = PageController();
  }

  @override
  void didUpdateWidget(covariant SalesInvoiceViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transaction != widget.transaction) {
      final sameTransaction =
          oldWidget.transaction.transactionId == widget.transaction.transactionId;
      _transaction = widget.transaction;
      _pages = InvoicePaginator.paginate(_transaction.items);
      if (!sameTransaction) {
        _currentPage = 0;
        _isZoomed = false;
        if (_pageController.hasClients) {
          _pageController.jumpToPage(0);
        }
      } else if (_currentPage >= _pages.length) {
        _currentPage = (_pages.length - 1).clamp(0, _pages.length);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _handleVoidCurrentPage() async {
    if (_isVoiding || widget.onVoidPageRequested == null) return;
    final pageNo = _currentPage + 1;
    final currentSi = _transaction.siNumberForPage(pageNo);
    if (currentSi == null) return;

    var reasonInput = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.block_rounded, color: Colors.red.shade700, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Void SI No. $currentSi?',
                style: const TextStyle(fontSize: 17),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SI No. $currentSi (Page $pageNo of ${_pages.length}) will be marked as VOID. '
              'Page $pageNo and any remaining pages of this invoice will shift to the next available SI series.',
              style: const TextStyle(fontSize: 13.5, height: 1.35),
            ),
            const SizedBox(height: 12),
            TextField(
              maxLength: 80,
              onChanged: (val) => reasonInput = val,
              decoration: const InputDecoration(
                labelText: 'Reason (Optional)',
                hintText: 'e.g., Wrong entry, torn sheet, ink smudge',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.block, size: 17),
            label: const Text('Yes, Void Page'),
          ),
        ],
      ),
    );

    final reason = reasonInput.trim();

    if (confirmed != true || !mounted) return;

    setState(() => _isVoiding = true);
    try {
      final updated = await widget.onVoidPageRequested!(
        pageNo,
        reason.isEmpty ? null : reason,
      );
      if (updated != null && mounted) {
        setState(() {
          _transaction = updated;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to void SI page: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isVoiding = false);
      }
    }
  }

  Future<void> _handleClosePressed() async {
    if (!widget.confirmOnClose) {
      widget.onCloseRequested?.call();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Done with Preview?'),
        content: const Text(
          'Are you already done copying or reviewing this Sales Invoice?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep Viewing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes, Close'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      widget.onCloseRequested?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sheetDate = SfaInvoiceParser.formatSheetDate(
      _transaction.invoiceDate,
      fallback: _transaction.capturedAt,
    );
    final hasMultiplePages = _pages.length > 1;
    final currentPageNo = _currentPage + 1;
    final currentPageSi = _transaction.siNumberForPage(currentPageNo);
    final showVoidButton =
        widget.onVoidPageRequested != null && currentPageSi != null;
    final voidedSummary = _transaction.formattedVoidedSiSummary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_transaction.siConflict)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 16, color: Colors.red.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'SI Series Conflict detected — please review with your encoder.',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.red.shade900,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (_transaction.hasMissingSiPages &&
            _transaction.hasAnySiAssigned)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.amber.shade900),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'SI Booklet Exhausted — one or more pages have no SI series assigned. Ask your encoder to add a new booklet.',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.amber.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Flexible(
          child: PageView.builder(
            controller: _pageController,
            physics: _isZoomed
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            itemCount: _pages.length,
            onPageChanged: (idx) {
              setState(() {
                _currentPage = idx;
                _isZoomed = false;
              });
            },
            itemBuilder: (context, index) {
              return _ZoomableInvoiceSheet(
                transaction: _transaction,
                page: _pages[index],
                sheetDate: sheetDate,
                moneyFormat: _moneyFormat,
                onZoomChanged: (zoomed) {
                  if (zoomed != _isZoomed && mounted) {
                    setState(() => _isZoomed = zoomed);
                  }
                },
              );
            },
          ),
        ),
        if (voidedSummary.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade100),
            ),
            child: Row(
              children: [
                Icon(Icons.block, size: 14, color: Colors.red.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Voided SI: $voidedSummary',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.red.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (hasMultiplePages) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: _currentPage > 0
                    ? () => _pageController.previousPage(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                        )
                    : null,
                icon: const Icon(Icons.chevron_left),
                label: const Text('Previous'),
              ),
              Flexible(
                child: _pages.length > 7
                    ? Text(
                        'Page ${_currentPage + 1} / ${_pages.length}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF4A3FB5),
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(_pages.length, (i) {
                          final active = i == _currentPage;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: active ? 18 : 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: active
                                  ? const Color(0xFF4A3FB5)
                                  : Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          );
                        }),
                      ),
              ),
              TextButton.icon(
                onPressed: _currentPage < _pages.length - 1
                    ? () => _pageController.nextPage(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                        )
                    : null,
                icon: const Icon(Icons.chevron_right),
                label: const Text('Next'),
              ),
            ],
          ),
        ],
        if (showVoidButton || widget.showCloseButton) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              if (showVoidButton)
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade300),
                    ),
                    onPressed: _isVoiding ? null : _handleVoidCurrentPage,
                    icon: _isVoiding
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.red.shade700,
                            ),
                          )
                        : const Icon(Icons.block, size: 18),
                    label: Text(_isVoiding ? 'Voiding...' : 'Void Page'),
                  ),
                ),
              if (showVoidButton && widget.showCloseButton)
                const SizedBox(width: 10),
              if (widget.showCloseButton)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isVoiding ? null : _handleClosePressed,
                    icon: const Icon(Icons.close),
                    label: const Text('Close'),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Renders a single zoomable 9-line BIR Sales Invoice page card for custom
/// viewers (such as the full-screen dimmed invoice lightbox).
class SalesInvoicePageCard extends StatelessWidget {
  final RouteTransaction transaction;
  final InvoicePageData page;
  final String sheetDate;
  final ValueChanged<bool>? onZoomChanged;

  const SalesInvoicePageCard({
    super.key,
    required this.transaction,
    required this.page,
    required this.sheetDate,
    this.onZoomChanged,
  });

  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  @override
  Widget build(BuildContext context) {
    return _ZoomableInvoiceSheet(
      transaction: transaction,
      page: page,
      sheetDate: sheetDate,
      moneyFormat: _moneyFormat,
      onZoomChanged: onZoomChanged ?? (_) {},
    );
  }
}

class _ZoomableInvoiceSheet extends StatefulWidget {
  final RouteTransaction transaction;
  final InvoicePageData page;
  final String sheetDate;
  final NumberFormat moneyFormat;
  final ValueChanged<bool> onZoomChanged;

  const _ZoomableInvoiceSheet({
    required this.transaction,
    required this.page,
    required this.sheetDate,
    required this.moneyFormat,
    required this.onZoomChanged,
  });

  @override
  State<_ZoomableInvoiceSheet> createState() => _ZoomableInvoiceSheetState();
}

class _ZoomableInvoiceSheetState extends State<_ZoomableInvoiceSheet> {
  final TransformationController _transformController = TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    if (_transformController.value != Matrix4.identity()) {
      _transformController.value = Matrix4.identity();
      widget.onZoomChanged(false);
    } else {
      _transformController.value = Matrix4.diagonal3Values(1.8, 1.8, 1.0);
      widget.onZoomChanged(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformController,
        minScale: 1.0,
        maxScale: 4.0,
        panEnabled: true,
        scaleEnabled: true,
        onInteractionEnd: (_) {
          final scale = _transformController.value.getMaxScaleOnAxis();
          widget.onZoomChanged(scale > 1.05);
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: _BirInvoiceSheetCard(
            transaction: widget.transaction,
            page: widget.page,
            sheetDate: widget.sheetDate,
            moneyFormat: widget.moneyFormat,
          ),
        ),
      ),
    );
  }
}

class _BirInvoiceSheetCard extends StatelessWidget {
  final RouteTransaction transaction;
  final InvoicePageData page;
  final String sheetDate;
  final NumberFormat moneyFormat;

  const _BirInvoiceSheetCard({
    required this.transaction,
    required this.page,
    required this.sheetDate,
    required this.moneyFormat,
  });

  @override
  Widget build(BuildContext context) {
    const borderColor = Color(0xFF2B2B2B);
    const gridColor = Color(0xFF666666);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFCEF), // Subtle paper tint matching physical invoice booklet
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 1.4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SALES INVOICE',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    Text(
                      'Invoice: ${transaction.invoiceCode}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'PAGE ${page.pageNo} OF ${page.totalPages}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Date: $sheetDate',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2B2B2B),
                    ),
                  ),
                  const SizedBox(height: 3),
                  _buildSiSeriesHeaderTag(),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'SOLD TO',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2B2B2B),
            ),
          ),
          const SizedBox(height: 4),
          _UnderlinedField(
            label: 'Registered Name',
            value: transaction.customerName,
          ),
          const SizedBox(height: 4),
          _UnderlinedField(
            label: 'TIN',
            value: transaction.tin ?? '',
          ),
          const SizedBox(height: 4),
          _UnderlinedField(
            label: 'Address',
            value: transaction.address,
          ),
          const SizedBox(height: 10),
          Table(
            border: TableBorder.all(color: gridColor, width: 0.8),
            columnWidths: const {
              0: FixedColumnWidth(28),
              1: FlexColumnWidth(4.4),
              2: FlexColumnWidth(1.4),
              3: FlexColumnWidth(1.3),
              4: FlexColumnWidth(1.5),
            },
            children: [
              const TableRow(
                decoration: BoxDecoration(color: Color(0xFFF3EEC8)),
                children: [
                  _HeaderCell('No.', align: TextAlign.center),
                  _HeaderCell('Item Description'),
                  _HeaderCell('QTY', align: TextAlign.center),
                  _HeaderCell('U-Price', align: TextAlign.right),
                  _HeaderCell('Amount', align: TextAlign.right),
                ],
              ),
              for (var i = 0; i < InvoicePaginator.maxLinesPerPage; i++)
                _buildRow(
                  i + 1,
                  i < page.items.length ? page.items[i] : null,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: gridColor, width: 0.9),
              color: const Color(0xFFFAF6DA),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AmountRow(
                  label: 'VATABLE SALES:',
                  value: moneyFormat.format(page.vatableSales),
                ),
                const SizedBox(height: 3),
                _AmountRow(
                  label: 'VAT:',
                  value: moneyFormat.format(page.vat),
                ),
                const Divider(height: 12, thickness: 0.9, color: gridColor),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'TOTAL AMOUNT DUE',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF1A1A1A),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      moneyFormat.format(page.totalAmountDue),
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSiSeriesHeaderTag() {
    final pageSi = transaction.siNumberForPage(page.pageNo);
    if (pageSi != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFFDECEC),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFFD32F2F), width: 0.9),
        ),
        child: Text(
          'SI No. $pageSi',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.4,
            color: Color(0xFFB71C1C),
          ),
        ),
      );
    }

    if (transaction.hasAnySiAssigned) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.amber.shade700, width: 0.8),
        ),
        child: Text(
          'Booklet Exhausted',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: Colors.amber.shade900,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade400, width: 0.7),
      ),
      child: Text(
        'No SI Series',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.grey.shade700,
        ),
      ),
    );
  }

  TableRow _buildRow(int rowNo, InvoiceLineItem? item) {
    return TableRow(
      children: [
        _DataCell('$rowNo', align: TextAlign.center, isMuted: item == null),
        _DataCell(item?.formattedDescription ?? ''),
        _DataCell(item?.formattedQty ?? '', align: TextAlign.center),
        _DataCell(
          item == null ? '' : moneyFormat.format(item.unitPrice),
          align: TextAlign.right,
        ),
        _DataCell(
          item == null ? '' : moneyFormat.format(item.totalAmount),
          align: TextAlign.right,
          isBold: true,
        ),
      ],
    );
  }
}

class _UnderlinedField extends StatelessWidget {
  final String label;
  final String value;

  const _UnderlinedField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '$label: ',
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF2B2B2B),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.only(bottom: 1, left: 4),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFF444444), width: 0.8),
              ),
            ),
            child: Text(
              value.isEmpty ? ' ' : value,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111111),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String text;
  final TextAlign align;

  const _HeaderCell(this.text, {this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      child: Text(
        text,
        textAlign: align,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          color: Color(0xFF1A1A1A),
        ),
      ),
    );
  }
}

class _DataCell extends StatelessWidget {
  final String text;
  final TextAlign align;
  final bool isBold;
  final bool isMuted;

  const _DataCell(
    this.text, {
    this.align = TextAlign.left,
    this.isBold = false,
    this.isMuted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      child: Text(
        text.isEmpty ? ' ' : text,
        textAlign: align,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: isBold ? FontWeight.w700 : FontWeight.w500,
          color: isMuted ? Colors.grey.shade600 : const Color(0xFF1A1A1A),
        ),
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  final String label;
  final String value;

  const _AmountRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF2B2B2B),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1A1A1A),
          ),
        ),
      ],
    );
  }
}

