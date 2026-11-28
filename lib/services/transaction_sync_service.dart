import 'dart:async';
import 'dart:convert';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/connectivity_check_service.dart';
import 'package:compact_sales_monitoring/services/daily_invoice_pdf_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/si_booklet_storage_service.dart';
import 'package:compact_sales_monitoring/services/si_series_engine.dart';
import 'package:compact_sales_monitoring/services/transaction_storage_service.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/sfa_invoice_parser.dart';

class CapturedTransactionResult {
  final RouteTransaction transaction;
  final List<InvoicePageData> pages;
  final bool isDuplicate;
  final DailyPdfSaveResult? pdfSaveResult;
  final bool uploadedNow;
  final bool hasIntegrityWarning;
  final bool siExhausted;
  final bool hasNoSiBooklets;
  final bool blockedNoActiveCall;

  const CapturedTransactionResult({
    required this.transaction,
    required this.pages,
    required this.isDuplicate,
    this.pdfSaveResult,
    this.uploadedNow = false,
    this.hasIntegrityWarning = false,
    this.siExhausted = false,
    this.hasNoSiBooklets = false,
    this.blockedNoActiveCall = false,
  });
}

class ParsedPreviewInvoiceResult {
  final RouteTransaction transaction;
  final List<InvoicePageData> pages;
  final RouteTransaction? existingCapturedToday;
  final bool isOldInvoiceDate;
  final bool hasActiveCallToday;
  final bool hasIntegrityWarning;

  const ParsedPreviewInvoiceResult({
    required this.transaction,
    required this.pages,
    this.existingCapturedToday,
    required this.isOldInvoiceDate,
    required this.hasActiveCallToday,
    this.hasIntegrityWarning = false,
  });
}

/// Coordinates GPS capture, daily deduplication, live SI booklet allocation,
/// combined PDF generation, and Firestore upload/retry for captured SFA transactions.
class TransactionSyncService {
  static bool _isFlushing = false;

  final TransactionStorageService _storage;
  final FirestoreService _firestore;
  final SiBookletStorageService _bookletStorage;

  TransactionSyncService({
    TransactionStorageService? storage,
    FirestoreService? firestore,
    SiBookletStorageService? bookletStorage,
  }) : _storage = storage ?? TransactionStorageService(),
       _firestore = firestore ?? FirestoreService(),
       _bookletStorage = bookletStorage ?? SiBookletStorageService();

