import 'dart:math' as math;
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/esc_pos_sanitizer.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/invoice_paginator.dart';

class SfaInvoiceParseException implements Exception {
  final String message;
  const SfaInvoiceParseException(this.message);

  @override
  String toString() => 'SfaInvoiceParseException: $message';
}

class ParsedSfaInvoice {
  final RouteTransaction transaction;
  final List<InvoicePageData> pages;
  final double? printedVatableSales;
  final double? printedVat;
  final double? printedGrandTotal;
  final bool hasIntegrityWarning;

  const ParsedSfaInvoice({
    required this.transaction,
    required this.pages,
    this.printedVatableSales,
    this.printedVat,
    this.printedGrandTotal,
    this.hasIntegrityWarning = false,
  });
}

/// Parses SFA `PROFORMA INVOICE` text from both PDFBox structured extraction
/// and raw/thermal receipt text.
class SfaInvoiceParser {
  static const String pdfRowPrefix = '[PDF_TABLE_ROW]\t';

  static final RegExp _headerFieldPattern = RegExp(
    r'^(SalesRep Name|SalesRep Code|Customer Name|Customer Code|Address|Invoice Code|Invoiced Date|Invoice Date|TIN)\s*:?\s*(.*)$',
    caseSensitive: false,
  );

  static final RegExp _trailingMetricsPattern = RegExp(
    r'(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z\s\-]*?)\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$',
  );

  static final RegExp _standaloneMetricsPattern = RegExp(
    r'^\s*(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z\s\-]*?)\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$',
  );

  static final RegExp _thermalCodeDescPattern = RegExp(
    r'^\s*([A-Za-z0-9\-]{3,16})\s+(.+?)\s*$',
  );

  static final RegExp _footerVatablePattern = RegExp(
    r'Vatable\s+Sales\s*=\s*([\d,]+\.\d{2})',
    caseSensitive: false,
  );
  static final RegExp _footerVatPattern = RegExp(
    r'12%\s*VAT\s*=\s*([\d,]+\.\d{2})',
    caseSensitive: false,
  );
  static final RegExp _footerGrandTotalPattern = RegExp(
    r'Grand\s+total\s*=\s*([\d,]+\.\d{2})',
    caseSensitive: false,
  );

  /// Fast check to determine whether extracted PDF/text belongs to an SFA Proforma Invoice.
  static bool isSfaInvoiceText(String rawText) {
    final upper = EscPosSanitizer.normalizeText(rawText).toUpperCase();
    final hasTitle = upper.contains('PROFORMA INVOICE');
    final hasIdentifier =
        upper.contains('INVOICE CODE') || upper.contains('SALESREP CODE');
    return hasTitle && hasIdentifier;
  }

  /// Parses sanitized/structured invoice text into a paginated [ParsedSfaInvoice].
  static ParsedSfaInvoice parse({
    required String rawText,
    DateTime? capturedAt,
    double lat = 0.0,
    double lon = 0.0,
    double? accuracyMeters,
    int? batteryLevel,
    bool? isMobileDataOn,
    bool? isWifiOn,
    TransactionUploadStatus uploadStatus = TransactionUploadStatus.pending,
  }) {
    final normalized = EscPosSanitizer.normalizeText(rawText);
    if (!isSfaInvoiceText(normalized)) {
      throw const SfaInvoiceParseException(
        'Document does not match SFA Proforma Invoice format.',
      );
    }

    final commitTime = capturedAt ?? DateTime.now();
    final lines = normalized.split('\n');

    String salesRepName = '';
    String salesRepCode = '';
    String customerName = '';
    String customerCode = '';
    String address = '';
    String invoiceCode = '';
    String invoiceDate = '';
    String? tin;

    String? activeHeaderKey;
    var inTableSection = false;
    var inFooterSection = false;

    final rawItems = <InvoiceLineItem>[];
    String? pendingCode;
    final pendingDescParts = <String>[];

    void flushPendingDescriptionLine(String text) {
      if (pendingCode == null) return;
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        pendingDescParts.add(trimmed);
      }
    }

