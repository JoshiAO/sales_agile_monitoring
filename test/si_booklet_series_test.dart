import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/daily_invoice_pdf_service.dart';
import 'package:compact_sales_monitoring/services/si_series_engine.dart';
import 'package:compact_sales_monitoring/services/transaction_export_service.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';

RouteTransaction _makeTx({
  required String id,
  required String invoiceCode,
  required int pageCount,
  List<String?> pageSiNumbers = const [],
  List<SiVoidEntry> voidedSiEntries = const [],
  DateTime? capturedAt,
  TransactionUploadStatus uploadStatus = TransactionUploadStatus.uploaded,
}) {
  final itemCount = (pageCount - 1) * 9 + 1;
  final items = List.generate(
    itemCount,
    (i) => InvoiceLineItem(
      sequence: (i % 9) + 1,
      pageNo: (i ~/ 9) + 1,
      code: 'SKU${i + 1}',
      description: 'Item ${i + 1}',
      qty: 1,
      uom: 'PC',
      unitPrice: 100.0,
      totalAmount: 100.0,
    ),
  );
  return RouteTransaction(
    transactionId: id,
    routeDate: '2026-11-27',
    salesRepName: 'Juan Dela Cruz',
    salesRepCode: 'REP01',
    customerName: 'CAREN STORE',
    customerCode: 'CUST-01',
    address: 'Cabanatuan City',
    tin: '123-456-789',
    invoiceCode: invoiceCode,
    invoiceDate: '11/27/2026',
    items: items,
    csQty: 0,
    scQty: 0,
    pcQty: itemCount.toDouble(),
    totalAmount: itemCount * 100.0,
    pageCount: pageCount,
    lat: 15.48,
    lon: 120.96,
    capturedAt: capturedAt ?? DateTime(2026, 11, 27, 10, 0),
    pageSiNumbers: pageSiNumbers,
    voidedSiEntries: voidedSiEntries,
    uploadStatus: uploadStatus,
  );
}

SalesmanSiBookletState _makeState(List<SiBooklet> booklets, {int revision = 1}) {
  return SalesmanSiBookletState(
    salesmanId: 'van1',
    companyId: 'COMP1',
    revision: revision,
    booklets: booklets,
    updatedAt: DateTime(2026, 11, 27, 8, 0),
  );
}