  /// Checks `SharedPreferences` (cross-isolate safe via `reload()`) to determine
  /// whether the salesman currently has an active call (First Call started, online
  /// or offline) for [routeDate] (`YYYY-MM-DD`).
  static Future<bool> hasActiveCallForDate(String routeDate) async {
    if (kIsWeb) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final activeRouteId = prefs.getString('active_route_id');
      final routeStartStr = prefs.getString('route_start_time');
      if (activeRouteId != null &&
          activeRouteId.trim().isNotEmpty &&
          routeStartStr != null &&
          routeStartStr.trim().isNotEmpty) {
        final parsedStart = DateTime.tryParse(routeStartStr);
        if (parsedStart != null &&
            DateFormat('yyyy-MM-dd').format(parsedStart) == routeDate) {
          return true;
        }
      }

      final pendingFirstCallRaw = prefs.getString('pending_first_call_v2') ?? '';
      if (pendingFirstCallRaw.isNotEmpty) {
        try {
          final map = jsonDecode(pendingFirstCallRaw) as Map<String, dynamic>;
          final pendingDate = (map['date'] as String?)?.trim();
          if (pendingDate == routeDate) {
            return true;
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[TransactionSyncService] hasActiveCallForDate error: $e');
    }
    return false;
  }

  /// Returns `true` if the parsed invoice date matches [referenceNow]'s local calendar day.
  static bool isInvoiceDateToday(
    String rawInvoiceDate, {
    DateTime? referenceNow,
  }) {
    final now = referenceNow ?? DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final parsed = SfaInvoiceParser.tryParseInvoiceDateTime(rawInvoiceDate);
    if (parsed == null) return true;
    return DateFormat('yyyy-MM-dd').format(parsed) == todayStr;
  }

  /// Parses raw SFA text strictly for **Preview Only** (manual import flow):
  /// does NOT save locally, does NOT allocate SI numbers, does NOT rebuild PDF,
  /// and does NOT upload to Firestore.
  Future<ParsedPreviewInvoiceResult> parseInvoiceForPreview({
    required String rawText,
  }) async {
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final parsed = SfaInvoiceParser.parse(
      rawText: rawText,
      capturedAt: now,
      uploadStatus: TransactionUploadStatus.pending,
    );

    final isToday = isInvoiceDateToday(
      parsed.transaction.invoiceDate,
      referenceNow: now,
    );

    // Check if this invoice code is already captured today (or on its parsed routeDate).
    final existingToday = await _storage.findExistingByInvoiceCode(
          routeDate: todayStr,
          invoiceCode: parsed.transaction.invoiceCode,
        ) ??
        (parsed.transaction.routeDate != todayStr
            ? await _storage.findExistingByInvoiceCode(
                routeDate: parsed.transaction.routeDate,
                invoiceCode: parsed.transaction.invoiceCode,
              )
            : null);

    final hasActiveCall = await hasActiveCallForDate(todayStr);

    return ParsedPreviewInvoiceResult(
      transaction: parsed.transaction,
      pages: parsed.pages,
      existingCapturedToday: existingToday,
      isOldInvoiceDate: !isToday,
      hasActiveCallToday: hasActiveCall,
      hasIntegrityWarning: parsed.hasIntegrityWarning,
    );
  }

  Future<String?> _resolveCurrentUid() async {
    var uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && uid.isNotEmpty) return uid;
    try {
      final restored = await FirebaseAuth.instance
          .authStateChanges()
          .first
          .timeout(const Duration(seconds: 3));
      uid = restored?.uid;
    } catch (_) {}
    return uid;
  }

  /// Pulls the salesman's SI booklets from Firestore (1 read) and reconciles
  /// with the local cache safely under the shared exclusive lock.
  Future<SalesmanSiBookletState?> refreshBookletsFromFirestore(
    String salesmanId, {
    String? companyId,
  }) async {
    if (kIsWeb || salesmanId.trim().isEmpty) return null;
    try {
      final isOnline = await ConnectivityCheckService.hasInternetConnection();
      if (!isOnline) {
        return _bookletStorage.getBookletState(salesmanId);
      }

      final remote = await _firestore
          .getSalesmanSiBooklets(salesmanId, fallbackCompanyId: companyId)
          .timeout(const Duration(seconds: 8));

      return _bookletStorage.withSharedLock(() async {
        final local = await _bookletStorage.readUnlocked(salesmanId);
        final reconciled = SiSeriesEngine.reconcileBookletStates(
          local: local,
          remote: remote,
        );
        await _bookletStorage.writeUnlocked(reconciled);
        return reconciled;
      });
    } catch (e) {
      debugPrint('[TransactionSyncService] Booklet refresh failed: $e');
      return _bookletStorage.getBookletState(salesmanId);
    }
  }

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

  /// Processes raw parsed SFA text: verifies an active call exists (when
  /// [requireActiveCall] is true), captures GPS, deduplicates by `invoiceCode`
  /// for the day, allocates SI series numbers, rebuilds today's combined PDF,
  /// and uploads to Firestore if possible.
  Future<CapturedTransactionResult> processRawInvoiceText({
    required String rawText,
    String? fallbackSalesmanCode,
    bool requireActiveCall = true,
    bool forceTodayRouteDate = false,
  }) async {
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
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

    final effectiveTx = forceTodayRouteDate &&
            parsed.transaction.routeDate != todayStr
        ? parsed.transaction.copyWith(
            routeDate: todayStr,
            transactionId: '${todayStr}_${parsed.transaction.invoiceCode}',
          )
        : parsed.transaction;

    // Check if already captured before enforcing active-call block so reprints
    // of already-saved invoices still display cleanly with their assigned SI No.
    final existingAlready = await _storage.findExistingByInvoiceCode(
      routeDate: effectiveTx.routeDate,
      invoiceCode: effectiveTx.invoiceCode,
    );

    if (requireActiveCall && existingAlready == null) {
      final hasActiveCall = await hasActiveCallForDate(todayStr);
      if (!hasActiveCall) {
        return CapturedTransactionResult(
          transaction: effectiveTx,
          pages: parsed.pages,
          isDuplicate: false,
          hasIntegrityWarning: parsed.hasIntegrityWarning,
          blockedNoActiveCall: true,
        );
      }
    }

    final currentUid = await _resolveCurrentUid();
    final saveResult = await _storage.saveOrFindExistingWithSiAllocation(
      candidate: effectiveTx,
      salesmanId: currentUid,
      bookletStorage: _bookletStorage,
      allocateSi: true,
    );

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
        siExhausted: saveResult.transaction.hasMissingSiPages &&
            saveResult.transaction.hasAnySiAssigned,
        hasNoSiBooklets: !saveResult.transaction.hasAnySiAssigned,
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
      siExhausted: saveResult.siExhausted,
      hasNoSiBooklets: saveResult.hasNoSiBooklets,
    );
  }

