import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';

/// Parsed & validated booklet range input entered by an encoder.
class ParsedBookletRange {
  final int startNumber;
  final int endNumber;
  final int padWidth;

  const ParsedBookletRange({
    required this.startNumber,
    required this.endNumber,
    required this.padWidth,
  });

  int get totalPages => endNumber - startNumber + 1;
  String get startFormatted => formatSiNumber(startNumber, padWidth);
  String get endFormatted => formatSiNumber(endNumber, padWidth);
}

class SiAllocationResult {
  final SalesmanSiBookletState updatedState;
  final List<String?> pageSiNumbers;
  final bool exhausted;

  const SiAllocationResult({
    required this.updatedState,
    required this.pageSiNumbers,
    required this.exhausted,
  });
}

class SalesmanVoidResult {
  final SalesmanSiBookletState updatedState;
  final RouteTransaction updatedTransaction;
  final SiVoidEntry voidedEntry;
  final bool exhausted;

  const SalesmanVoidResult({
    required this.updatedState,
    required this.updatedTransaction,
    required this.voidedEntry,
    required this.exhausted,
  });
}

class TransactionSiDiff {
  final RouteTransaction before;
  final RouteTransaction after;

  const TransactionSiDiff({required this.before, required this.after});
}

class EncoderCascadePreview {
  final bool isUnvoid;
  final SiVoidEntry targetVoidEntry;
  final List<TransactionSiDiff> diffs;
  final SalesmanSiBookletState updatedState;
  final int unassignedSlotsCount;
  final Set<String> affectedDates;

  const EncoderCascadePreview({
    required this.isUnvoid,
    required this.targetVoidEntry,
    required this.diffs,
    required this.updatedState,
    required this.unassignedSlotsCount,
    required this.affectedDates,
  });

  bool get crossesMultipleDates => affectedDates.length > 1;
}

class _ParsedSiToken {
  final String formatted;
  final int numeric;

  const _ParsedSiToken(this.formatted, this.numeric);
}

/// Pure, deterministic business logic for SI booklet range validation,
/// chronological allocation, voiding/un-voiding cascades, and summary formatting.
class SiSeriesEngine {
  static const int maxPagesPerBooklet = 100000;
  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  /// Validates raw text inputs from encoder ("0001001" .. "0001050").
  /// Throws [FormatException] with a user-friendly message when invalid.
  static ParsedBookletRange parseBookletInput(String startRaw, String endRaw) {
    final s = startRaw.trim();
    final e = endRaw.trim();
    if (s.isEmpty || e.isEmpty) {
      throw const FormatException('Please enter both first page and last page.');
    }
    if (!_digitsOnly.hasMatch(s) || !_digitsOnly.hasMatch(e)) {
      throw const FormatException(
        'SI series numbers must contain digits only (0–9).',
      );
    }
    final start = int.tryParse(s);
    final end = int.tryParse(e);
    if (start == null || end == null || start < 0 || end < 0) {
      throw const FormatException('Invalid SI series number.');
    }
    if (end < start) {
      throw const FormatException(
        'Last page number must be greater than or equal to first page number.',
      );
    }
    final count = end - start + 1;
    if (count > maxPagesPerBooklet) {
      throw const FormatException(
        'A single booklet cannot exceed $maxPagesPerBooklet pages.',
      );
    }
    final preserveWidth = (s.startsWith('0') || e.startsWith('0'))
        ? (s.length >= e.length ? s.length : e.length)
        : 0;
    return ParsedBookletRange(
      startNumber: start,
      endNumber: end,
      padWidth: preserveWidth,
    );
  }