void main() {
  group('SiSeriesEngine.parseBookletInput', () {
    test('preserves leading zeros and validates pure digits', () {
      final padded = SiSeriesEngine.parseBookletInput('0001001', '0001050');
      expect(padded.startNumber, 1001);
      expect(padded.endNumber, 1050);
      expect(padded.padWidth, 7);
      expect(padded.totalPages, 50);
      expect(padded.startFormatted, '0001001');
      expect(padded.endFormatted, '0001050');

      final plain = SiSeriesEngine.parseBookletInput('123456', '123500');
      expect(plain.padWidth, 0);
      expect(plain.startFormatted, '123456');
      expect(plain.endFormatted, '123500');

      expect(
        () => SiSeriesEngine.parseBookletInput('SI-123', '125'),
        throwsFormatException,
      );
      expect(
        () => SiSeriesEngine.parseBookletInput('123500', '123456'),
        throwsFormatException,
      );
    });
  });

  group('SiSeriesEngine.formatSeriesSummary', () {
    test('formats single page, contiguous range, thousand boundary, and void splits', () {
      expect(SiSeriesEngine.formatSeriesSummary(['123456']), '123456');
      expect(
        SiSeriesEngine.formatSeriesSummary([
          '1223456',
          '1223457',
          '1223458',
          '1223459',
          '1223460',
          '1223461',
        ]),
        '1223456-461',
      );
      expect(
        SiSeriesEngine.formatSeriesSummary([
          '123456',
          '123457',
          '123458',
          '123460',
          '123461',
        ]),
        '123456-458,123460-461',
      );
      expect(
        SiSeriesEngine.formatSeriesSummary([
          '123998',
          '123999',
          '124000',
          '124001',
          '124002',
        ]),
        '123998-124002',
      );
      expect(
        SiSeriesEngine.formatSeriesSummary([
          '0001001',
          '0001002',
          '0001004',
          '0001005',
        ]),
        '0001001-002,0001004-005',
      );
      expect(
        SiSeriesEngine.formatSeriesSummary(['123499', '123500', null]),
        '123499-500',
      );
    });
  });

  group('SiSeriesEngine.allocatePages', () {
    test('consumes smallest-to-highest across multiple booklets and handles exhaustion non-blockingly', () {
      // Intentionally pass Booklet B before Booklet A to verify sorting by startNumber
      final state = _makeState([
        SiBooklet(
          id: 'b2',
          startNumber: 200001,
          endNumber: 200002,
          padWidth: 6,
          nextNumber: 200001,
          createdAt: DateTime(2026, 11, 27),
        ),
        SiBooklet(
          id: 'b1',
          startNumber: 123499,
          endNumber: 123500,
          padWidth: 6,
          nextNumber: 123499,
          createdAt: DateTime(2026, 11, 27),
        ),
      ]);

      // 3-page invoice spans Booklet 1 (123499, 123500) into Booklet 2 (200001)
      final alloc1 = SiSeriesEngine.allocatePages(state, 3);
      expect(alloc1.exhausted, isFalse);
      expect(alloc1.pageSiNumbers, ['123499', '123500', '200001']);
      expect(alloc1.updatedState.totalRemainingPages, 1);

      // Next 2-page invoice gets last page (200002) + null (non-blocking exhaustion)
      final alloc2 = SiSeriesEngine.allocatePages(alloc1.updatedState, 2);
      expect(alloc2.exhausted, isTrue);
      expect(alloc2.pageSiNumbers, ['200002', null]);
      expect(alloc2.updatedState.totalRemainingPages, 0);
    });
  });

  group('Salesman Void & Encoder Cascade / Un-Void', () {
    test('salesman live void shifts page + remaining pages and marks needsRemoteUpdate', () {
      final state = _makeState([
        SiBooklet(
          id: 'b1',
          startNumber: 123456,
          endNumber: 123500,
          padWidth: 6,
          nextNumber: 123461,
          createdAt: DateTime(2026, 11, 27),
        ),
      ]);
      final tx = _makeTx(
        id: 'tx1',
        invoiceCode: 'INV-1',
        pageCount: 5,
        pageSiNumbers: ['123456', '123457', '123458', '123459', '123460'],
        uploadStatus: TransactionUploadStatus.uploaded,
      );

      final result = SiSeriesEngine.voidPageOnTransaction(
        state: state,
        transaction: tx,
        pageNo: 4,
        reason: 'Wrong handwriting',
        voidedBy: 'van1',
      );

      expect(result.voidedEntry.siNumber, '123459');
      expect(
        result.updatedTransaction.pageSiNumbers,
        ['123456', '123457', '123458', '123460', '123461'],
      );
      expect(
        result.updatedTransaction.formattedSiSeriesSummary,
        '123456-458,123460-461',
      );
      expect(result.updatedTransaction.formattedVoidedSiSummary, '123459');
      expect(result.updatedTransaction.needsRemoteUpdate, isTrue);
      expect(result.updatedState.nextAvailableFormatted, '123462');
    });

    test('encoder void cascades chronologically (clock-skew proof) and un-void restores cleanly', () {
      final state = _makeState([
        SiBooklet(
          id: 'b1',
          startNumber: 123456,
          endNumber: 123500,
          padWidth: 6,
          nextNumber: 123460,
          createdAt: DateTime(2026, 11, 27),
        ),
      ]);

      // Simulate clock skew: tx2 has an EARLIER capturedAt than tx1, but higher SI numbers!
      final tx1 = _makeTx(
        id: 'tx1',
        invoiceCode: 'INV-1',
        pageCount: 2,
        pageSiNumbers: ['123456', '123457'],
        capturedAt: DateTime(2026, 11, 27, 11, 0),
      );
      final tx2 = _makeTx(
        id: 'tx2',
        invoiceCode: 'INV-2',
        pageCount: 2,
        pageSiNumbers: ['123458', '123459'],
        capturedAt: DateTime(2026, 11, 27, 9, 30),
      );

      final voidPreview = SiSeriesEngine.previewEncoderVoidCascade(
        state: state,
        scopedTransactions: [tx1, tx2],
        targetTransactionId: 'tx1',
        targetPageNo: 2,
        reason: 'Torn sheet',
        voidedBy: 'enc1',
        voidedByRole: 'encoder',
      );

      expect(voidPreview.diffs.length, 2);
      final afterTx1 = voidPreview.diffs[0].after;
      final afterTx2 = voidPreview.diffs[1].after;
      expect(afterTx1.pageSiNumbers, ['123456', '123458']);
      expect(afterTx1.formattedVoidedSiSummary, '123457');
      expect(afterTx2.pageSiNumbers, ['123459', '123460']);
      expect(voidPreview.updatedState.nextAvailableFormatted, '123461');
      expect(voidPreview.updatedState.revision, 2);

      // Now Un-Void 123457 and verify exact restoration + booklet pointer rollback!
      final unvoidPreview = SiSeriesEngine.previewEncoderUnvoidCascade(
        state: voidPreview.updatedState,
        scopedTransactions: [afterTx1, afterTx2],
        targetTransactionId: 'tx1',
        voidedSiNumber: '123457',
      );

      expect(unvoidPreview.diffs[0].after.pageSiNumbers, ['123456', '123457']);
      expect(unvoidPreview.diffs[0].after.voidedSiEntries, isEmpty);
      expect(unvoidPreview.diffs[1].after.pageSiNumbers, ['123458', '123459']);
      expect(unvoidPreview.updatedState.nextAvailableFormatted, '123460');
      expect(unvoidPreview.updatedState.revision, 3);
    });
  });

  group('Excel Export & Daily PDF & SalesInvoiceViewer', () {
    test('TransactionExportService writes SI Series + Voided SI to Summary and per-page SI to Itemized Details', () {
      final salesman = AppUser(
        uid: 'van1',
        email: 'van1@kenea.com',
        name: 'Juan Dela Cruz',
        role: UserRole.salesman,
        active: true,
        salesmanClassification: SalesmanClassification.vanExTruck,
        logoutRequestPending: false,
        logoutRequestApproved: false,
      );

      final tx = _makeTx(
        id: 'tx1',
        invoiceCode: 'CBINV-500',
        pageCount: 5,
        pageSiNumbers: ['123456', '123457', '123458', '123460', '123461'],
        voidedSiEntries: [
          SiVoidEntry(
            siNumber: '123459',
            numericValue: 123459,
            pageNo: 4,
            voidedAt: DateTime(2026, 11, 27, 10, 5),
          ),
        ],
      );

      final bytes = TransactionExportService().buildWorkbookBytes(
        records: [
          SalesmanTransactionExportRecord(salesman: salesman, transaction: tx),
        ],
      );
      final decoded = Excel.decodeBytes(bytes);

      final summaryRows = decoded.tables['Transactions Summary']!.rows;
      final itemizedRows = decoded.tables['Itemized Details']!.rows;

      // Summary headers & values
      expect(summaryRows[0][16]?.value.toString(), 'SI Series');
      expect(summaryRows[0][17]?.value.toString(), 'Voided SI');
      expect(summaryRows[1][16]?.value.toString(), '123456-458,123460-461');
      expect(summaryRows[1][17]?.value.toString(), '123459');

      // Itemized Details per-page SI series
      expect(itemizedRows[0][13]?.value.toString(), 'SI Series');
      // Item 1 -> page 1 -> 123456
      expect(itemizedRows[1][5]?.value.toString(), '1');
      expect(itemizedRows[1][13]?.value.toString(), '123456');
      // Item 10 -> page 2 -> 123457
      expect(itemizedRows[10][5]?.value.toString(), '2');
      expect(itemizedRows[10][13]?.value.toString(), '123457');
      // Item 37 -> page 5 -> 123461
      expect(itemizedRows[37][5]?.value.toString(), '5');
      expect(itemizedRows[37][13]?.value.toString(), '123461');
    });

    test('DailyInvoicePdfService builds PDF with SI series numbers', () async {
      final tx = _makeTx(
        id: 'tx_pdf',
        invoiceCode: 'CBINV-PDF',
        pageCount: 2,
        pageSiNumbers: ['0001001', '0001002'],
      );
      final pdfBytes = await DailyInvoicePdfService.buildPdfBytes([tx]);
      expect(pdfBytes.length, greaterThan(500));
    });

    testWidgets('SalesInvoiceViewer shows SI No. under date and supports Void Page staying on current page', (
      tester,
    ) async {
      final tx = _makeTx(
        id: 'tx_ui',
        invoiceCode: 'CBINV-UI',
        pageCount: 2,
        pageSiNumbers: ['123456', '123457'],
      );

      String? capturedReason;
      int? capturedPageNo;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 760,
              child: SalesInvoiceViewer(
                transaction: tx,
                showCloseButton: true,
                onVoidPageRequested: (pageNo, reason) async {
                  capturedPageNo = pageNo;
                  capturedReason = reason;
                  return tx.copyWith(
                    pageSiNumbers: ['123456', '123458'],
                    voidedSiEntries: [
                      SiVoidEntry(
                        siNumber: '123457',
                        numericValue: 123457,
                        pageNo: 2,
                        reason: reason,
                        voidedAt: DateTime(2026, 11, 27),
                      ),
                    ],
                    siRevision: 1,
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('SI No. 123456'), findsOneWidget);

      // Navigate to Page 2
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('SI No. 123457'), findsOneWidget);

      // Tap Void Page -> confirm dialog -> enter reason -> confirm
      await tester.tap(find.text('Void Page'));
      await tester.pumpAndSettle();
      expect(find.text('Void SI No. 123457?'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Smudged ink');
      await tester.tap(find.text('Yes, Void Page'));
      await tester.pumpAndSettle();

      expect(capturedPageNo, 2);
      expect(capturedReason, 'Smudged ink');
      // Still on Page 2, now showing the shifted SI No. 123458!
      expect(find.text('PAGE 2 OF 2'), findsOneWidget);
      expect(find.text('SI No. 123458'), findsOneWidget);
      expect(find.text('Voided SI: 123457'), findsOneWidget);
    });
  });
}

