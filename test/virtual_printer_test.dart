import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/esc_pos_sanitizer.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/invoice_paginator.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/sfa_invoice_parser.dart';

void main() {
  group('EscPosSanitizer', () {
    test('strips ESC/POS commands and normalizes full-width characters', () {
      final raw = Uint8List.fromList([
        0x1B, 0x40, // ESC @
        0x1B, 0x61, 0x01, // ESC a 1 (center)
        ...'PROFORMA INVOICE\r\n'.codeUnits,
        0x1D, 0x56, 0x42, 0x00, // GS V B 0 (cut)
      ]);
      final sanitized = EscPosSanitizer.sanitizeBytes(raw);
      expect(sanitized, 'PROFORMA INVOICE\n');

      final fullWidth = EscPosSanitizer.normalizeText(
        'Payless XTRA BIG Chilimansi （128g）',
      );
      expect(fullWidth, 'Payless XTRA BIG Chilimansi (128g)');
    });
  });

  group('SfaInvoiceParser', () {
    test('parses structured PDF table from real 8-item SFA PDF (merges 2 SFA pages into 1 nine-line page)', () {
      const structuredPayload = '''
PROFORMA INVOICE
KNE
Maharlika Highway San Gregorio Bgy Tramo Santa Rosa Nueva Ecija Tramo
783772241
SalesRep Name:ALEJANDRO DE GUZMAN .
SalesRep Code:kne0024
Customer Name:CAREN STORE
Customer Code:B3103B0321
Address:SAN JOSEF PENARANDA NUEVA ECIJA
Invoice Code:CBINV1795487203141464
Invoiced Date:24-Nov-2026 10:26:43 AM
[PDF_TABLE_ROW]\t7524\tCream-O Choco Fudge 10s R. Pack 30g x 10 x 20\t1\tPiece\t7.06\t7.06
[PDF_TABLE_ROW]\t7506\tCream-O Original Vanilla 10s R. Pack 30g x 10 x 20\t1\tPiece\t7.06\t7.06
[PDF_TABLE_ROW]\t62727\tJnJ Pretzels Berry Knots 25 g\t1\tPiece\t7.71\t7.71
[PDF_TABLE_ROW]\t62728\tJnJ Pretzels Milky Knots 25g\t1\tPiece\t7.71\t7.71
[PDF_TABLE_ROW]\t7636\tPRESTO CREAMS CHOCOLATE 30g x 10 x 20\t1\tPiece\t6.13\t6.13
[PDF_TABLE_ROW]\t7637\tPRESTO CREAMS PEANUT BUTTER 30g x 10x20\t1\tPiece\t6.13\t6.13
[PDF_TABLE_ROW]\t8404\tWAFRETS CHEESE BAR 24g x 10 x 24\t1\tPiece\t6.31\t6.31
[PDF_TABLE_ROW]\t8406\tWAFRETS CHOCO BAR 24g x 10 x 24\t1\tPiece\t6.31\t6.31
Vatable Sales = 48.56
12% VAT = 5.83
Grand total = 54.39
''';

      expect(SfaInvoiceParser.isSfaInvoiceText(structuredPayload), isTrue);
      final parsed = SfaInvoiceParser.parse(rawText: structuredPayload);
      final tx = parsed.transaction;

      expect(tx.salesRepName, 'ALEJANDRO DE GUZMAN');
      expect(tx.salesRepCode, 'kne0024');
      expect(tx.customerName, 'CAREN STORE');
      expect(tx.customerCode, 'B3103B0321');
      expect(tx.address, 'SAN JOSEF PENARANDA NUEVA ECIJA');
      expect(tx.invoiceCode, 'CBINV1795487203141464');
      expect(tx.routeDate, '2026-11-24');
      expect(tx.items.length, 8);
      expect(tx.pcQty, 8);
      expect(tx.csQty, 0);
      expect(tx.scQty, 0);
      expect(tx.pageCount, 1);
      expect(parsed.pages.length, 1);
      expect(tx.totalAmount, 54.42);
      expect(tx.printedGrandTotal, 54.39);
      // 3-centavo unrounded variance across 8 items is within max(0.05, 8*0.01) = 0.08
      expect(parsed.hasIntegrityWarning, isFalse);
      expect(
        SfaInvoiceParser.formatSheetDate(tx.invoiceDate),
        '11/24/26',
      );
    });

    test('parses thermal receipt 1 (unrounded Total preservation & exact 12% VAT)', () {
      const receipt1 = '''
PROFORMA INVOICE
KNE
SalesRep Name MARK GONZALES .
SalesRep Code kne0030
Customer Name LEONY R
Customer Code MDIC1001116
Address BANTUG NORTE CABANATUAN CITY NUEVA ECIJA
Invoice Code CBINV1795234470167459
Invoiced Date 21-Nov-2026 12:14:30 PM
----------------------------------------
Code  Description
  Qty UOM   Price   Total
----------------------------------------
64480  PIATTOS CHEESE 40g x 80
  5 PC   15.98   79.91
63378  PIATTOS ROADHOUSE BBQ 40g x 80
  5 PC   15.98   79.91
67180  PIATTOS SOUR CREAM & ONION 40g x 80
  5 PC   15.98   79.91
62253  POT CHIPS V-CUT SPICY BBQ 25g x 80
  5 PC   16.44   82.21
56280  Payless XTRA BIG Chilimansi （128g）
  6 PC   17.84   107.05
----------------------------------------
Vatable Sales = 383.03
12% VAT = 45.96
Grand total = 428.99
''';

      final parsed = SfaInvoiceParser.parse(rawText: receipt1);
      final tx = parsed.transaction;

      expect(tx.salesRepName, 'MARK GONZALES');
      expect(tx.salesRepCode, 'kne0030');
      expect(tx.routeDate, '2026-11-21');
      expect(tx.items.length, 5);
      expect(tx.items.first.totalAmount, 79.91); // Trust printed Total, not 5 * 15.98
      expect(tx.items.last.description, 'Payless XTRA BIG Chilimansi (128g)');
      expect(tx.pcQty, 26);
      expect(tx.totalAmount, 428.99);
      expect(parsed.pages.single.vatableSales, 383.03);
      expect(parsed.pages.single.vat, 45.96);
      expect(parsed.pages.single.totalAmountDue, 428.99);
      expect(parsed.hasIntegrityWarning, isFalse);
    });

    test('parses thermal receipt 2 (mixed SC and PC UOMs & exact 12% VAT)', () {
      const receipt2 = '''
PROFORMA INVOICE
KNE
SalesRep Name MARK GONZALES .
SalesRep Code kne0030
Customer Name GIGI D.
Customer Code MDIC1002087
Address BITAS CABANATUAN CITY NUEVA ECIJA
Invoice Code CBINV1795241086354459
Invoiced Date 21-Nov-2026 02:04:46 PM
Code  Description
  Qty UOM   Price   Total
7524  Cream-O Choco Fudge 10s R. Pack 30g x 10
  1 SC   70.60   70.60
7506  Cream-O Original Vanilla 10s R. Pack 30g
  1 SC   70.60   70.60
62727 JnJ Pretzels Berry Knots 25 g
  5 PC   7.71    38.53
62726 JnJ Pretzels Choco Knots 25g
  5 PC   7.71    38.53
55721 NISSIN CUP MINI SOTANGHON CHCKN 30g x 48
  5 PC   24.75   123.76
7635  PRESTO CREAMS VANILLA 30g x 10 x 20
  1 SC   61.29   61.29
Vatable Sales = 360.10
12% VAT = 43.21
Grand total = 403.31
''';

      final parsed = SfaInvoiceParser.parse(rawText: receipt2);
      final tx = parsed.transaction;

      expect(tx.scQty, 3);
      expect(tx.pcQty, 15);
      expect(tx.csQty, 0);
      expect(tx.totalAmount, 403.31);
      expect(parsed.pages.single.vatableSales, 360.10);
      expect(parsed.pages.single.vat, 43.21);
      expect(parsed.hasIntegrityWarning, isFalse);
    });

    test('rejects non-invoice text cleanly', () {
      expect(
        SfaInvoiceParser.isSfaInvoiceText('Quarterly Sales Handbook 2026'),
        isFalse,
      );
      expect(
        () => SfaInvoiceParser.parse(rawText: 'Random PDF content'),
        throwsA(isA<SfaInvoiceParseException>()),
      );
    });
  });

  group('InvoicePaginator', () {
    List<InvoiceLineItem> buildItems(int count) {
      return List.generate(
        count,
        (i) => InvoiceLineItem(
          sequence: i + 1,
          pageNo: 1,
          code: '100$i',
          description: 'Item $i',
          qty: 1,
          uom: 'PC',
          unitPrice: 10.0,
          totalAmount: 10.0,
        ),
      );
    }

    test('splits 9, 10, and 19 items into 1, 2, and 3 pages with per-page VAT', () {
      final p9 = InvoicePaginator.paginate(buildItems(9));
      expect(p9.length, 1);
      expect(p9.first.items.length, 9);
      expect(p9.first.items.last.sequence, 9);

      final p10 = InvoicePaginator.paginate(buildItems(10));
      expect(p10.length, 2);
      expect(p10[0].items.length, 9);
      expect(p10[1].items.length, 1);
      expect(p10[1].items.first.sequence, 1);
      expect(p10[1].items.first.pageNo, 2);
      expect(p10[1].totalPages, 2);

      final p19 = InvoicePaginator.paginate(buildItems(19));
      expect(p19.length, 3);
      expect(p19[0].items.length, 9);
      expect(p19[1].items.length, 9);
      expect(p19[2].items.length, 1);
      expect(p19[2].items.first.pageNo, 3);
    });

    test('matches physical BIR Sales Invoice VAT math (284.45 -> 253.97 + 30.48)', () {
      final pages = InvoicePaginator.paginate([
        const InvoiceLineItem(
          sequence: 1,
          pageNo: 1,
          code: 'GT',
          description: 'GT Twin Choco',
          qty: 1,
          uom: 'SC',
          unitPrice: 124.94,
          totalAmount: 124.94,
        ),
        const InvoiceLineItem(
          sequence: 2,
          pageNo: 1,
          code: 'MXC',
          description: 'Maxx Cherry',
          qty: 1,
          uom: 'SC',
          unitPrice: 42.24,
          totalAmount: 42.24,
        ),
        const InvoiceLineItem(
          sequence: 3,
          pageNo: 1,
          code: 'MXO',
          description: 'Maxx Orange',
          qty: 1,
          uom: 'SC',
          unitPrice: 42.24,
          totalAmount: 42.24,
        ),
        const InvoiceLineItem(
          sequence: 4,
          pageNo: 1,
          code: 'RL',
          description: 'Roller',
          qty: 10,
          uom: 'PC',
          unitPrice: 7.50,
          totalAmount: 75.03,
        ),
      ]);

      expect(pages.single.totalAmountDue, 284.45);
      expect(pages.single.vatableSales, 253.97);
      expect(pages.single.vat, 30.48);
    });
  });
}