  /// Salesman live void: voids [pageNo] on [transaction], shifts remaining pages
  /// forward by 1 from the local booklet pool, rebuilds today's Daily PDF so it
  /// reflects the new SI numbers, and flushes updates safely in-place.
  Future<SalesmanVoidResult> voidPageAsSalesman({
    required RouteTransaction transaction,
    required int pageNo,
    String? reason,
    String? salesmanName,
    String? fallbackSalesmanCode,
  }) async {
    final currentUid = await _resolveCurrentUid();
    if (currentUid == null || currentUid.isEmpty) {
      throw StateError('Please sign in before voiding a Sales Invoice page.');
    }

    final voidResult = await _storage.voidPageLocally(
      salesmanId: currentUid,
      transaction: transaction,
      pageNo: pageNo,
      bookletStorage: _bookletStorage,
      reason: reason,
      voidedBy: currentUid,
      voidedByName: salesmanName,
    );

    // Rebuild daily PDF so saved PDF immediately matches updated SI numbers.
    try {
      final dayTransactions = await _storage.getTransactionsForDate(
        transaction.routeDate,
      );
      final effectiveCode = transaction.salesRepCode.isNotEmpty
          ? transaction.salesRepCode
          : (fallbackSalesmanCode ?? 'REP');
      if (dayTransactions.isNotEmpty) {
        await DailyInvoicePdfService.rebuildAndSaveDailyPdf(
          routeDate: transaction.routeDate,
          salesmanCode: effectiveCode,
          transactions: dayTransactions,
        );
      }
    } catch (e) {
      debugPrint('[TransactionSyncService] PDF rebuild after void failed: $e');
    }

    // Best-effort immediate flush (in-place update + booklet pointer sync).
    try {
      await flushPendingTransactions();
    } catch (e) {
      debugPrint('[TransactionSyncService] Flush after void deferred: $e');
    }

    return voidResult;
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
      final dirtyUpdates = await _storage.getTransactionsNeedingRemoteUpdate();
      final currentUid = await _resolveCurrentUid();

      SalesmanSiBookletState? localBooklets;
      if (currentUid != null && currentUid.isNotEmpty) {
        localBooklets = await _bookletStorage.getBookletState(currentUid);
      }

      final hasBookletPending = localBooklets?.hasPendingSync == true;
      if (pending.isEmpty && dirtyUpdates.isEmpty && !hasBookletPending) {
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

      Future<String?> resolveRouteIdForDate(
        String routeDate, {
        String? preferredRouteId,
      }) async {
        if (preferredRouteId != null && preferredRouteId.isNotEmpty) {
          return preferredRouteId;
        }
        if (knownRouteId != null && knownRouteDate == routeDate) {
          return knownRouteId;
        }
        if (activeRouteId != null && activeRouteDate == routeDate) {
          return activeRouteId;
        }
        if (currentUid != null) {
          try {
            final routes = await _firestore
                .getRoutesBySalesman(currentUid, routeDate)
                .timeout(const Duration(seconds: 10));
            if (routes.isNotEmpty) {
              return routes.first.routeId;
            }
          } catch (e) {
            debugPrint(
              '[TransactionSyncService] Route lookup failed for $routeDate: $e',
            );
          }
        }
        return null;
      }

      // 1. Flush brand-new pending transactions.
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

        final targetRouteId = await resolveRouteIdForDate(routeDate);
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

      // 2. Flush in-place updates for already-uploaded transactions (e.g. offline voids)
      //    using upsertRouteTransaction so arrayUnion never creates duplicates!
      for (final dirtyTx in dirtyUpdates) {
        if (pendingFirstCallDate == dirtyTx.routeDate) continue;
        final targetRouteId = await resolveRouteIdForDate(
          dirtyTx.routeDate,
          preferredRouteId: dirtyTx.uploadedRouteId,
        );
        if (targetRouteId == null || targetRouteId.isEmpty) continue;

        try {
          await _firestore.upsertRouteTransaction(targetRouteId, dirtyTx);
          await _storage.clearNeedsRemoteUpdate(
            routeDate: dirtyTx.routeDate,
            transactionId: dirtyTx.transactionId,
            syncedSiRevision: dirtyTx.siRevision,
            routeId: targetRouteId,
          );
          uploadedIds.add(dirtyTx.transactionId);
        } catch (e) {
          debugPrint(
            '[TransactionSyncService] In-place SI update failed for ${dirtyTx.transactionId}: $e',
          );
        }
      }

      // 3. Sync salesman booklet pointer & voids ONCE per flush cycle (Spark quota optimized).
      if (currentUid != null && currentUid.isNotEmpty) {
        try {
          final latestLocal = await _bookletStorage.getBookletState(currentUid);
          if (latestLocal.hasPendingSync && latestLocal.hasBooklets) {
            final reconciled = await _firestore.syncSalesmanBookletProgress(
              latestLocal,
            );
            await _bookletStorage.saveBookletState(reconciled);
          }
        } catch (e) {
          debugPrint('[TransactionSyncService] Booklet pointer sync failed: $e');
        }
      }
    } finally {
      _isFlushing = false;
    }

    return uploadedIds;
  }
}

