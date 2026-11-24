import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/salesman_performance_helper.dart';
import 'package:compact_sales_monitoring/services/transaction_export_service.dart';
import 'package:compact_sales_monitoring/widgets/fullscreen_invoice_lightbox.dart';

RouteTransaction _makeTx({
  required String id,
  required String invoiceCode,
  required String customerCode,
  required String customerName,
  required double totalAmount,
  int itemCount = 2,
}) {
  final items = List.generate(
    itemCount,
    (i) => InvoiceLineItem(
      sequence: i + 1,
      pageNo: (i ~/ 9) + 1,
      code: 'SKU${i + 1}',
      description: 'Product ${i + 1}',
      qty: 2,
      uom: 'PC',
      unitPrice: totalAmount / (itemCount * 2),
      totalAmount: totalAmount / itemCount,
    ),
  );
  return RouteTransaction(
    transactionId: id,
    routeDate: '2026-11-24',
    salesRepName: 'Juan Dela Cruz',
    salesRepCode: 'REP01',
    customerName: customerName,
    customerCode: customerCode,
    address: 'Cabanatuan City',
    tin: '123-456-789',
    invoiceCode: invoiceCode,
    invoiceDate: '11/24/2026',
    items: items,
    csQty: 1,
    scQty: 0,
    pcQty: itemCount * 2.0,
    totalAmount: totalAmount,
    pageCount: (itemCount / 9).ceil(),
    lat: 15.48,
    lon: 120.96,
    capturedAt: DateTime(2026, 11, 24, 10, 30),
  );
}

SalesRoute _makeRoute(String salesmanId, List<RouteTransaction> txs) {
  final point = RoutePoint(
    lat: 15.48,
    lon: 120.96,
    imageUrl: '',
    timestamp: DateTime(2026, 11, 24, 8, 0),
  );
  return SalesRoute(
    routeId: 'r_$salesmanId',
    salesmanId: salesmanId,
    supervisorId: 'sup_1',
    date: '2026-11-24',
    first: point,
    last: point,
    hasLastCall: false,
    transactions: txs,
  );
}

AppUser _makeSalesman(
  String uid,
  SalesmanClassification classification,
) {
  return AppUser(
    uid: uid,
    email: '$uid@kenea.com',
    name: 'Salesman $uid',
    role: UserRole.salesman,
    active: true,
    supervisorId: 'sup_1',
    salesmanClassification: classification,
    logoutRequestPending: false,
    logoutRequestApproved: false,
  );
}

void main() {
  group('SalesmanPerformanceHelper', () {
    test('Van Ex-Truck derives Actual Productive Calls (unique customers) and Actual STT from transactions', () {
      final vanSalesman = _makeSalesman('van1', SalesmanClassification.vanExTruck);
      final route = _makeRoute('van1', [
        _makeTx(
          id: 't1',
          invoiceCode: 'INV-1',
          customerCode: 'CUST-A',
          customerName: 'Store Alpha',
          totalAmount: 100.50,
        ),
        // Same customerCode -> should NOT double-count productive calls
        _makeTx(
          id: 't2',
          invoiceCode: 'INV-2',
          customerCode: 'cust-a',
          customerName: 'Store Alpha Branch',
          totalAmount: 50.25,
        ),
        // Blank customerCode -> falls back to normalized customerName
        _makeTx(
          id: 't3',
          invoiceCode: 'INV-3',
          customerCode: '',
          customerName: '  Store   Beta ',
          totalAmount: 200.00,
        ),
        _makeTx(
          id: 't4',
          invoiceCode: 'INV-4',
          customerCode: '',
          customerName: 'store beta',
          totalAmount: 49.25,
        ),
      ]);

      final metrics = SalesmanPerformanceHelper.resolveForDate(
        salesman: vanSalesman,
        agileSubmission: const AgileSubmission(
          salesmanId: 'van1',
          supervisorId: 'sup_1',
          date: '2026-11-24',
          totalCalls: 99,
          productiveCalls: 99,
          sttActual: 9999.0,
          lastCallCompleted: true,
          submitted: true,
        ),
        salesmanRoutes: [route],
      );

      expect(metrics.isFromTransactions, isTrue);
      expect(metrics.hasData, isTrue);
      expect(metrics.productiveCalls, 2); // CUST-A + STORE BETA
      expect(metrics.stt, 400.00);
    });

    test('Booking salesman continues reading from AgileSubmission', () {
      final bookingSalesman = _makeSalesman('book1', SalesmanClassification.booking);
      final metrics = SalesmanPerformanceHelper.resolveForDate(
        salesman: bookingSalesman,
        agileSubmission: const AgileSubmission(
          salesmanId: 'book1',
          supervisorId: 'sup_1',
          date: '2026-11-24',
          totalCalls: 15,
          productiveCalls: 12,
          sttActual: 15430.75,
          lastCallCompleted: true,
          submitted: true,
        ),
        salesmanRoutes: [
          _makeRoute('book1', [
            _makeTx(
              id: 't_ignored',
              invoiceCode: 'INV-X',
              customerCode: 'C1',
              customerName: 'Ignored',
              totalAmount: 5.0,
            ),
          ]),
        ],
      );

      expect(metrics.isFromTransactions, isFalse);
      expect(metrics.hasData, isTrue);
      expect(metrics.productiveCalls, 12);
      expect(metrics.stt, 15430.75);
    });
  });

  group('TransactionExportService', () {
    test('builds 2-sheet Excel workbook with Transactions Summary and Itemized Details', () {
      final salesman = _makeSalesman('van1', SalesmanClassification.vanExTruck);
      final tx = _makeTx(
        id: 'tx1',
        invoiceCode: 'CBINV-001',
        customerCode: 'C001',
        customerName: 'CAREN STORE',
        totalAmount: 224.0,
        itemCount: 3,
      );

      final service = TransactionExportService();
      final bytes = service.buildWorkbookBytes(
        records: [
          SalesmanTransactionExportRecord(salesman: salesman, transaction: tx),
        ],
      );

      final decoded = Excel.decodeBytes(bytes);
      expect(decoded.tables.keys, contains('Transactions Summary'));
      expect(decoded.tables.keys, contains('Itemized Details'));

      final summaryRows = decoded.tables['Transactions Summary']!.rows;
      final itemizedRows = decoded.tables['Itemized Details']!.rows;

      expect(summaryRows.length, 2); // header + 1 invoice
      expect(itemizedRows.length, 4); // header + 3 line items
      expect(summaryRows[1][3]?.value.toString(), 'CBINV-001');
      expect(summaryRows[1][6]?.value.toString(), 'CAREN STORE');
      expect(itemizedRows[1][3]?.value.toString(), 'CBINV-001');
      expect(itemizedRows[1][7]?.value.toString(), 'SKU1');
    });
  });

  group('FullscreenInvoiceLightbox', () {
    testWidgets('navigates 2-page 9-line invoice using arrow buttons and shows dots', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 11 items -> 2 pages (9 on page 1, 2 on page 2)
      final tx = _makeTx(
        id: 'tx_multi',
        invoiceCode: 'CBINV-MULTI',
        customerCode: 'C99',
        customerName: 'MULTI STORE',
        totalAmount: 1100.0,
        itemCount: 11,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FullscreenInvoiceLightbox(transaction: tx),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PAGE 1 OF 2'), findsOneWidget);
      expect(find.byTooltip('Next page'), findsOneWidget);
      expect(find.byTooltip('Previous page'), findsOneWidget);

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();

      expect(find.text('PAGE 2 OF 2'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous page'));
      await tester.pumpAndSettle();

      expect(find.text('PAGE 1 OF 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

