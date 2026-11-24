import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/widgets/itemized_invoice_table.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';

/// Modal displayed when a Web Map user clicks a Captured Transaction checkpoint.
/// Supports multi-invoice stops, GPS/telemetry metadata, the 9-line Paged Sales
/// Invoice view, and a toggle to a full itemized table.
class WebTransactionDetailModal extends StatefulWidget {
  final List<RouteTransaction> transactions;
  final String? salesmanLabel;
  final int initialIndex;

  const WebTransactionDetailModal({
    super.key,
    required this.transactions,
    this.salesmanLabel,
    this.initialIndex = 0,
  });

  @override
  State<WebTransactionDetailModal> createState() =>
      _WebTransactionDetailModalState();
}

class _WebTransactionDetailModalState extends State<WebTransactionDetailModal> {
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  late int _selectedIndex;
  bool _showFullTable = false;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(
      0,
      widget.transactions.isEmpty ? 0 : widget.transactions.length - 1,
    );
  }

  @override
  void didUpdateWidget(covariant WebTransactionDetailModal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transactions.isEmpty) {
      _selectedIndex = 0;
    } else if (_selectedIndex >= widget.transactions.length) {
      _selectedIndex = widget.transactions.length - 1;
    }
  }

  Future<void> _openGoogleMaps(double lat, double lon) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
    );
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched) return;
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Unable to open map for this location.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.transactions.isEmpty) {
      return const SizedBox.shrink();
    }

    final tx = widget.transactions[_selectedIndex];
    final size = MediaQuery.sizeOf(context);
    final isWide = kIsWeb && size.width >= 900;
    final maxAllowedWidth = (size.width - 32).clamp(280.0, 960.0);
    final dialogWidth = isWide
        ? (size.width * 0.62).clamp(620.0, 960.0).clamp(280.0, maxAllowedWidth)
        : maxAllowedWidth.clamp(280.0, 760.0);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: dialogWidth,
        height: size.height * 0.88,
        child: Column(
          children: [
            _buildTopBar(tx),
            if (widget.transactions.length > 1) _buildStopSwitcher(),
            _buildMetadataHeader(tx),
            _buildViewModeTabs(),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: _showFullTable
                    ? ItemizedInvoiceTable(transaction: tx)
                    : SalesInvoiceViewer(
                        key: ValueKey(tx.transactionId),
                        transaction: tx,
                        showCloseButton: false,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(RouteTransaction tx) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      color: const Color(0xFF0F766E),
      child: Row(
        children: [
          const Icon(Icons.receipt_long, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.customerName.isEmpty
                      ? 'Captured Transaction'
                      : tx.customerName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${tx.invoiceCode}  •  Captured ${DateFormat('hh:mm a').format(tx.capturedAt)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildStopSwitcher() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: Colors.teal.shade50,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${widget.transactions.length} invoices at this stop:',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.teal.shade900,
            ),
          ),
          for (var i = 0; i < widget.transactions.length; i++)
            ChoiceChip(
              label: Text(
                '#${i + 1} ${widget.transactions[i].invoiceCode}',
                style: const TextStyle(fontSize: 11.5),
              ),
              selected: i == _selectedIndex,
              onSelected: (_) => setState(() => _selectedIndex = i),
            ),
        ],
      ),
    );
  }

  Widget _buildMetadataHeader(RouteTransaction tx) {
    final gpsText = tx.hasValidLocation
        ? '${tx.lat.toStringAsFixed(6)}, ${tx.lon.toStringAsFixed(6)}'
        : 'Unavailable';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      color: Colors.grey.shade50,
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Customer Code: ${tx.customerCode}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Address: ${tx.address}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 2),
                Text(
                  'SalesRep: ${tx.salesRepCode} ${tx.salesRepName}'
                  '${widget.salesmanLabel != null ? ' (${widget.salesmanLabel})' : ''}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 2),
                Text(
                  'Invoiced Date: ${tx.invoiceDate}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _moneyFormat.format(tx.totalAmount),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F766E),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  _QtyPill(label: 'CS', value: formatQuantity(tx.csQty)),
                  _QtyPill(label: 'SC', value: formatQuantity(tx.scQty)),
                  _QtyPill(label: 'PC', value: formatQuantity(tx.pcQty)),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_on, size: 14, color: Colors.teal.shade700),
                      const SizedBox(width: 4),
                      Text(
                        gpsText,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  if (tx.hasValidLocation)
                    TextButton(
                      onPressed: () => _openGoogleMaps(tx.lat, tx.lon),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Open Map',
                        style: TextStyle(fontSize: 11.5),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildViewModeTabs() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<bool>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment<bool>(
              value: false,
              icon: Icon(Icons.description_outlined, size: 16),
              label: Text('9-Line Invoice', overflow: TextOverflow.ellipsis),
            ),
            ButtonSegment<bool>(
              value: true,
              icon: Icon(Icons.table_rows_outlined, size: 16),
              label: Text('Full Table', overflow: TextOverflow.ellipsis),
            ),
          ],
          selected: {_showFullTable},
          onSelectionChanged: (sel) {
            setState(() => _showFullTable = sel.first);
          },
        ),
      ),
    );
  }
}

class _QtyPill extends StatelessWidget {
  final String label;
  final String value;

  const _QtyPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.teal.shade200),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.teal.shade900,
        ),
      ),
    );
  }
}

