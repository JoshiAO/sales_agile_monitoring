import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/invoice_paginator.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/sfa_invoice_parser.dart';

/// Shared 9-line BIR Sales Invoice viewer with pinch-to-zoom, page navigation
/// (for 2+ pages), and optional close confirmation button.
class SalesInvoiceViewer extends StatefulWidget {
  final RouteTransaction transaction;
  final VoidCallback? onCloseRequested;
  final bool confirmOnClose;
  final bool showCloseButton;

  const SalesInvoiceViewer({
    super.key,
    required this.transaction,
    this.onCloseRequested,
    this.confirmOnClose = false,
    this.showCloseButton = true,
  });

  @override
  State<SalesInvoiceViewer> createState() => _SalesInvoiceViewerState();
}

class _SalesInvoiceViewerState extends State<SalesInvoiceViewer> {
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  late List<InvoicePageData> _pages;
  late final PageController _pageController;
  int _currentPage = 0;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _pages = InvoicePaginator.paginate(widget.transaction.items);
    _pageController = PageController();
  }

  @override
  void didUpdateWidget(covariant SalesInvoiceViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transaction != widget.transaction) {
      _pages = InvoicePaginator.paginate(widget.transaction.items);
      _currentPage = 0;
      _isZoomed = false;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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
      widget.transaction.invoiceDate,
      fallback: widget.transaction.capturedAt,
    );
    final hasMultiplePages = _pages.length > 1;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
                transaction: widget.transaction,
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
        if (widget.showCloseButton) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _handleClosePressed,
              icon: const Icon(Icons.close),
              label: const Text('Close'),
            ),
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

