import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/si_booklet_storage_service.dart';
import 'package:compact_sales_monitoring/services/si_series_engine.dart';

class TransactionSaveResult {
  final RouteTransaction transaction;
  final bool isDuplicate;
  final bool siExhausted;
  final bool hasNoSiBooklets;

  const TransactionSaveResult({
    required this.transaction,
    required this.isDuplicate,
    this.siExhausted = false,
    this.hasNoSiBooklets = false,
  });
}

/// Persists captured transactions locally in `appDocs/transactions/YYYY-MM-DD.json`
/// so offline and pre-First-Call invoices are never lost.
class TransactionStorageService {
  static const String pendingCountPrefsKey = 'pending_transactions_count_v1';

  Future<Directory?> _transactionsDir() async {
    if (kIsWeb) return null;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/transactions');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cross-isolate exclusive file lock serializing read-modify-write cycles
  /// across Main, Overlay, and Background isolates.
  Future<T> _withFileLock<T>(Future<T> Function() action) async {
    if (kIsWeb) return action();
    final dir = await _transactionsDir();
    if (dir == null) return action();
    final lockFile = File('${dir.path}/.tx.lock');
    final raf = await lockFile.open(mode: FileMode.write);
    try {
      await raf.lock(FileLock.blockingExclusive);
      return await action();
    } finally {
      try {
        await raf.unlock();
      } catch (_) {}
      await raf.close();
    }
  }

  Future<File?> _dateFile(String routeDate) async {
    final dir = await _transactionsDir();
    if (dir == null) return null;
    final safeDate = routeDate.replaceAll(RegExp(r'[^0-9\-]'), '');
    return File('${dir.path}/$safeDate.json');
  }

  Future<List<RouteTransaction>> getTransactionsForDate(String routeDate) async {
    if (kIsWeb) return const [];
    return _readTransactionsForDateUnlocked(routeDate);
  }

  Future<List<RouteTransaction>> _readTransactionsForDateUnlocked(
    String routeDate,
  ) async {
    final file = await _dateFile(routeDate);
    if (file == null || !await file.exists()) return const [];

    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];

      final list = decoded
          .whereType<Map<String, dynamic>>()
          .map(
            (m) => RouteTransaction.fromMap(
              m,
              defaultUploadStatus: TransactionUploadStatus.pending,
            ),
          )
          .toList()
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      return list;
    } catch (e) {
      debugPrint('[TransactionStorageService] Failed reading $routeDate: $e');
      return const [];
    }
  }

  Future<void> _writeTransactionsForDateUnlocked(
    String routeDate,
    List<RouteTransaction> items,
  ) async {
    final file = await _dateFile(routeDate);
    if (file == null) return;

    final encoded = jsonEncode(items.map((tx) => tx.toLocalJson()).toList());
    final uniqueId = DateTime.now().microsecondsSinceEpoch;
    final tmpFile = File('${file.path}.$uniqueId.tmp');
    await tmpFile.writeAsString(encoded, flush: true);
    await tmpFile.rename(file.path);
  }

  /// Saves [candidate] if its `invoiceCode` has not been captured yet for `candidate.routeDate`.
  /// Returns the existing record with `isDuplicate: true` on reprints/re-exports.
  Future<TransactionSaveResult> saveOrFindExisting(
    RouteTransaction candidate,
  ) async {
    return _withFileLock(() async {
      final existingList = await _readTransactionsForDateUnlocked(
        candidate.routeDate,
      );
      final normalizedCode = candidate.invoiceCode.trim().toUpperCase();

      for (final existing in existingList) {
        if (existing.invoiceCode.trim().toUpperCase() == normalizedCode) {
          return TransactionSaveResult(
            transaction: existing,
            isDuplicate: true,
          );
        }
      }

      final updated = [...existingList, candidate]
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      await _writeTransactionsForDateUnlocked(candidate.routeDate, updated);
      await _refreshPendingCountUnlocked();

      return TransactionSaveResult(
        transaction: candidate,
        isDuplicate: false,
      );
    });
  }

  /// Looks up an existing locally saved transaction by [invoiceCode] for [routeDate].
  Future<RouteTransaction?> findExistingByInvoiceCode({
    required String routeDate,
    required String invoiceCode,
  }) async {
    if (kIsWeb) return null;
    final list = await getTransactionsForDate(routeDate);
    final normalizedCode = invoiceCode.trim().toUpperCase();
    for (final existing in list) {
      if (existing.invoiceCode.trim().toUpperCase() == normalizedCode) {
        return existing;
      }
    }
    return null;
  }

  /// Atomically deduplicates [candidate] and allocates sequential SI numbers
  /// from [bookletStorage] under the same exclusive OS file lock so Overlay,
  /// Main, and Background isolates never race or consume duplicate SI numbers.
  Future<TransactionSaveResult> saveOrFindExistingWithSiAllocation({
    required RouteTransaction candidate,
    required String? salesmanId,
    required SiBookletStorageService bookletStorage,
    bool allocateSi = true,
  }) async {
    return _withFileLock(() async {
      final existingList = await _readTransactionsForDateUnlocked(
        candidate.routeDate,
      );
      final normalizedCode = candidate.invoiceCode.trim().toUpperCase();

      for (final existing in existingList) {
        if (existing.invoiceCode.trim().toUpperCase() == normalizedCode) {
          return TransactionSaveResult(
            transaction: existing,
            isDuplicate: true,
          );
        }
      }

      var txToSave = candidate;
      var siExhausted = false;
      var hasNoSiBooklets = false;

      if (allocateSi && salesmanId != null && salesmanId.trim().isNotEmpty) {
        final bookletState = await bookletStorage.readUnlocked(salesmanId);
        if (!bookletState.hasBooklets) {
          hasNoSiBooklets = true;
        } else {
          final alloc = SiSeriesEngine.allocatePages(
            bookletState,
            candidate.pageCount,
            now: candidate.capturedAt,
          );
          siExhausted = alloc.exhausted;
          if (alloc.pageSiNumbers.any((s) => s != null && s.isNotEmpty)) {
            txToSave = candidate.copyWith(
              pageSiNumbers: alloc.pageSiNumbers,
              siRevision: candidate.siRevision + 1,
            );
            await bookletStorage.writeUnlocked(alloc.updatedState);
          }
        }
      }

      final updated = [...existingList, txToSave]
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      await _writeTransactionsForDateUnlocked(candidate.routeDate, updated);
      await _refreshPendingCountUnlocked();

      return TransactionSaveResult(
        transaction: txToSave,
        isDuplicate: false,
        siExhausted: siExhausted,
        hasNoSiBooklets: hasNoSiBooklets,
      );
    });
  }

  /// Atomically voids [pageNo] on [transaction] locally, shifts remaining pages
  /// forward by 1 using [bookletStorage], and marks `needsRemoteUpdate = true`
  /// if already uploaded so sync performs an in-place replacement (never duplicating).
  Future<SalesmanVoidResult> voidPageLocally({
    required String salesmanId,
    required RouteTransaction transaction,
    required int pageNo,
    required SiBookletStorageService bookletStorage,
    String? reason,
    String? voidedBy,
    String? voidedByName,
  }) async {
    return _withFileLock(() async {
      final list = await _readTransactionsForDateUnlocked(transaction.routeDate);
      final idx = list.indexWhere(
        (t) => t.transactionId == transaction.transactionId,
      );
      final latestTx = idx >= 0 ? list[idx] : transaction;

      final bookletState = await bookletStorage.readUnlocked(salesmanId);
      final result = SiSeriesEngine.voidPageOnTransaction(
        state: bookletState,
        transaction: latestTx,
        pageNo: pageNo,
        reason: reason,
        voidedBy: voidedBy ?? salesmanId,
        voidedByName: voidedByName,
        voidedByRole: 'salesman',
      );

      final updatedList = List<RouteTransaction>.from(list);
      if (idx >= 0) {
        updatedList[idx] = result.updatedTransaction;
      } else {
        updatedList.add(result.updatedTransaction);
        updatedList.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      }

      await _writeTransactionsForDateUnlocked(transaction.routeDate, updatedList);
      await bookletStorage.writeUnlocked(result.updatedState);
      await _refreshPendingCountUnlocked();

      return result;
    });
  }

  /// Returns all locally uploaded transactions that have unsynced SI edits (e.g. offline voids).
  Future<List<RouteTransaction>> getTransactionsNeedingRemoteUpdate() async {
    if (kIsWeb) return const [];
    return _withFileLock(() => _getTransactionsNeedingRemoteUpdateUnlocked());
  }

  Future<List<RouteTransaction>> _getTransactionsNeedingRemoteUpdateUnlocked() async {
    final dir = await _transactionsDir();
    if (dir == null || !await dir.exists()) return const [];

    final dirty = <RouteTransaction>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final fileName = entity.uri.pathSegments.last;
      if (fileName.startsWith('si_booklets_')) continue;
      try {
        final raw = await entity.readAsString();
        if (raw.trim().isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! List) continue;
        for (final item in decoded.whereType<Map<String, dynamic>>()) {
          final tx = RouteTransaction.fromMap(
            item,
            defaultUploadStatus: TransactionUploadStatus.pending,
          );
          if (tx.uploadStatus == TransactionUploadStatus.uploaded &&
              tx.needsRemoteUpdate) {
            dirty.add(tx);
          }
        }
      } catch (_) {}
    }

    dirty.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    return dirty;
  }

  Future<void> clearNeedsRemoteUpdate({
    required String routeDate,
    required String transactionId,
    required int syncedSiRevision,
    String? routeId,
  }) async {
    if (kIsWeb) return;
    await _withFileLock(() async {
      final list = await _readTransactionsForDateUnlocked(routeDate);
      if (list.isEmpty) return;

      var changed = false;
      final updated = list.map((tx) {
        if (tx.transactionId == transactionId &&
            tx.needsRemoteUpdate &&
            tx.siRevision <= syncedSiRevision) {
          changed = true;
          return tx.copyWith(
            needsRemoteUpdate: false,
            uploadedRouteId: routeId ?? tx.uploadedRouteId,
          );
        }
        return tx;
      }).toList();

      if (changed) {
        await _writeTransactionsForDateUnlocked(routeDate, updated);
        await _refreshPendingCountUnlocked();
      }
    });
  }

  /// Marks a transaction with [siConflict] locally if a collision was detected during sync.
  Future<void> markSiConflict({
    required String routeDate,
    required String transactionId,
  }) async {
    if (kIsWeb) return;
    await _withFileLock(() async {
      final list = await _readTransactionsForDateUnlocked(routeDate);
      var changed = false;
      final updated = list.map((tx) {
        if (tx.transactionId == transactionId && !tx.siConflict) {
          changed = true;
          return tx.copyWith(siConflict: true);
        }
        return tx;
      }).toList();
      if (changed) {
        await _writeTransactionsForDateUnlocked(routeDate, updated);
      }
    });
  }

  /// Returns all transactions across all local daily files still marked `pending`.
  Future<List<RouteTransaction>> getAllPendingTransactions() async {
    if (kIsWeb) return const [];
    return _getAllPendingTransactionsUnlocked();
  }

  Future<List<RouteTransaction>> _getAllPendingTransactionsUnlocked() async {
    final dir = await _transactionsDir();
    if (dir == null || !await dir.exists()) return const [];

    final pending = <RouteTransaction>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final fileName = entity.uri.pathSegments.last;
      if (fileName.startsWith('si_booklets_')) continue;
      try {
        final raw = await entity.readAsString();
        if (raw.trim().isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! List) continue;
        for (final item in decoded.whereType<Map<String, dynamic>>()) {
          final tx = RouteTransaction.fromMap(
            item,
            defaultUploadStatus: TransactionUploadStatus.pending,
          );
          if (tx.uploadStatus == TransactionUploadStatus.pending) {
            pending.add(tx);
          }
        }
      } catch (_) {}
    }

    pending.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    return pending;
  }

  Future<void> markAsUploaded({
    required String routeDate,
    required Set<String> transactionIds,
    required String routeId,
  }) async {
    if (kIsWeb || transactionIds.isEmpty) return;
    await _withFileLock(() async {
      final list = await _readTransactionsForDateUnlocked(routeDate);
      if (list.isEmpty) return;

      var changed = false;
      final updated = list.map((tx) {
        if (transactionIds.contains(tx.transactionId) &&
            tx.uploadStatus != TransactionUploadStatus.uploaded) {
          changed = true;
          return tx.copyWith(
            uploadStatus: TransactionUploadStatus.uploaded,
            uploadedRouteId: routeId,
          );
        }
        return tx;
      }).toList();

      if (changed) {
        await _writeTransactionsForDateUnlocked(routeDate, updated);
        await _refreshPendingCountUnlocked();
      }
    });
  }

  /// Merges remote Firestore transactions for [routeDate] into local storage
  /// and persists reconciled uploaded states so items are never re-queued.
  Future<List<RouteTransaction>> mergeWithRemote(
    String routeDate,
    List<RouteTransaction> remoteTransactions,
  ) async {
    if (kIsWeb) {
      return List<RouteTransaction>.from(remoteTransactions)
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    }

    return _withFileLock(() async {
      final local = await _readTransactionsForDateUnlocked(routeDate);
      final byCode = <String, RouteTransaction>{};
      var changed = false;

      for (final tx in local) {
        byCode[tx.invoiceCode.trim().toUpperCase()] = tx;
      }

      for (final remote in remoteTransactions) {
        final key = remote.invoiceCode.trim().toUpperCase();
        final existing = byCode[key];
        if (existing == null) {
          byCode[key] = remote.copyWith(
            uploadStatus: TransactionUploadStatus.uploaded,
            needsRemoteUpdate: false,
          );
          changed = true;
        } else if (existing.needsRemoteUpdate) {
          // Local has unsynced SI void/edit — preserve local changes until flushed.
          continue;
        } else if (remote.siRevision > existing.siRevision) {
          // Remote encoder updated SI series / voids — adopt remote SI fields.
          byCode[key] = existing.copyWith(
            pageSiNumbers: remote.pageSiNumbers,
            voidedSiEntries: remote.voidedSiEntries,
            siConflict: remote.siConflict,
            siRevision: remote.siRevision,
            uploadStatus: TransactionUploadStatus.uploaded,
            needsRemoteUpdate: false,
          );
          changed = true;
        } else if (existing.uploadStatus != TransactionUploadStatus.uploaded) {
          byCode[key] = existing.copyWith(
            uploadStatus: TransactionUploadStatus.uploaded,
          );
          changed = true;
        }
      }

      final merged = byCode.values.toList()
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      if (changed) {
        await _writeTransactionsForDateUnlocked(routeDate, merged);
        await _refreshPendingCountUnlocked();
      }
      return merged;
    });
  }

  Future<int> refreshPendingCount() async {
    return _withFileLock(() => _refreshPendingCountUnlocked());
  }

  Future<int> _refreshPendingCountUnlocked() async {
    final pending = await _getAllPendingTransactionsUnlocked();
    final dirty = await _getTransactionsNeedingRemoteUpdateUnlocked();
    final total = pending.length + dirty.length;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(pendingCountPrefsKey, total);
    return total;
  }

  Future<int> getCachedPendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(pendingCountPrefsKey) ?? 0;
  }

  /// Purges fully uploaded local daily transaction files older than [retentionDays].
  Future<void> purgeOldUploadedFiles({int retentionDays = 30}) async {
    if (kIsWeb) return;
    await _withFileLock(() async {
      final dir = await _transactionsDir();
      if (dir == null || !await dir.exists()) return;

      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final fileName = entity.uri.pathSegments.last;
        if (fileName.startsWith('si_booklets_')) continue;
        try {
          final name = fileName.replaceAll('.json', '');
          final fileDate = DateTime.tryParse(name);
          if (fileDate == null || !fileDate.isBefore(cutoff)) continue;

          final list = await _readTransactionsForDateUnlocked(name);
          final hasPending = list.any(
            (tx) =>
                tx.uploadStatus == TransactionUploadStatus.pending ||
                tx.needsRemoteUpdate,
          );
          if (!hasPending) {
            await entity.delete();
          }
        } catch (_) {}
      }
    });
  }
}
