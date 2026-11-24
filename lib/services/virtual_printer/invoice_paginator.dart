import 'package:compact_sales_monitoring/models/transaction_model.dart';

/// Paginates invoice line items into 9-line pages and calculates per-page VAT.
class InvoicePaginator {
  static const int maxLinesPerPage = 9;

  /// Rounds a currency value to 2 decimal places.
  static double round2(double value) => (value * 100.0).roundToDouble() / 100.0;

  /// Splits [rawItems] into pages of up to 9 lines, assigning `pageNo` and `sequence`,
  /// and computes `TOTAL AMOUNT DUE`, `VATABLE SALES`, and `VAT` per page.
  static List<InvoicePageData> paginate(List<InvoiceLineItem> rawItems) {
    if (rawItems.isEmpty) {
      return const [
        InvoicePageData(
          pageNo: 1,
          totalPages: 1,
          items: [],
          totalAmountDue: 0.0,
          vatableSales: 0.0,
          vat: 0.0,
        ),
      ];
    }

    final totalPages = ((rawItems.length - 1) ~/ maxLinesPerPage) + 1;
    final pages = <InvoicePageData>[];

    for (var pageIndex = 0; pageIndex < totalPages; pageIndex++) {
      final start = pageIndex * maxLinesPerPage;
      final end = (start + maxLinesPerPage).clamp(0, rawItems.length);
      final slice = rawItems.sublist(start, end);

      final pageItems = <InvoiceLineItem>[];
      var pageSum = 0.0;

      for (var i = 0; i < slice.length; i++) {
        final item = slice[i].copyWith(
          pageNo: pageIndex + 1,
          sequence: i + 1,
        );
        pageItems.add(item);
        pageSum += item.totalAmount;
      }

      final totalAmountDue = round2(pageSum);
      final vatableSales = round2(totalAmountDue / 1.12);
      final vat = round2(totalAmountDue - vatableSales);

      pages.add(
        InvoicePageData(
          pageNo: pageIndex + 1,
          totalPages: totalPages,
          items: List.unmodifiable(pageItems),
          totalAmountDue: totalAmountDue,
          vatableSales: vatableSales,
          vat: vat,
        ),
      );
    }

    return List.unmodifiable(pages);
  }

  /// Re-indexes [rawItems] with sequential 9-line `pageNo` and `sequence` values.
  static List<InvoiceLineItem> assignSequences(List<InvoiceLineItem> rawItems) {
    return paginate(rawItems).expand((page) => page.items).toList();
  }
}

