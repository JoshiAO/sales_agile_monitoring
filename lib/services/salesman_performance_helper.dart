import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';

class EffectiveActualMetrics {
  final int productiveCalls;
  final double stt;
  final bool hasData;
  final bool isFromTransactions;

  const EffectiveActualMetrics({
    required this.productiveCalls,
    required this.stt,
    required this.hasData,
    required this.isFromTransactions,
  });
}

/// Resolves Actual Productive Calls and Actual STT based on salesman
/// classification:
/// - **Van Ex-Truck**: derived from captured route transactions
///   - Actual Productive Calls = unique customers (`customerCode`, fallback to
///     normalized `customerName`)
///   - Actual STT = total sum of transaction amounts
/// - **Booking**: read from Agile submissions (`productiveCalls`, `sttActual`)
class SalesmanPerformanceHelper {
  static String _customerUniquenessKey(RouteTransaction tx) {
    final code = tx.customerCode.trim().toUpperCase();
    if (code.isNotEmpty) return 'CODE:$code';
    final name = tx.customerName
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (name.isNotEmpty) return 'NAME:$name';
    return 'TX:${tx.transactionId}';
  }

  /// Computes effective actuals for a single salesman on a single date.
  static EffectiveActualMetrics resolveForDate({
    required AppUser salesman,
    required AgileSubmission? agileSubmission,
    required Iterable<SalesRoute> salesmanRoutes,
  }) {
    if (salesman.isVanExTruck) {
      final uniqueCustomers = <String>{};
      var totalStt = 0.0;
      var txCount = 0;

      for (final route in salesmanRoutes) {
        for (final tx in route.transactions) {
          txCount++;
          uniqueCustomers.add(_customerUniquenessKey(tx));
          totalStt += tx.totalAmount;
        }
      }

      return EffectiveActualMetrics(
        productiveCalls: uniqueCustomers.length,
        stt: (totalStt * 100).roundToDouble() / 100.0,
        hasData: txCount > 0,
        isFromTransactions: true,
      );
    }

    // Booking salesman: read from Agile submission
    if (agileSubmission == null) {
      return const EffectiveActualMetrics(
        productiveCalls: 0,
        stt: 0.0,
        hasData: false,
        isFromTransactions: false,
      );
    }

    return EffectiveActualMetrics(
      productiveCalls: agileSubmission.productiveCalls,
      stt: agileSubmission.sttActual,
      hasData: true,
      isFromTransactions: false,
    );
  }

  /// Builds an effective `AgileSubmission` map so existing Agile dashboards and
  /// Home previews seamlessly reflect Van Ex-Truck transaction-derived actuals
  /// alongside Booking Agile submissions without duplicating rendering logic.
  static Map<String, AgileSubmission> buildEffectiveSubmissionsBySalesman({
    required List<AppUser> salesmen,
    required String date,
    required Map<String, AgileSubmission> rawAgileSubmissions,
    required List<SalesRoute> routes,
  }) {
    final routesBySalesman = <String, List<SalesRoute>>{};
    for (final route in routes) {
      routesBySalesman
          .putIfAbsent(route.salesmanId, () => <SalesRoute>[])
          .add(route);
    }

    final result = <String, AgileSubmission>{};
    for (final salesman in salesmen) {
      final raw = rawAgileSubmissions[salesman.uid];
      if (salesman.isBooking) {
        if (raw != null) {
          result[salesman.uid] = raw;
        }
        continue;
      }

      final salesmanRoutes = routesBySalesman[salesman.uid] ?? const [];
      final metrics = resolveForDate(
        salesman: salesman,
        agileSubmission: raw,
        salesmanRoutes: salesmanRoutes,
      );
      if (metrics.hasData) {
        final hasLastCall = salesmanRoutes.any((r) => r.hasLastCall);
        final totalTx = salesmanRoutes.fold<int>(
          0,
          (sum, r) => sum + r.transactions.length,
        );
        result[salesman.uid] = AgileSubmission(
          salesmanId: salesman.uid,
          supervisorId: salesman.supervisorId ?? raw?.supervisorId ?? '',
          date: date,
          totalCalls: totalTx,
          productiveCalls: metrics.productiveCalls,
          sttActual: metrics.stt,
          lastCallCompleted: raw?.lastCallCompleted ?? hasLastCall,
          submitted: true,
          submittedAt: raw?.submittedAt,
        );
      }
    }
    return result;
  }
}