    bool isDividerLine(String line) {
      final t = line.trim();
      return t.isNotEmpty && RegExp(r'^[\-\_=]{4,}$').hasMatch(t);
    }

    bool isTableHeaderLine(String line) {
      final u = line.trim().toUpperCase();
      return u == 'PRODUCT' ||
          u == 'CODE' ||
          u == 'DESCRIPTION' ||
          u == 'QTY' ||
          u == 'UOM' ||
          u == 'UNIT' ||
          u == 'PRICE(INCL.' ||
          u == '12% TAX)' ||
          u == 'LINE' ||
          u == 'TOTAL' ||
          u.startsWith('PRODUCT CODE') ||
          u.startsWith('CODE DESCRIPTION') ||
          u.startsWith('DESCRIPTION QTY') ||
          u.startsWith('QTY UOM');
    }

    double? printedVatableSales;
    double? printedVat;
    double? printedGrandTotal;

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Structured row emitted by Kotlin PdfInvoiceExtractor
      if (trimmed.startsWith(pdfRowPrefix)) {
        inTableSection = true;
        final cols = trimmed.substring(pdfRowPrefix.length).split('\t');
        if (cols.length >= 6) {
          final code = cols[0].trim();
          final desc = cols[1].trim().replaceAll(RegExp(r'\s+'), ' ');
          final qty = _parseDouble(cols[2]) ?? 0.0;
          final uom = normalizeUom(cols[3]);
          final unitPrice = _parseDouble(cols[4]) ?? 0.0;
          final totalAmount = _parseDouble(cols[5]) ?? 0.0;

          if (code.isNotEmpty || desc.isNotEmpty) {
            rawItems.add(
              InvoiceLineItem(
                sequence: rawItems.length + 1,
                pageNo: 1,
                code: code,
                description: desc,
                qty: qty,
                uom: uom,
                unitPrice: unitPrice,
                totalAmount: totalAmount,
              ),
            );
          }
        }
        continue;
      }

      // Check footer totals anywhere after header
      final vatableMatch = _footerVatablePattern.firstMatch(trimmed);
      if (vatableMatch != null) {
        inFooterSection = true;
        inTableSection = false;
        printedVatableSales = _parseDouble(vatableMatch.group(1));
        continue;
      }
      final vatMatch = _footerVatPattern.firstMatch(trimmed);
      if (vatMatch != null) {
        inFooterSection = true;
        inTableSection = false;
        printedVat = _parseDouble(vatMatch.group(1));
        continue;
      }
      final grandMatch = _footerGrandTotalPattern.firstMatch(trimmed);
      if (grandMatch != null) {
        inFooterSection = true;
        inTableSection = false;
        printedGrandTotal = _parseDouble(grandMatch.group(1));
        continue;
      }

      if (inFooterSection) {
        continue;
      }

      // Check header key-value pairs before table starts
      if (!inTableSection) {
        final headerMatch = _headerFieldPattern.firstMatch(trimmed);
        if (headerMatch != null) {
          final key = headerMatch.group(1)!.toLowerCase();
          final value = _cleanHeaderValue(headerMatch.group(2) ?? '');
          activeHeaderKey = key;

          switch (key) {
            case 'salesrep name':
              salesRepName = value;
              break;
            case 'salesrep code':
              salesRepCode = value;
              break;
            case 'customer name':
              customerName = value;
              break;
            case 'customer code':
              customerCode = value;
              break;
            case 'address':
              address = value;
              break;
            case 'invoice code':
              invoiceCode = value;
              break;
            case 'invoiced date':
            case 'invoice date':
              invoiceDate = value;
              break;
            case 'tin':
              tin = value.isEmpty ? null : value;
              break;
          }
          continue;
        }

        // Detect transition into item table
        if (isTableHeaderLine(trimmed) || isDividerLine(trimmed)) {
          activeHeaderKey = null;
          if (isTableHeaderLine(trimmed)) {
            inTableSection = true;
          }
          continue;
        }

        // Handle wrapped address lines (before Invoice Code)
        if (activeHeaderKey == 'address') {
          address = address.isEmpty ? trimmed : '$address $trimmed';
          continue;
        }

        continue;
      }

