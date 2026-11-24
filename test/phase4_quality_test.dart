import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/storage_url_resolver.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';
import 'package:compact_sales_monitoring/widgets/web_transaction_detail_modal.dart';

void main() {
  RouteTransaction buildTx({
    required String code,
    required String customer,
    required int itemCount,
    DateTime? capturedAt,
  }) {
    final items = List.generate(
      itemCount,
      (i) => InvoiceLineItem(
        sequence: (i % 9) + 1,
        pageNo: (i ~/ 9) + 1,
        code: '75${i + 10}',
        description: 'Sample Item ${i + 1}',
        qty: 2,
        uom: 'PC',
        unitPrice: 10.0,
        totalAmount: 20.0,
      ),
    );
    return RouteTransaction(
      transactionId: '2026-11-24_$code',
      routeDate: '2026-11-24',
      salesRepName: 'MARK GONZALES',
      salesRepCode: 'kne0030',
      customerName: customer,
      customerCode: 'C001',
      address: 'CABANATUAN CITY',
      invoiceCode: code,
      invoiceDate: '24-Nov-2026 10:00:00 AM',
      items: items,
      csQty: 0,
      scQty: 0,
      pcQty: itemCount * 2.0,
      totalAmount: itemCount * 20.0,
      pageCount: items.isEmpty ? 1 : ((itemCount - 1) ~/ 9) + 1,
      lat: 15.48,
      lon: 120.97,
      capturedAt: capturedAt ?? DateTime(2026, 11, 24, 10, 0, 0),
    );
  }

  group('StorageUrlResolver', () {
    test('normalizes http URLs to https and preserves gs://', () {
      expect(StorageUrlResolver.normalizeUrl(null), isNull);
      expect(StorageUrlResolver.normalizeUrl('   '), isNull);
      expect(
        StorageUrlResolver.normalizeUrl('gs://bucket/path/img.jpg'),
        'gs://bucket/path/img.jpg',
      );
      expect(
        StorageUrlResolver.normalizeUrl('http://example.com/a.jpg'),
        'https://example.com/a.jpg',
      );
    });

    test('extracts decoded Firebase Storage object path', () {
      final uri = Uri.parse(
        'https://firebasestorage.googleapis.com/v0/b/my-app/o/route_images%2Fu1%2Fcall.jpg?alt=media',
      );
      expect(
        StorageUrlResolver.extractStorageObjectPath(uri),
        'route_images/u1/call.jpg',
      );
    });
  });

  testWidgets(
    'SalesInvoiceViewer resets page on prop change and uses Page X / Y for >7 pages',
    (tester) async {
      final txLarge = buildTx(code: 'INV_BIG', customer: 'STORE A', itemCount: 70);
      final txSmall = buildTx(code: 'INV_SML', customer: 'STORE B', itemCount: 3);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 700,
              child: SalesInvoiceViewer(
                transaction: txLarge,
                showCloseButton: false,
              ),
            ),
          ),
        ),
      );

      expect(find.text('PAGE 1 OF 8'), findsOneWidget);
      expect(find.text('Page 1 / 8'), findsOneWidget);

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('PAGE 2 OF 8'), findsOneWidget);
      expect(find.text('Page 2 / 8'), findsOneWidget);

      // Update transaction prop in-place without changing widget key
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 700,
              child: SalesInvoiceViewer(
                transaction: txSmall,
                showCloseButton: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PAGE 1 OF 1'), findsOneWidget);
      expect(find.text('STORE B'), findsOneWidget);
    },
  );

  testWidgets(
    'WebTransactionDetailModal switches stops, toggles itemized table, and renders on 360px viewport',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final tx1 = buildTx(code: 'INV001', customer: 'ALPHA STORE', itemCount: 4);
      final tx2 = buildTx(code: 'INV002', customer: 'BETA MART', itemCount: 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WebTransactionDetailModal(transactions: [tx1, tx2]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ALPHA STORE'), findsWidgets);

      // Toggle to Full Table
      await tester.tap(find.text('Full Table'));
      await tester.pumpAndSettle();
      expect(find.text('Sample Item 1'), findsOneWidget);

      // Switch to second stop (empty items)
      await tester.tap(find.text('#2 INV002'));
      await tester.pumpAndSettle();
      expect(find.text('No line items recorded for this invoice.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
