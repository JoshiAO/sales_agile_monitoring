import 'dart:async';
import 'dart:convert';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/connectivity_check_service.dart';
import 'package:compact_sales_monitoring/services/daily_invoice_pdf_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/transaction_storage_service.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/sfa_invoice_parser.dart';

class CapturedTransactionResult {
  final RouteTransaction transaction;
  final List<InvoicePageData> pages;
  final bool isDuplicate;
  final DailyPdfSaveResult? pdfSaveResult;
  final bool uploadedNow;
  final bool hasIntegrityWarning;

  const CapturedTransactionResult({
    required this.transaction,
    required this.pages,
    required this.isDuplicate,
    this.pdfSaveResult,
    this.uploadedNow = false,
    this.hasIntegrityWarning = false,
  });
}

/// Coordinates GPS capture, daily deduplication, combined PDF generation,
/// and Firestore upload/retry for captured SFA transactions.
class TransactionSyncService {
  static bool _isFlushing = false;

  final TransactionStorageService _storage;
  final FirestoreService _firestore;

  TransactionSyncService({
    TransactionStorageService? storage,
    FirestoreService? firestore,
  }) : _storage = storage ?? TransactionStorageService(),
       _firestore = firestore ?? FirestoreService();

  /// Captures the best available GPS fix + battery/connectivity snapshot.
  static Future<({
    double lat,
    double lon,
    double? accuracyMeters,
    int? batteryLevel,
    bool? isMobileDataOn,
    bool? isWifiOn,
  })> captureDeviceSnapshot() async {
    double lat = 0.0;
    double lon = 0.0;
    double? accuracy;

    if (!kIsWeb) {
      geo.Position? pos;
      try {
        pos = await geo.Geolocator.getCurrentPosition(
          desiredAccuracy: geo.LocationAccuracy.high,
          timeLimit: const Duration(seconds: 8),
        );
      } catch (_) {
        try {
          pos = await geo.Geolocator.getLastKnownPosition();
        } catch (_) {}
      }

      if (pos != null) {
        lat = pos.latitude;
        lon = pos.longitude;
        accuracy = pos.accuracy;
      } else {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          final fallbackLat = prefs.getDouble('last_checkpoint_lat') ??
              prefs.getDouble('first_point_lat');
          final fallbackLon = prefs.getDouble('last_checkpoint_lon') ??
              prefs.getDouble('first_point_lon');
          if (fallbackLat != null && fallbackLon != null) {
            lat = fallbackLat;
            lon = fallbackLon;
          }
        } catch (_) {}
      }
    }

    int? batteryLevel;
    bool? isMobileDataOn;
    bool? isWifiOn;
    try {
      batteryLevel = await Battery().batteryLevel;
    } catch (_) {}
    try {
      final conn = await Connectivity().checkConnectivity();
      isMobileDataOn = conn.contains(ConnectivityResult.mobile);
      isWifiOn = conn.contains(ConnectivityResult.wifi);
    } catch (_) {}

