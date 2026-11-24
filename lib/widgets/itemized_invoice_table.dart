import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/invoice_paginator.dart';

/// Shared itemized line-item table with Vatable Sales, 12% VAT, and Grand Total
/// footer used by both `WebTransactionDetailModal` and `RouteDetailModal`.
class ItemizedInvoiceTable extends StatelessWidget {
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  final RouteTransaction transaction;
  final double columnSpacing;

  const ItemizedInvoiceTable({
    super.key,
    required this.transaction,
    this.columnSpacing = 24,
  });

  @override
  Widget build(BuildContext context) {
    if (transaction.items.isEmpty) {
      return const Center(
        child: Text(
          'No line items recorded for this invoice.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final grandVatable = InvoicePaginator.round2(transaction.totalAmount / 1.12);
    final grandVat = InvoicePaginator.round2(transaction.totalAmount - grandVatable);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
                columnSpacing: columnSpacing,
                columns: const [
                  DataColumn(label: Text('Pg')),
                  DataColumn(label: Text('#')),
                  DataColumn(label: Text('Code')),
                  DataColumn(label: Text('Description')),
                  DataColumn(label: Text('QTY')),
                  DataColumn(label: Text('U-Price'), numeric: true),
                  DataColumn(label: Text('Amount'), numeric: true),
                ],
                rows: transaction.items
                    .map(
                      (item) => DataRow(
                        cells: [
                          DataCell(Text('${item.pageNo}')),
                          DataCell(Text('${item.sequence}')),
                          DataCell(Text(item.code)),
                          DataCell(Text(item.description)),
                          DataCell(Text(item.formattedQty)),
                          DataCell(Text(_moneyFormat.format(item.unitPrice))),
                          DataCell(Text(_moneyFormat.format(item.totalAmount))),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(
                'Vatable Sales: ₱${_moneyFormat.format(grandVatable)}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade800,
                ),
              ),
              Text(
                '12% VAT: ₱${_moneyFormat.format(grandVat)}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade800,
                ),
              ),
              Text(
                'Grand Total: ₱${_moneyFormat.format(transaction.totalAmount)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F766E),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

