import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';

class TransactionStopCluster {
  final double lat;
  final double lon;
  final int startIndex;
  final List<RouteTransaction> transactions;

  const TransactionStopCluster({
    required this.lat,
    required this.lon,
    required this.startIndex,
    required this.transactions,
  });
}

/// Groups captured transactions within [thresholdMeters] so multiple invoices
/// captured at the same store share a single interactive map marker.
List<TransactionStopCluster> clusterRouteTransactions(
  List<RouteTransaction> transactions, {
  double thresholdMeters = 15.0,
}) {
  final valid = transactions.where((tx) => tx.hasValidLocation).toList()
    ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  if (valid.isEmpty) return const [];

  const distance = Distance();
  final clusters = <TransactionStopCluster>[];

  for (var i = 0; i < valid.length; i++) {
    final tx = valid[i];
    final point = LatLng(tx.lat, tx.lon);
    var matchedIdx = -1;

    for (var c = 0; c < clusters.length; c++) {
      final clusterPoint = LatLng(clusters[c].lat, clusters[c].lon);
      if (distance.as(LengthUnit.Meter, point, clusterPoint) <= thresholdMeters) {
        matchedIdx = c;
        break;
      }
    }

    if (matchedIdx == -1) {
      clusters.add(
        TransactionStopCluster(
          lat: tx.lat,
          lon: tx.lon,
          startIndex: i + 1,
          transactions: [tx],
        ),
      );
    } else {
      final existing = clusters[matchedIdx];
      clusters[matchedIdx] = TransactionStopCluster(
        lat: existing.lat,
        lon: existing.lon,
        startIndex: existing.startIndex,
        transactions: [...existing.transactions, tx],
      );
    }
  }

  return clusters;
}

/// Distinct emerald-teal receipt marker used on Web Maps for captured transactions.
class TransactionMapMarker extends StatelessWidget {
  final TransactionStopCluster cluster;
  final Color routeColor;
  final bool isSelected;
  final VoidCallback onTap;

  const TransactionMapMarker({
    super.key,
    required this.cluster,
    required this.routeColor,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final count = cluster.transactions.length;
    final badgeText = count > 1 ? '×$count' : '#${cluster.startIndex}';
    final distinctCustomers = cluster.transactions
        .map((t) => t.customerName.trim())
        .where((n) => n.isNotEmpty)
        .toSet();
    final multiTooltip = distinctCustomers.isEmpty
        ? '$count Transactions'
        : distinctCustomers.length == 1
            ? '$count Transactions (${distinctCustomers.first})'
            : '$count Transactions (${distinctCustomers.length} customers: ${distinctCustomers.take(2).join(', ')}${distinctCustomers.length > 2 ? '…' : ''})';

    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: count > 1
            ? multiTooltip
            : '${cluster.transactions.first.customerName} • ${cluster.transactions.first.invoiceCode}',
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: isSelected ? 34 : 28,
              height: isSelected ? 34 : 28,
              decoration: BoxDecoration(
                color: const Color(0xFF0F766E),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 2.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: routeColor.withValues(alpha: 0.65),
                    blurRadius: isSelected ? 10 : 4,
                    spreadRadius: isSelected ? 2 : 0.8,
                  ),
                ],
              ),
              child: Icon(
                Icons.receipt_long,
                size: isSelected ? 18 : 15,
                color: Colors.white,
              ),
            ),
            Positioned(
              right: -6,
              top: -5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: count > 1 ? Colors.amber.shade800 : routeColor,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 1.2),
                ),
                child: Text(
                  badgeText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