    return (
      lat: lat,
      lon: lon,
      accuracyMeters: accuracy,
      batteryLevel: batteryLevel,
      isMobileDataOn: isMobileDataOn,
      isWifiOn: isWifiOn,
    );
  }

  /// Processes raw parsed SFA text: captures GPS, deduplicates by `invoiceCode`
  /// for the day, rebuilds today's combined PDF, and uploads to Firestore if possible.
  Future<CapturedTransactionResult> processRawInvoiceText({
    required String rawText,
    String? fallbackSalesmanCode,
  }) async {
    final now = DateTime.now();
    final snapshot = await captureDeviceSnapshot();

    final parsed = SfaInvoiceParser.parse(
      rawText: rawText,
      capturedAt: now,
      lat: snapshot.lat,
      lon: snapshot.lon,
      accuracyMeters: snapshot.accuracyMeters,
      batteryLevel: snapshot.batteryLevel,
      isMobileDataOn: snapshot.isMobileDataOn,
      isWifiOn: snapshot.isWifiOn,
      uploadStatus: TransactionUploadStatus.pending,
    );

    final saveResult = await _storage.saveOrFindExisting(parsed.transaction);

    final dayTransactions = await _storage.getTransactionsForDate(
      saveResult.transaction.routeDate,
    );

    final effectiveCode = saveResult.transaction.salesRepCode.isNotEmpty
        ? saveResult.transaction.salesRepCode
        : (fallbackSalesmanCode ?? 'REP');

    if (saveResult.isDuplicate) {
      // Ensure today's progressive PDF still exists on disk even on reprint.
      DailyPdfSaveResult? pdfResult;
      try {
        final existingPath = await DailyInvoicePdfService.findExistingPrivatePdfPath(
          routeDate: saveResult.transaction.routeDate,
          salesmanCode: effectiveCode,
        );
        if (existingPath == null && dayTransactions.isNotEmpty) {
          pdfResult = await DailyInvoicePdfService.rebuildAndSaveDailyPdf(
            routeDate: saveResult.transaction.routeDate,
            salesmanCode: effectiveCode,
            transactions: dayTransactions,
          );
        }
      } catch (e) {
        debugPrint('[TransactionSyncService] Duplicate PDF check failed: $e');
      }

      return CapturedTransactionResult(
        transaction: saveResult.transaction,
        pages: parsed.pages,
        isDuplicate: true,
        pdfSaveResult: pdfResult,
        hasIntegrityWarning: parsed.hasIntegrityWarning,
      );
    }

    DailyPdfSaveResult? pdfResult;
    try {
      pdfResult = await DailyInvoicePdfService.rebuildAndSaveDailyPdf(
        routeDate: saveResult.transaction.routeDate,
        salesmanCode: effectiveCode,
        transactions: dayTransactions,
      );
    } catch (e) {
      debugPrint('[TransactionSyncService] PDF generation failed (non-fatal): $e');
    }

    final uploadedIds = await flushPendingTransactions();
    final uploadedNow = uploadedIds.contains(saveResult.transaction.transactionId);

    final refreshedList = await _storage.getTransactionsForDate(
      saveResult.transaction.routeDate,
    );
    final finalTx = refreshedList.firstWhere(
      (t) => t.transactionId == saveResult.transaction.transactionId,
      orElse: () => saveResult.transaction,
    );

    return CapturedTransactionResult(
      transaction: finalTx,
      pages: parsed.pages,
      isDuplicate: false,
      pdfSaveResult: pdfResult,
      uploadedNow: uploadedNow,
      hasIntegrityWarning: parsed.hasIntegrityWarning,
    );
  }

  /// Flushes all locally pending transactions whose route document already exists.
  /// Returns the set of `transactionId`s uploaded during this flush.
  Future<Set<String>> flushPendingTransactions({
    String? knownRouteId,
    String? knownRouteDate,
  }) async {
    if (kIsWeb || _isFlushing) return const <String>{};
    _isFlushing = true;
    final uploadedIds = <String>{};

    try {
      final pending = await _storage.getAllPendingTransactions();
      if (pending.isEmpty) {
        await _storage.refreshPendingCount();
        return uploadedIds;
      }

      final isOnline = await ConnectivityCheckService.hasInternetConnection();
      if (!isOnline) return uploadedIds;

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final pendingFirstCallRaw = prefs.getString('pending_first_call_v2') ?? '';
      String? pendingFirstCallDate;
      if (pendingFirstCallRaw.isNotEmpty) {
        try {
          final map = jsonDecode(pendingFirstCallRaw) as Map<String, dynamic>;
          pendingFirstCallDate = map['date'] as String?;
        } catch (_) {}
      }

      final activeRouteId = prefs.getString('active_route_id');
      String? activeRouteDate;
      final routeStartStr = prefs.getString('route_start_time');
      if (routeStartStr != null) {
        try {
          activeRouteDate = DateFormat('yyyy-MM-dd').format(
            DateTime.parse(routeStartStr),
          );
        } catch (_) {}
      }

      var currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) {
        try {
          final restoredUser = await FirebaseAuth.instance
              .authStateChanges()
              .first
              .timeout(const Duration(seconds: 3));
          currentUid = restoredUser?.uid;
        } catch (_) {}
      }
      final byDate = <String, List<RouteTransaction>>{};
      for (final tx in pending) {
        byDate.putIfAbsent(tx.routeDate, () => []).add(tx);
      }

      for (final entry in byDate.entries) {
        final routeDate = entry.key;
        final batch = entry.value;

        // If First Call for this day is still queued offline, keep transactions pending.
        if (pendingFirstCallDate == routeDate) {
          continue;
        }

        String? targetRouteId;
        if (knownRouteId != null && knownRouteDate == routeDate) {
          targetRouteId = knownRouteId;
        } else if (activeRouteId != null && activeRouteDate == routeDate) {
          targetRouteId = activeRouteId;
        } else if (currentUid != null) {
          try {
            final routes = await _firestore
                .getRoutesBySalesman(currentUid, routeDate)
                .timeout(const Duration(seconds: 10));
            if (routes.isNotEmpty) {
              targetRouteId = routes.first.routeId;
            }
          } catch (e) {
            debugPrint('[TransactionSyncService] Route lookup failed for $routeDate: $e');
          }
        }

        if (targetRouteId == null || targetRouteId.isEmpty) {
          // Pre-First-Call state: leave pending until First Call creates the route doc.
          continue;
        }

        try {
          await _firestore.appendRouteTransactionsBatch(
            targetRouteId,
            batch,
            expectedRouteDate: routeDate,
          );
          final ids = batch.map((tx) => tx.transactionId).toSet();
          await _storage.markAsUploaded(
            routeDate: routeDate,
            transactionIds: ids,
            routeId: targetRouteId,
          );
          uploadedIds.addAll(ids);
        } catch (e) {
          debugPrint(
            '[TransactionSyncService] Upload failed for route $targetRouteId ($routeDate): $e',
          );
        }
      }
    } finally {
      _isFlushing = false;
    }

    return uploadedIds;
  }
}