  /// Formats a transaction's per-page SI series into compact summary notation:
  /// - Single page: `123456`
  /// - Contiguous within same prefix (last 3 digits differ): `123456-461`
  /// - Contiguous crossing thousand/prefix boundary: `123998-124002`
  /// - Split by void or booklet jump: `123456-458,123460-461`
  static String formatSeriesSummary(List<String?> pageSiNumbers) {
    final tokens = <_ParsedSiToken>[];
    for (final raw in pageSiNumbers) {
      final trimmed = raw?.trim() ?? '';
      if (trimmed.isEmpty) continue;
      final numeric = int.tryParse(trimmed);
      if (numeric == null) continue;
      tokens.add(_ParsedSiToken(trimmed, numeric));
    }
    if (tokens.isEmpty) return '';

    final segments = <String>[];
    var runStart = tokens.first;
    var runPrev = tokens.first;

    void flushRun() {
      if (runStart.numeric == runPrev.numeric) {
        segments.add(runStart.formatted);
        return;
      }
      final a = runStart.formatted;
      final b = runPrev.formatted;
      final canShortenToLast3 = a.length >= 4 &&
          a.length == b.length &&
          a.substring(0, a.length - 3) == b.substring(0, b.length - 3);
      if (canShortenToLast3) {
        segments.add('$a-${b.substring(b.length - 3)}');
      } else {
        segments.add('$a-$b');
      }
    }

    for (var i = 1; i < tokens.length; i++) {
      final current = tokens[i];
      if (current.numeric == runPrev.numeric + 1) {
        runPrev = current;
      } else {
        flushRun();
        runStart = current;
        runPrev = current;
      }
    }
    flushRun();

    return segments.join(',');
  }

  /// Formats voided SI numbers on a transaction (sorted ascending, comma-separated).
  static String formatVoidedSummary(List<SiVoidEntry> voidedEntries) {
    if (voidedEntries.isEmpty) return '';
    final sorted = List<SiVoidEntry>.from(voidedEntries)
      ..sort((a, b) => a.numericValue.compareTo(b.numericValue));
    return sorted
        .map((e) => e.siNumber.trim())
        .where((s) => s.isNotEmpty)
        .join(',');
  }

  /// Finds which booklet contains [numericValue], if any.
  static SiBooklet? findBookletContaining(
    SalesmanSiBookletState state,
    int numericValue,
  ) {
    for (final b in state.sortedBooklets) {
      if (b.containsNumber(numericValue)) return b;
    }
    return null;
  }

  /// Allocates [pageCount] sequential SI numbers from the salesman's booklets
  /// ordered ascending by `startNumber`, seamlessly spanning across booklets.
  /// If booklets run out mid-allocation, trailing slots are `null` (non-blocking).
  static SiAllocationResult allocatePages(
    SalesmanSiBookletState state,
    int pageCount, {
    DateTime? now,
  }) {
    if (pageCount <= 0) {
      return SiAllocationResult(
        updatedState: state,
        pageSiNumbers: const [],
        exhausted: false,
      );
    }

    final timestamp = now ?? DateTime.now();
    final updatedBooklets = state.sortedBooklets
        .map((b) => b.copyWith())
        .toList();
    final assigned = <String?>[];
    var exhausted = false;

    for (var i = 0; i < pageCount; i++) {
      String? picked;
      for (var bi = 0; bi < updatedBooklets.length; bi++) {
        final b = updatedBooklets[bi];
        if (!b.isExhausted) {
          picked = b.formatValue(b.nextNumber);
          updatedBooklets[bi] = b.copyWith(
            nextNumber: b.nextNumber + 1,
            updatedAt: timestamp,
          );
          break;
        }
      }
      if (picked == null) {
        exhausted = true;
      }
      assigned.add(picked);
    }

    final changed = assigned.any((s) => s != null);
    final updatedState = changed
        ? state.copyWith(
            booklets: updatedBooklets,
            updatedAt: timestamp,
            hasPendingSync: true,
          )
        : state;

    return SiAllocationResult(
      updatedState: updatedState,
      pageSiNumbers: assigned,
      exhausted: exhausted,
    );
  }

