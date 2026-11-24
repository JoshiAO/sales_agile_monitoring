import 'dart:io';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/web_downloader.dart';

class SalesmanTransactionExportRecord {
  final AppUser salesman;
  final RouteTransaction transaction;

  const SalesmanTransactionExportRecord({
    required this.salesman,
    required this.transaction,
  });
}

class TransactionExportResult {
  final String fileName;
  final String savedPath;
  final int invoiceCount;
  final int lineItemCount;

  const TransactionExportResult({
    required this.fileName,
    required this.savedPath,
    required this.invoiceCount,
    required this.lineItemCount,
  });
}

/// Builds and downloads a 2-sheet Excel workbook containing:
/// 1. `Transactions Summary` — 1 row per invoice
/// 2. `Itemized Details` — 1 row per SKU line item linked by Invoice Code
class TransactionExportService {
  static double _round2(double value) => (value * 100).roundToDouble() / 100.0;

  static String _salesmanLabel(AppUser user) {
    final name = user.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    return user.email;
  }

  static String _sanitizeSegment(String input) {
    final cleaned = input
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'salesmen' : cleaned;
  }

  /// Generates the `.xlsx` bytes directly (exposed for unit testing).
  List<int> buildWorkbookBytes({
    required List<SalesmanTransactionExportRecord> records,
  }) {
    final excel = Excel.createExcel();
    final defaultSheet = excel.getDefaultSheet();
    const summarySheetName = 'Transactions Summary';
    const itemizedSheetName = 'Itemized Details';

    if (defaultSheet != null && defaultSheet != summarySheetName) {
      excel.rename(defaultSheet, summarySheetName);
    }

    final summarySheet = excel[summarySheetName];
    final itemizedSheet = excel[itemizedSheetName];

    summarySheet.appendRow([
      TextCellValue('Route Date'),
      TextCellValue('Salesman Name'),
      TextCellValue('Salesman Email'),
      TextCellValue('Invoice Code'),
      TextCellValue('Invoice Date'),
      TextCellValue('Customer Code'),
      TextCellValue('Customer Name'),
      TextCellValue('TIN'),
      TextCellValue('Address'),
      TextCellValue('CS'),
      TextCellValue('SC'),
      TextCellValue('PC'),
      TextCellValue('Item Count'),
      TextCellValue('Vatable Sales'),
      TextCellValue('VAT (12%)'),
      TextCellValue('Total Amount'),
    ]);

    itemizedSheet.appendRow([
      TextCellValue('Route Date'),
      TextCellValue('Salesman Name'),
      TextCellValue('Salesman Email'),
      TextCellValue('Invoice Code'),
      TextCellValue('Customer Name'),
      TextCellValue('Page No'),
      TextCellValue('Seq'),
      TextCellValue('Item Code'),
      TextCellValue('Item Description'),
      TextCellValue('Qty'),
      TextCellValue('UOM'),
      TextCellValue('Unit Price'),
      TextCellValue('Line Amount'),
    ]);

    final sortedRecords = List<SalesmanTransactionExportRecord>.from(records)
      ..sort((a, b) {
        final dateCmp = a.transaction.routeDate.compareTo(
          b.transaction.routeDate,
        );
        if (dateCmp != 0) return dateCmp;
        final nameCmp = _salesmanLabel(a.salesman).toLowerCase().compareTo(
          _salesmanLabel(b.salesman).toLowerCase(),
        );
        if (nameCmp != 0) return nameCmp;
        return a.transaction.capturedAt.compareTo(b.transaction.capturedAt);
      });

    for (final rec in sortedRecords) {
      final tx = rec.transaction;
      final salesmanName = _salesmanLabel(rec.salesman);
      final totalAmount = _round2(tx.totalAmount);
      final vatable = _round2(totalAmount / 1.12);
      final vat = _round2(totalAmount - vatable);

      summarySheet.appendRow([
        TextCellValue(tx.routeDate),
        TextCellValue(salesmanName),
        TextCellValue(rec.salesman.email),
        TextCellValue(tx.invoiceCode),
        TextCellValue(tx.invoiceDate),
        TextCellValue(tx.customerCode),
        TextCellValue(tx.customerName),
        TextCellValue(tx.tin ?? ''),
        TextCellValue(tx.address),
        DoubleCellValue(tx.csQty),
        DoubleCellValue(tx.scQty),
        DoubleCellValue(tx.pcQty),
        IntCellValue(tx.items.length),
        DoubleCellValue(vatable),
        DoubleCellValue(vat),
        DoubleCellValue(totalAmount),
      ]);

      for (final item in tx.items) {
        itemizedSheet.appendRow([
          TextCellValue(tx.routeDate),
          TextCellValue(salesmanName),
          TextCellValue(rec.salesman.email),
          TextCellValue(tx.invoiceCode),
          TextCellValue(tx.customerName),
          IntCellValue(item.pageNo),
          IntCellValue(item.sequence),
          TextCellValue(item.code),
          TextCellValue(item.description),
          DoubleCellValue(item.qty),
          TextCellValue(item.uom),
          DoubleCellValue(_round2(item.unitPrice)),
          DoubleCellValue(_round2(item.totalAmount)),
        ]);
      }
    }

    final encoded = excel.encode();
    if (encoded == null) {
      throw StateError('Failed to encode transactions Excel workbook.');
    }
    return encoded;
  }

  Future<TransactionExportResult> exportTransactions({
    required List<SalesmanTransactionExportRecord> records,
    required DateTime startDate,
    required DateTime endDate,
    String? filePrefix,
  }) async {
    if (records.isEmpty) {
      throw StateError('No transactions found for the selected criteria.');
    }

    final startStr = DateFormat('yyyy-MM-dd').format(startDate);
    final endStr = DateFormat('yyyy-MM-dd').format(endDate);
    final datePart = startStr == endStr ? startStr : '${startStr}_to_$endStr';
    final scopePart = filePrefix != null && filePrefix.trim().isNotEmpty
        ? _sanitizeSegment(filePrefix)
        : 'selected_salesmen';
    final fileName = 'transactions_${scopePart}_$datePart.xlsx';

    final bytes = buildWorkbookBytes(records: records);
    final lineItemCount = records.fold<int>(
      0,
      (sum, rec) => sum + rec.transaction.items.length,
    );

    if (kIsWeb) {
      downloadFile(fileName, bytes);
      return TransactionExportResult(
        fileName: fileName,
        savedPath: 'Downloaded to browser',
        invoiceCount: records.length,
        lineItemCount: lineItemCount,
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final outFile = File('${dir.path}${Platform.pathSeparator}$fileName');
    await outFile.writeAsBytes(bytes, flush: true);

    return TransactionExportResult(
      fileName: fileName,
      savedPath: outFile.path,
      invoiceCount: records.length,
      lineItemCount: lineItemCount,
    );
  }
}

