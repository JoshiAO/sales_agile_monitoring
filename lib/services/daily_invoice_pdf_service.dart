import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/invoice_paginator.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/sfa_invoice_parser.dart';

class DailyPdfSaveResult {
  final String privateFilePath;
  final String publicRelativePath;
  final String fileName;
  final bool savedToPublicDocuments;

  const DailyPdfSaveResult({
    required this.privateFilePath,
    required this.publicRelativePath,
    required this.fileName,
    required this.savedToPublicDocuments,
  });
}

/// Builds and saves the single combined daily PDF containing all captured
/// invoices formatted in the 9-line BIR Sales Invoice layout.
class DailyInvoicePdfService {
  static const MethodChannel _channel = MethodChannel(
    'com.agile.app.jao/pdf_storage',
  );

  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  static String sanitizeFileSegment(String input, {String fallback = 'REP'}) {
    final cleaned = input
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.isEmpty ? fallback : cleaned;
  }

  /// Sanitizes text for built-in Helvetica WinAnsi encoding so PDF generation
  /// never fails or renders missing-glyph boxes on non-Latin1 characters.
  static String _sanitizePdfText(String input) {
    if (input.isEmpty) return '';
    return input
        .replaceAll('\u00A0', ' ')
        .replaceAll('₱', 'PHP ')
        .replaceAll('×', 'x')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll(RegExp(r'[^\x20-\x7E\xA0-\xFF]'), '');
  }

  /// Computes `Agile App/Invoices/[Year]/[Month]/[Salesman Code] - [mm.dd.yy] - Transacted Invoices.pdf`.
  static ({
    String year,
    String month,
    String fileName,
    String relativeDir,
    String relativePath,
  }) buildOutputMetadata({
    required String routeDate,
    required String salesmanCode,
  }) {
    final date = DateTime.tryParse(routeDate) ?? DateTime.now();
    final year = DateFormat('yyyy').format(date);
    final month = DateFormat('MMMM', 'en_US').format(date);
    final shortDate = DateFormat('MM.dd.yy').format(date);
    final safeCode = sanitizeFileSegment(salesmanCode);
    final fileName = '$safeCode - $shortDate - Transacted Invoices.pdf';
    final relativeDir = 'Agile App/Invoices/$year/$month';
    return (
      year: year,
      month: month,
      fileName: fileName,
      relativeDir: relativeDir,
      relativePath: '$relativeDir/$fileName',
    );
  }

