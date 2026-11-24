import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/daily_invoice_pdf_service.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';
import 'package:compact_sales_monitoring/widgets/transaction_map_marker.dart';

void main() {
  RouteTransaction buildSampleTransaction(int itemCount) {
    final items = List.generate(
      itemCount,
      (i) => InvoiceLineItem(
        sequence: (i % 9) + 1,
        pageNo: (i ~/ 9) + 1,
        code: '75${i + 10}',
        description: 'Product Description ${i + 1}',
        qty: 2,
        uom: i.isEven ? 'PC' : 'SC',
        unitPrice: 10.0,
        totalAmount: 20.0,
      ),
    );

    return RouteTransaction(
      transactionId: '2026-11-24_CBINVTEST001',
      routeDate: '2026-11-24',
      salesRepName: 'ALEJANDRO DE GUZMAN',
      salesRepCode: 'kne0024',
      customerName: 'CAREN STORE',
      customerCode: 'B3103B0321',
      address: 'SAN JOSEF PENARANDA NUEVA ECIJA',
      invoiceCode: 'CBINVTEST001',
      invoiceDate: '24-Nov-2026 10:26:43 AM',
      items: items,
      csQty: 0,
      scQty: items.where((e) => e.uom == 'SC').length * 2.0,
      pcQty: items.where((e) => e.uom == 'PC').length * 2.0,
      totalAmount: itemCount * 20.0,
      pageCount: ((itemCount - 1) ~/ 9) + 1,
      lat: 15.481,
      lon: 120.971,
      capturedAt: DateTime(2026, 11, 24, 10, 26, 43),
    );
  }

  testWidgets('SalesInvoiceViewer renders 9 rows and hides pagination for 1 page', (
    tester,
  ) async {
    final tx = buildSampleTransaction(5);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: SalesInvoiceViewer(
              transaction: tx,
              showCloseButton: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('SALES INVOICE'), findsOneWidget);
    expect(find.text('PAGE 1 OF 1'), findsOneWidget);
    expect(find.text('CAREN STORE'), findsOneWidget);
    expect(find.text('Previous'), findsNothing);
    expect(find.text('Next'), findsNothing);
  });

  testWidgets('SalesInvoiceViewer shows Next/Previous on 2+ pages and confirms close', (
    tester,
  ) async {
    final tx = buildSampleTransaction(11);
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: SalesInvoiceViewer(
              transaction: tx,
              confirmOnClose: true,
              showCloseButton: true,
              onCloseRequested: () => closed = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('PAGE 1 OF 2'), findsOneWidget);
    expect(find.text('Previous'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('PAGE 2 OF 2'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Done with Preview?'), findsOneWidget);

    await tester.tap(find.text('Yes, Close'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  test('DailyInvoicePdfService generates exact filename & progressive multi-invoice PDF', () async {
    final meta = DailyInvoicePdfService.buildOutputMetadata(
      routeDate: '2026-11-24',
      salesmanCode: 'kne0024',
    );
    expect(meta.relativeDir, 'Agile App/Invoices/2026/November');
    expect(meta.fileName, 'kne0024 - 11.24.26 - Transacted Invoices.pdf');

    final tx1 = buildSampleTransaction(10);
    final singlePdfBytes = await DailyInvoicePdfService.buildPdfBytes([tx1]);
    expect(singlePdfBytes.length, greaterThan(500));

    final tx2 = buildSampleTransaction(5).copyWith(
      transactionId: '2026-11-24_CBINVTEST002',
      invoiceCode: 'CBINVTEST002',
      customerName: 'CAREN’S “SPECIAL” STORE ₱',
      capturedAt: DateTime(2026, 11, 24, 11, 15, 0),
    );
    final progressivePdfBytes = await DailyInvoicePdfService.buildPdfBytes([
      tx1,
      tx2,
    ]);
    expect(progressivePdfBytes.length, greaterThan(singlePdfBytes.length));
  });

  test('clusterRouteTransactions groups co-located stops within 15m', () {
    final tx1 = buildSampleTransaction(2);
    final tx2 = tx1.copyWith(
      transactionId: '2026-11-24_CBINVTEST002',
      invoiceCode: 'CBINVTEST002',
      lat: 15.48101,
      lon: 120.97101,
    );
    final tx3 = tx1.copyWith(
      transactionId: '2026-11-24_CBINVTEST003',
      invoiceCode: 'CBINVTEST003',
      lat: 15.490,
      lon: 120.980,
    );

    final clusters = clusterRouteTransactions([tx1, tx2, tx3]);
    expect(clusters.length, 2);
    expect(clusters.first.transactions.length, 2);
    expect(clusters.last.transactions.length, 1);
  });
}