      // Inside plain-text item table (either thermal or non-structured PDF text)
      if (isDividerLine(trimmed) || isTableHeaderLine(trimmed)) {
        continue;
      }

      // 1. Standalone indented/bottom metrics line (thermal receipt 2nd line OR PDF OCR bottom line)
      final standaloneMatch = _standaloneMetricsPattern.firstMatch(line);
      if (standaloneMatch != null && pendingCode != null) {
        final qty = _parseDouble(standaloneMatch.group(1)) ?? 0.0;
        final uom = normalizeUom(standaloneMatch.group(2)!);
        final unitPrice = _parseDouble(standaloneMatch.group(3)) ?? 0.0;
        final totalAmount = _parseDouble(standaloneMatch.group(4)) ?? 0.0;
        final description = pendingDescParts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();

        rawItems.add(
          InvoiceLineItem(
            sequence: rawItems.length + 1,
            pageNo: 1,
            code: pendingCode,
            description: description,
            qty: qty,
            uom: uom,
            unitPrice: unitPrice,
            totalAmount: totalAmount,
          ),
        );
        pendingCode = null;
        pendingDescParts.clear();
        continue;
      }

      // 2. Single-line item ending with qty + uom + price + total
      final trailingMatch = _trailingMetricsPattern.firstMatch(trimmed);
      if (trailingMatch != null && pendingCode == null) {
        final prefix = trimmed.substring(0, trailingMatch.start).trim();
        final codeDescMatch = _thermalCodeDescPattern.firstMatch(prefix);
        if (codeDescMatch != null) {
          rawItems.add(
            InvoiceLineItem(
              sequence: rawItems.length + 1,
              pageNo: 1,
              code: codeDescMatch.group(1)!.trim(),
              description: codeDescMatch.group(2)!.trim(),
              qty: _parseDouble(trailingMatch.group(1)) ?? 0.0,
              uom: normalizeUom(trailingMatch.group(2)!),
              unitPrice: _parseDouble(trailingMatch.group(3)) ?? 0.0,
              totalAmount: _parseDouble(trailingMatch.group(4)) ?? 0.0,
            ),
          );
          continue;
        }
      }

      // 3. Pending item description continuation (e.g., wrapped PDF description)
      if (pendingCode != null) {
        // Check if this line itself carries trailing metrics (PDF last description line + metrics)
        if (trailingMatch != null) {
          final prefix = trimmed.substring(0, trailingMatch.start).trim();
          flushPendingDescriptionLine(prefix);
          final description = pendingDescParts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
          rawItems.add(
            InvoiceLineItem(
              sequence: rawItems.length + 1,
              pageNo: 1,
              code: pendingCode,
              description: description,
              qty: _parseDouble(trailingMatch.group(1)) ?? 0.0,
              uom: normalizeUom(trailingMatch.group(2)!),
              unitPrice: _parseDouble(trailingMatch.group(3)) ?? 0.0,
              totalAmount: _parseDouble(trailingMatch.group(4)) ?? 0.0,
            ),
          );
          pendingCode = null;
          pendingDescParts.clear();
          continue;
        }

        // Check if a new item code started without finishing previous? Only if clearly numeric code and prev never closed
        flushPendingDescriptionLine(trimmed);
        continue;
      }

      // 4. Start of new item: either "CODE  Description" or standalone "CODE" line
      if (RegExp(r'^\d{3,10}$').hasMatch(trimmed)) {
        pendingCode = trimmed;
        pendingDescParts.clear();
        continue;
      }