  /// Generates the combined PDF bytes for all [transactions] of a given day.
  static Future<Uint8List> buildPdfBytes(
    List<RouteTransaction> transactions,
  ) async {
    final doc = pw.Document(
      title: 'Transacted Invoices',
      author: 'Sales Agile Monitoring',
    );

    final ordered = List<RouteTransaction>.from(transactions)
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));

    for (final tx in ordered) {
      final pages = InvoicePaginator.paginate(tx.items);
      final sheetDate = SfaInvoiceParser.formatSheetDate(
        tx.invoiceDate,
        fallback: tx.capturedAt,
      );

      for (final page in pages) {
        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(24),
            build: (_) => _buildInvoicePdfPage(tx, page, sheetDate),
          ),
        );
      }
    }

    return doc.save();
  }

  static pw.Widget _buildInvoicePdfPage(
    RouteTransaction tx,
    InvoicePageData page,
    String sheetDate,
  ) {
    const borderSide = pw.BorderSide(color: PdfColors.grey800, width: 0.9);
    const lightBorder = pw.BorderSide(color: PdfColors.grey600, width: 0.6);

    return pw.Container(
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey900, width: 1.4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // Top header
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'SALES INVOICE',
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'Ref: ${_sanitizePdfText(tx.invoiceCode)}',
                    style: const pw.TextStyle(
                      fontSize: 9,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'PAGE ${page.pageNo} OF ${page.totalPages}',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    'Date: $sheetDate',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  if (tx.siNumberForPage(page.pageNo) != null) ...[
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'SI No. ${_sanitizePdfText(tx.siNumberForPage(page.pageNo)!)}',
                      style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.red900,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 12),

          // SOLD TO section
          pw.Text(
            'SOLD TO',
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          _pdfLabeledUnderline('Registered Name', tx.customerName),
          pw.SizedBox(height: 4),
          _pdfLabeledUnderline('TIN', tx.tin ?? ''),
          pw.SizedBox(height: 4),
          _pdfLabeledUnderline('Address', tx.address),
          pw.SizedBox(height: 12),

          // 9-row item table
          pw.Table(
            border: const pw.TableBorder(
              top: borderSide,
              bottom: borderSide,
              left: borderSide,
              right: borderSide,
              horizontalInside: lightBorder,
              verticalInside: lightBorder,
            ),
            columnWidths: const {
              0: pw.FixedColumnWidth(28),
              1: pw.FlexColumnWidth(4.5),
              2: pw.FlexColumnWidth(1.3),
              3: pw.FlexColumnWidth(1.3),
              4: pw.FlexColumnWidth(1.5),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [
                  _tableHeaderCell('No.', align: pw.TextAlign.center),
                  _tableHeaderCell('Item Description'),
                  _tableHeaderCell('QTY', align: pw.TextAlign.center),
                  _tableHeaderCell('U-Price', align: pw.TextAlign.right),
                  _tableHeaderCell('Amount', align: pw.TextAlign.right),
                ],
              ),
              for (var rowIdx = 0; rowIdx < InvoicePaginator.maxLinesPerPage; rowIdx++)
                _buildDataRow(
                  rowIdx + 1,
                  rowIdx < page.items.length ? page.items[rowIdx] : null,
                ),
            ],
          ),
          pw.SizedBox(height: 10),

          // Totals section
          pw.Container(
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey800, width: 0.9),
            ),
            padding: const pw.EdgeInsets.all(10),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _totalRow('VATABLE SALES:', _moneyFormat.format(page.vatableSales)),
                pw.SizedBox(height: 4),
                _totalRow('VAT:', _moneyFormat.format(page.vat)),
                pw.Divider(color: PdfColors.grey700, thickness: 0.8),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'TOTAL AMOUNT DUE',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      _moneyFormat.format(page.totalAmountDue),
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          pw.Spacer(),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                _sanitizePdfText('SalesRep: ${tx.salesRepCode} ${tx.salesRepName}'.trim()),
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
              ),
              pw.Text(
                _sanitizePdfText('Customer Code: ${tx.customerCode}'),
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _pdfLabeledUnderline(String label, String value) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Text('$label: ', style: const pw.TextStyle(fontSize: 10)),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.only(bottom: 1, left: 4),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: PdfColors.grey700, width: 0.7),
              ),
            ),
            child: pw.Text(
              value.isEmpty ? ' ' : _sanitizePdfText(value),
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static pw.Widget _tableHeaderCell(
    String text, {
    pw.TextAlign align = pw.TextAlign.left,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
      ),
    );
  }

  static pw.TableRow _buildDataRow(int rowNo, InvoiceLineItem? item) {
    return pw.TableRow(
      children: [
        _tableCell('$rowNo', align: pw.TextAlign.center),
        _tableCell(item?.formattedDescription ?? ''),
        _tableCell(item?.formattedQty ?? '', align: pw.TextAlign.center),
        _tableCell(
          item == null ? '' : _moneyFormat.format(item.unitPrice),
          align: pw.TextAlign.right,
        ),
        _tableCell(
          item == null ? '' : _moneyFormat.format(item.totalAmount),
          align: pw.TextAlign.right,
        ),
      ],
    );
  }

  static pw.Widget _tableCell(
    String text, {
    pw.TextAlign align = pw.TextAlign.left,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 7),
      child: pw.Text(
        text.isEmpty ? ' ' : _sanitizePdfText(text),
        textAlign: align,
        style: const pw.TextStyle(fontSize: 9),
      ),
    );
  }

  static pw.Widget _totalRow(String label, String amount) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 10)),
        pw.Text(
          amount,
          style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold),
        ),
      ],
    );
  }

  /// Rebuilds the daily combined PDF from [transactions] and saves it both in
  /// app-private `invoices/` and in public Android `Documents/Agile App/Invoices/...`.
  static Future<DailyPdfSaveResult?> rebuildAndSaveDailyPdf({
    required String routeDate,
    required String salesmanCode,
    required List<RouteTransaction> transactions,
  }) async {
    if (kIsWeb || transactions.isEmpty) return null;

    final meta = buildOutputMetadata(
      routeDate: routeDate,
      salesmanCode: salesmanCode,
    );
    final bytes = await buildPdfBytes(transactions);

    final appDir = await getApplicationDocumentsDirectory();
    final privateDir = Directory('${appDir.path}/${meta.relativeDir}');
    if (!await privateDir.exists()) {
      await privateDir.create(recursive: true);
    }
    final privateFile = File('${privateDir.path}/${meta.fileName}');
    await privateFile.writeAsBytes(bytes, flush: true);

    var savedPublic = false;
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<bool>('savePdfToMediaStore', {
          'relativeSubDir': meta.relativeDir,
          'fileName': meta.fileName,
          'bytes': bytes,
        });
        savedPublic = result ?? false;
      } catch (e) {
        debugPrint('[DailyInvoicePdfService] MediaStore save failed: $e');
      }
    }

    return DailyPdfSaveResult(
      privateFilePath: privateFile.path,
      publicRelativePath: 'Documents/${meta.relativePath}',
      fileName: meta.fileName,
      savedToPublicDocuments: savedPublic,
    );
  }

  /// Resolves the private local PDF path for [routeDate] if it exists on disk.
  static Future<String?> findExistingPrivatePdfPath({
    required String routeDate,
    required String salesmanCode,
  }) async {
    if (kIsWeb) return null;
    final meta = buildOutputMetadata(
      routeDate: routeDate,
      salesmanCode: salesmanCode,
    );
    final appDir = await getApplicationDocumentsDirectory();
    final directFile = File('${appDir.path}/${meta.relativePath}');
    if (await directFile.exists()) {
      return directFile.path;
    }

    // Fallback scan inside the month folder in case salesman code varied
    final monthDir = Directory('${appDir.path}/${meta.relativeDir}');
    if (!await monthDir.exists()) return null;
    final date = DateTime.tryParse(routeDate);
    if (date == null) return null;
    final shortDate = DateFormat('MM.dd.yy').format(date);

    await for (final entity in monthDir.list()) {
      if (entity is File && entity.path.contains(shortDate) && entity.path.endsWith('.pdf')) {
        return entity.path;
      }
    }
    return null;
  }

  /// Opens [filePath] in an external PDF viewer excluding our own invoice interceptor.
  static Future<bool> openPdfExternally(String filePath) async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      try {
        final opened = await _channel.invokeMethod<bool>(
          'openPdfExcludingSelf',
          {'filePath': filePath},
        );
        return opened ?? false;
      } catch (e) {
        debugPrint('[DailyInvoicePdfService] openPdfExternally failed: $e');
        return false;
      }
    }
    return false;
  }
}

