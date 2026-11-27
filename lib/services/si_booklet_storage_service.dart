import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';

/// Persists a salesman's SI booklet state locally in `appDocs/transactions/si_booklets_<uid>.json`
/// using the same exclusive `.tx.lock` file lock as `TransactionStorageService` so
/// Main, Overlay, and Background Android isolates never race when consuming SI numbers.
class SiBookletStorageService {
  Future<Directory?> _storageDir() async {
    if (kIsWeb) return null;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/transactions');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cross-isolate exclusive file lock shared with `TransactionStorageService`.
  Future<T> withSharedLock<T>(Future<T> Function() action) async {
    if (kIsWeb) return action();
    final dir = await _storageDir();
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

  Future<File?> _bookletFile(String salesmanId) async {
    final dir = await _storageDir();
    if (dir == null) return null;
    final safeUid = salesmanId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return File('${dir.path}/si_booklets_$safeUid.json');
  }

  Future<SalesmanSiBookletState> readUnlocked(String salesmanId) async {
    if (kIsWeb || salesmanId.trim().isEmpty) {
      return SalesmanSiBookletState.empty(salesmanId);
    }
    final file = await _bookletFile(salesmanId);
    if (file == null || !await file.exists()) {
      return SalesmanSiBookletState.empty(salesmanId);
    }
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return SalesmanSiBookletState.empty(salesmanId);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return SalesmanSiBookletState.empty(salesmanId);
      }
      return SalesmanSiBookletState.fromMap(decoded, salesmanId: salesmanId);
    } catch (e) {
      debugPrint('[SiBookletStorageService] Failed reading state for $salesmanId: $e');
      return SalesmanSiBookletState.empty(salesmanId);
    }
  }

  Future<void> writeUnlocked(SalesmanSiBookletState state) async {
    if (kIsWeb || state.salesmanId.trim().isEmpty) return;
    final file = await _bookletFile(state.salesmanId);
    if (file == null) return;
    final encoded = jsonEncode(state.toLocalJson());
    final uniqueId = DateTime.now().microsecondsSinceEpoch;
    final tmpFile = File('${file.path}.$uniqueId.tmp');
    await tmpFile.writeAsString(encoded, flush: true);
    await tmpFile.rename(file.path);
  }

  Future<SalesmanSiBookletState> getBookletState(String salesmanId) async {
    if (kIsWeb) return SalesmanSiBookletState.empty(salesmanId);
    return withSharedLock(() => readUnlocked(salesmanId));
  }

  Future<void> saveBookletState(SalesmanSiBookletState state) async {
    if (kIsWeb) return;
    await withSharedLock(() => writeUnlocked(state));
  }
}