      final codeDescMatch = _thermalCodeDescPattern.firstMatch(trimmed);
      if (codeDescMatch != null) {
        pendingCode = codeDescMatch.group(1)!.trim();
        pendingDescParts
          ..clear()
          ..add(codeDescMatch.group(2)!.trim());
        continue;
      }
    }

    if (invoiceCode.isEmpty) {
      throw const SfaInvoiceParseException('Missing Invoice Code.');
    }
    if (rawItems.isEmpty) {
      throw const SfaInvoiceParseException(
        'No line items could be parsed from invoice.',
      );
    }

    final pages = InvoicePaginator.paginate(rawItems);
    final paginatedItems = pages.expand((p) => p.items).toList();

    var csQty = 0.0;
    var scQty = 0.0;
    var pcQty = 0.0;
    var itemsTotalSum = 0.0;

    for (final item in paginatedItems) {
      itemsTotalSum += item.totalAmount;
      switch (item.uom) {
        case 'CS':
          csQty += item.qty;
          break;
        case 'SC':
          scQty += item.qty;
          break;
        case 'PC':
          pcQty += item.qty;
          break;
      }
    }

    final totalAmount = InvoicePaginator.round2(itemsTotalSum);
    final tolerance = math.max(0.05, paginatedItems.length * 0.01);
    final hasIntegrityWarning = printedGrandTotal != null &&
        (totalAmount - printedGrandTotal).abs() > tolerance;

    final parsedInvoiceDate = tryParseInvoiceDateTime(invoiceDate);
    final routeDate = DateFormat('yyyy-MM-dd').format(
      parsedInvoiceDate ?? commitTime,
    );

    final transaction = RouteTransaction(
      transactionId: '${routeDate}_$invoiceCode',
      routeDate: routeDate,
      salesRepName: salesRepName,
      salesRepCode: salesRepCode,
      customerName: customerName,
      customerCode: customerCode,
      address: address,
      tin: tin,
      invoiceCode: invoiceCode,
      invoiceDate: invoiceDate,
      items: List.unmodifiable(paginatedItems),
      csQty: InvoicePaginator.round2(csQty),
      scQty: InvoicePaginator.round2(scQty),
      pcQty: InvoicePaginator.round2(pcQty),
      totalAmount: totalAmount,
      printedGrandTotal: printedGrandTotal,
      pageCount: pages.length,
      lat: lat,
      lon: lon,
      accuracyMeters: accuracyMeters,
      capturedAt: commitTime,
      batteryLevel: batteryLevel,
      isMobileDataOn: isMobileDataOn,
      isWifiOn: isWifiOn,
      uploadStatus: uploadStatus,
    );

    return ParsedSfaInvoice(
      transaction: transaction,
      pages: pages,
      printedVatableSales: printedVatableSales,
      printedVat: printedVat,
      printedGrandTotal: printedGrandTotal,
      hasIntegrityWarning: hasIntegrityWarning,
    );
  }

  /// Parses `24-Nov-2026 10:26:43 AM` or `24-Nov-2026` into a [DateTime], or null.
  static DateTime? tryParseInvoiceDateTime(String raw) {
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return null;

    for (final pattern in const [
      'dd-MMM-yyyy hh:mm:ss a',
      'd-MMM-yyyy hh:mm:ss a',
      'dd-MMM-yyyy h:mm:ss a',
      'd-MMM-yyyy h:mm:ss a',
      'dd-MMM-yyyy',
      'yyyy-MM-dd HH:mm:ss',
      'yyyy-MM-dd',
    ]) {
      try {
        return DateFormat(pattern, 'en_US').parseStrict(cleaned);
      } catch (_) {}
    }
    return DateTime.tryParse(cleaned);
  }

  /// Formats `Invoiced Date` cleanly as `MM/dd/yy` for the BIR invoice sheet date box.
  static String formatSheetDate(String invoiceDate, {DateTime? fallback}) {
    final parsed = tryParseInvoiceDateTime(invoiceDate) ?? fallback;
    if (parsed == null) return invoiceDate;
    return DateFormat('MM/dd/yy').format(parsed);
  }

  static String _cleanHeaderValue(String value) {
    var result = value.trim();
    // Clean stray trailing separator dot like "ALEJANDRO DE GUZMAN ."
    result = result.replaceFirst(RegExp(r'\s+\.$'), '').trim();
    return result;
  }

  static double? _parseDouble(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.trim().replaceAll(',', '');
    return double.tryParse(cleaned);
  }
}