  /// Salesman live void: marks [pageNo] (1-based) on [transaction] as void,
  /// shifts [pageNo..pageCount] forward by 1, and pulls 1 new SI number from
  /// [state] for the last page of [transaction].
  static SalesmanVoidResult voidPageOnTransaction({
    required SalesmanSiBookletState state,
    required RouteTransaction transaction,
    required int pageNo,
    String? reason,
    String? voidedBy,
    String? voidedByName,
    String voidedByRole = 'salesman',
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final pageIndex = pageNo - 1;
    final currentPages = _normalizedPageList(transaction);

    if (pageIndex < 0 || pageIndex >= currentPages.length) {
      throw ArgumentError('Invalid page number $pageNo.');
    }

    final targetSi = currentPages[pageIndex]?.trim();
    if (targetSi == null || targetSi.isEmpty) {
      throw StateError('Page $pageNo does not have an assigned SI number.');
    }

    final targetNumeric = int.tryParse(targetSi) ?? 0;
    final matchedBooklet = findBookletContaining(state, targetNumeric);

    final voidEntry = SiVoidEntry(
      siNumber: targetSi,
      numericValue: targetNumeric,
      bookletId: matchedBooklet?.id,
      pageNo: pageNo,
      transactionId: transaction.transactionId,
      invoiceCode: transaction.invoiceCode,
      reason: reason?.trim().isEmpty == true ? null : reason?.trim(),
      voidedAt: timestamp,
      voidedBy: voidedBy,
      voidedByRole: voidedByRole,
      voidedByName: voidedByName,
    );

    // Pull 1 replacement SI number from the booklet pool for the tail slot.
    final nextAlloc = allocatePages(state, 1, now: timestamp);
    final tailReplacement = nextAlloc.pageSiNumbers.isNotEmpty
        ? nextAlloc.pageSiNumbers.first
        : null;

    final shiftedPages = List<String?>.from(currentPages);
    for (var i = pageIndex; i < shiftedPages.length - 1; i++) {
      shiftedPages[i] = shiftedPages[i + 1];
    }
    shiftedPages[shiftedPages.length - 1] = tailReplacement;

    final updatedVoids = [...transaction.voidedSiEntries, voidEntry]
      ..sort((a, b) => a.numericValue.compareTo(b.numericValue));

    final updatedTx = transaction.copyWith(
      pageSiNumbers: shiftedPages,
      voidedSiEntries: updatedVoids,
      siRevision: transaction.siRevision + 1,
      needsRemoteUpdate: transaction.isUploaded ? true : transaction.needsRemoteUpdate,
    );

    final updatedState = nextAlloc.updatedState.copyWith(
      recentVoids: [...nextAlloc.updatedState.recentVoids, voidEntry],
      updatedAt: timestamp,
      hasPendingSync: true,
    );

    return SalesmanVoidResult(
      updatedState: updatedState,
      updatedTransaction: updatedTx,
      voidedEntry: voidEntry,
      exhausted: nextAlloc.exhausted,
    );
  }

  /// Sorts transactions chronologically for cascade operations using their
  /// assigned SI order first (clock-skew proof), falling back to `capturedAt`.
  static List<RouteTransaction> sortTransactionsChronologically(
    List<RouteTransaction> transactions,
  ) {
    final copy = List<RouteTransaction>.from(transactions);
    copy.sort((a, b) {
      final aNum = a.firstAssignedSiNumeric;
      final bNum = b.firstAssignedSiNumeric;
      if (aNum != null && bNum != null && aNum != bNum) {
        return aNum.compareTo(bNum);
      }
      final timeCmp = a.capturedAt.compareTo(b.capturedAt);
      if (timeCmp != 0) return timeCmp;
      return a.transactionId.compareTo(b.transactionId);
    });
    return copy;
  }

  /// Builds a preview (and final mutated objects) for an Encoder/Superuser void
  /// that cascades chronologically across [scopedTransactions].
  static EncoderCascadePreview previewEncoderVoidCascade({
    required SalesmanSiBookletState state,
    required List<RouteTransaction> scopedTransactions,
    required String targetTransactionId,
    required int targetPageNo,
    String? reason,
    String? voidedBy,
    String? voidedByName,
    String voidedByRole = 'encoder',
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final ordered = sortTransactionsChronologically(scopedTransactions);

    final targetTxIdx = ordered.indexWhere(
      (t) => t.transactionId == targetTransactionId,
    );
    if (targetTxIdx < 0) {
      throw StateError('Target transaction not found in scope.');
    }

    final targetTx = ordered[targetTxIdx];
    final targetPages = _normalizedPageList(targetTx);
    final pageIdx = targetPageNo - 1;
    if (pageIdx < 0 || pageIdx >= targetPages.length) {
      throw ArgumentError('Invalid page number $targetPageNo.');
    }

    final targetSi = targetPages[pageIdx]?.trim();
    if (targetSi == null || targetSi.isEmpty) {
      throw StateError('Page $targetPageNo has no SI number to void.');
    }

    final targetNumeric = int.tryParse(targetSi) ?? 0;
    final matchedBooklet = findBookletContaining(state, targetNumeric);

    final voidEntry = SiVoidEntry(
      siNumber: targetSi,
      numericValue: targetNumeric,
      bookletId: matchedBooklet?.id,
      pageNo: targetPageNo,
      transactionId: targetTx.transactionId,
      invoiceCode: targetTx.invoiceCode,
      reason: reason?.trim().isEmpty == true ? null : reason?.trim(),
      voidedAt: timestamp,
      voidedBy: voidedBy,
      voidedByRole: voidedByRole,
      voidedByName: voidedByName,
    );

    // Gather every slot starting from (targetTxIdx, pageIdx) through the end
    // of all numbered transactions in scope.
    final slots = <({int txIdx, int slotIdx, String? currentSi})>[];
    for (var ti = targetTxIdx; ti < ordered.length; ti++) {
      final tx = ordered[ti];
      // Skip completely unnumbered transactions after the target so we don't
      // accidentally number unrelated historical/unassigned rows.
      if (ti > targetTxIdx && !tx.hasAnySiAssigned) continue;
      final pages = _normalizedPageList(tx);
      final startSlot = ti == targetTxIdx ? pageIdx : 0;
      for (var si = startSlot; si < pages.length; si++) {
        slots.add((txIdx: ti, slotIdx: si, currentSi: pages[si]));
      }
    }

    // Pull 1 replacement SI number from the booklet pool for the final tail slot.
    final tailAlloc = allocatePages(state, 1, now: timestamp);
    final tailReplacement = tailAlloc.pageSiNumbers.isNotEmpty
        ? tailAlloc.pageSiNumbers.first
        : null;

    // Shift all slots forward by 1.
    final newValues = <String?>[];
    for (var i = 0; i < slots.length - 1; i++) {
      newValues.add(slots[i + 1].currentSi);
    }
    newValues.add(tailReplacement);

    // Apply shifted values back to copies of affected transactions.
    final mutatedPagesByTxIdx = <int, List<String?>>{};
    var unassignedCount = 0;
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final list = mutatedPagesByTxIdx.putIfAbsent(
        slot.txIdx,
        () => _normalizedPageList(ordered[slot.txIdx]),
      );
      list[slot.slotIdx] = newValues[i];
      if (newValues[i] == null || newValues[i]!.isEmpty) {
        unassignedCount++;
      }
    }

    final diffs = <TransactionSiDiff>[];
    final affectedDates = <String>{};
    for (final entry in mutatedPagesByTxIdx.entries) {
      final before = ordered[entry.key];
      final updatedVoids = entry.key == targetTxIdx
          ? ([...before.voidedSiEntries, voidEntry]
            ..sort((a, b) => a.numericValue.compareTo(b.numericValue)))
          : before.voidedSiEntries;
      final after = before.copyWith(
        pageSiNumbers: entry.value,
        voidedSiEntries: updatedVoids,
        siRevision: before.siRevision + 1,
        siConflict: false,
      );
      diffs.add(TransactionSiDiff(before: before, after: after));
      affectedDates.add(before.routeDate);
    }

    final updatedState = tailAlloc.updatedState.copyWith(
      revision: state.revision + 1,
      recentVoids: [...tailAlloc.updatedState.recentVoids, voidEntry],
      updatedAt: timestamp,
      hasPendingSync: false,
    );

    return EncoderCascadePreview(
      isUnvoid: false,
      targetVoidEntry: voidEntry,
      diffs: diffs,
      updatedState: updatedState,
      unassignedSlotsCount: unassignedCount,
      affectedDates: affectedDates,
    );
  }

  /// Builds a preview to **un-void** a mistakenly voided SI number on
  /// [targetTransactionId], restoring it chronologically and shifting subsequent
  /// slots back by 1 (and stepping the booklet pointer back if the freed tail
  /// sits at `nextNumber - 1`).
  static EncoderCascadePreview previewEncoderUnvoidCascade({
    required SalesmanSiBookletState state,
    required List<RouteTransaction> scopedTransactions,
    required String targetTransactionId,
    required String voidedSiNumber,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final ordered = sortTransactionsChronologically(scopedTransactions);

    final targetTxIdx = ordered.indexWhere(
      (t) => t.transactionId == targetTransactionId,
    );
    if (targetTxIdx < 0) {
      throw StateError('Target transaction not found in scope.');
    }

    final targetTx = ordered[targetTxIdx];
    final targetVoid = targetTx.voidedSiEntries.firstWhere(
      (v) => v.siNumber.trim() == voidedSiNumber.trim(),
      orElse: () => throw StateError(
        'Voided SI $voidedSiNumber not found on this transaction.',
      ),
    );

    // Find the insertion slot on targetTx: first page whose assigned numeric SI
    // is greater than targetVoid.numericValue (or fallback to targetVoid.pageNo - 1).
    final targetPages = _normalizedPageList(targetTx);
    var insertSlotIdx = -1;
    for (var i = 0; i < targetPages.length; i++) {
      final numVal = int.tryParse(targetPages[i]?.trim() ?? '');
      if (numVal != null && numVal > targetVoid.numericValue) {
        insertSlotIdx = i;
        break;
      }
    }
    if (insertSlotIdx < 0) {
      insertSlotIdx = (targetVoid.pageNo - 1).clamp(0, targetPages.length - 1);
    }

    final slots = <({int txIdx, int slotIdx, String? currentSi})>[];
    for (var ti = targetTxIdx; ti < ordered.length; ti++) {
      final tx = ordered[ti];
      if (ti > targetTxIdx && !tx.hasAnySiAssigned) continue;
      final pages = _normalizedPageList(tx);
      final startSlot = ti == targetTxIdx ? insertSlotIdx : 0;
      for (var si = startSlot; si < pages.length; si++) {
        slots.add((txIdx: ti, slotIdx: si, currentSi: pages[si]));
      }
    }

    if (slots.isEmpty) {
      throw StateError('No pages available to restore.');
    }

    final freedTailSi = slots.last.currentSi;
    final newValues = <String?>[targetVoid.siNumber];
    for (var i = 0; i < slots.length - 1; i++) {
      newValues.add(slots[i].currentSi);
    }

    final mutatedPagesByTxIdx = <int, List<String?>>{};
    var unassignedCount = 0;
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final list = mutatedPagesByTxIdx.putIfAbsent(
        slot.txIdx,
        () => _normalizedPageList(ordered[slot.txIdx]),
      );
      list[slot.slotIdx] = newValues[i];
      if (newValues[i] == null || newValues[i]!.isEmpty) {
        unassignedCount++;
      }
    }

    final diffs = <TransactionSiDiff>[];
    final affectedDates = <String>{};
    for (final entry in mutatedPagesByTxIdx.entries) {
      final before = ordered[entry.key];
      final updatedVoids = entry.key == targetTxIdx
          ? before.voidedSiEntries
              .where((v) => v.siNumber.trim() != targetVoid.siNumber.trim())
              .toList()
          : before.voidedSiEntries;
      final after = before.copyWith(
        pageSiNumbers: entry.value,
        voidedSiEntries: updatedVoids,
        siRevision: before.siRevision + 1,
        siConflict: false,
      );
      diffs.add(TransactionSiDiff(before: before, after: after));
      affectedDates.add(before.routeDate);
    }

    // Reclaim the freed tail SI number back into its booklet if it sits right
    // at `nextNumber - 1` (so the salesman's next invoice reuses it seamlessly).
    final updatedBooklets = state.sortedBooklets
        .map((b) => b.copyWith())
        .toList();
    final freedNumeric = int.tryParse(freedTailSi?.trim() ?? '');
    if (freedNumeric != null) {
      for (var bi = 0; bi < updatedBooklets.length; bi++) {
        final b = updatedBooklets[bi];
        if (b.containsNumber(freedNumeric) &&
            b.nextNumber == freedNumeric + 1) {
          updatedBooklets[bi] = b.copyWith(
            nextNumber: freedNumeric,
            updatedAt: timestamp,
          );
          break;
        }
      }
    }

    final updatedRecentVoids = state.recentVoids
        .where(
          (v) =>
              !(v.siNumber.trim() == targetVoid.siNumber.trim() &&
                  v.transactionId == targetTransactionId),
        )
        .toList();

    final updatedState = state.copyWith(
      revision: state.revision + 1,
      booklets: updatedBooklets,
      recentVoids: updatedRecentVoids,
      updatedAt: timestamp,
      hasPendingSync: false,
    );

    return EncoderCascadePreview(
      isUnvoid: true,
      targetVoidEntry: targetVoid,
      diffs: diffs,
      updatedState: updatedState,
      unassignedSlotsCount: unassignedCount,
      affectedDates: affectedDates,
    );
  }

  /// Reconciles local salesman booklet state against remote Firestore state.
  /// - If encoder bumped `remote.revision > local.revision`, remote structure
  ///   and pointers win (while preserving local pending voids not yet synced).
  /// - Otherwise, keeps the higher `nextNumber` per booklet so local offline
  ///   progress is never rolled back.
  static SalesmanSiBookletState reconcileBookletStates({
    required SalesmanSiBookletState local,
    required SalesmanSiBookletState remote,
  }) {
    if (remote.revision > local.revision) {
      return remote.copyWith(hasPendingSync: false);
    }

    final localById = {for (final b in local.booklets) b.id: b};
    final mergedBooklets = <SiBooklet>[];
    var localAhead = false;

    for (final rb in remote.sortedBooklets) {
      final lb = localById[rb.id];
      if (lb == null) {
        mergedBooklets.add(rb);
      } else {
        final bestNext = lb.nextNumber > rb.nextNumber
            ? lb.nextNumber
            : rb.nextNumber;
        if (lb.nextNumber > rb.nextNumber) {
          localAhead = true;
        }
        mergedBooklets.add(
          rb.copyWith(
            nextNumber: bestNext.clamp(rb.startNumber, rb.endNumber + 1),
          ),
        );
      }
    }

    // Merge recentVoids uniquely by (siNumber, transactionId)
    final voidKeys = <String>{};
    final mergedVoids = <SiVoidEntry>[];
    for (final v in [...remote.recentVoids, ...local.recentVoids]) {
      final key = '${v.siNumber}|${v.transactionId ?? ''}';
      if (voidKeys.add(key)) {
        mergedVoids.add(v);
      }
    }
    mergedVoids.sort((a, b) => a.voidedAt.compareTo(b.voidedAt));

    return SalesmanSiBookletState(
      salesmanId: remote.salesmanId,
      companyId: remote.companyId ?? local.companyId,
      revision: remote.revision,
      booklets: mergedBooklets..sort((a, b) => a.startNumber.compareTo(b.startNumber)),
      recentVoids: mergedVoids.length > SalesmanSiBookletState.maxRecentVoids
          ? mergedVoids.sublist(
              mergedVoids.length - SalesmanSiBookletState.maxRecentVoids,
            )
          : mergedVoids,
      updatedAt: local.updatedAt.isAfter(remote.updatedAt)
          ? local.updatedAt
          : remote.updatedAt,
      hasPendingSync: local.hasPendingSync || localAhead,
    );
  }

  /// Checks whether any SI number on [candidate] collides with SI numbers
  /// already used or voided on [existingRemoteTransactions].
  static bool hasSiCollision(
    RouteTransaction candidate,
    List<RouteTransaction> existingRemoteTransactions,
  ) {
    final candidateNums = candidate.pageSiNumbers
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (candidateNums.isEmpty) return false;

    for (final other in existingRemoteTransactions) {
      if (other.transactionId == candidate.transactionId) continue;
      for (final used in other.pageSiNumbers) {
        if (used != null && candidateNums.contains(used.trim())) {
          return true;
        }
      }
      for (final v in other.voidedSiEntries) {
        if (candidateNums.contains(v.siNumber.trim())) {
          return true;
        }
      }
    }
    return false;
  }

  static List<String?> _normalizedPageList(RouteTransaction tx) {
    final count = tx.pageCount > 0 ? tx.pageCount : 1;
    return List<String?>.generate(
      count,
      (i) => i < tx.pageSiNumbers.length ? tx.pageSiNumbers[i] : null,
    );
  }
}

