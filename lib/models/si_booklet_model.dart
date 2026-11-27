import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? _parseSiDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is Timestamp) return value.toDate();
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  return null;
}

enum SiBookletStatus { unused, active, exhausted }

/// Formats an integer SI number using [padWidth] to preserve leading zeros.
String formatSiNumber(int number, int padWidth) {
  final raw = number.toString();
  if (padWidth <= raw.length) return raw;
  return raw.padLeft(padWidth, '0');
}

/// Represents a single physical BIR Sales Invoice booklet assigned to a salesman.
class SiBooklet {
  final String id;
  final int startNumber;
  final int endNumber;
  final int padWidth;
  final int nextNumber;
  final DateTime createdAt;
  final String? createdBy;
  final String? createdByName;
  final DateTime? updatedAt;

  const SiBooklet({
    required this.id,
    required this.startNumber,
    required this.endNumber,
    required this.padWidth,
    required this.nextNumber,
    required this.createdAt,
    this.createdBy,
    this.createdByName,
    this.updatedAt,
  });

  int get totalPages =>
      endNumber >= startNumber ? (endNumber - startNumber + 1) : 0;

  int get usedPages => (nextNumber - startNumber).clamp(0, totalPages);

  int get remainingPages => (endNumber - nextNumber + 1).clamp(0, totalPages);

  bool get isUnused => nextNumber <= startNumber;

  bool get isExhausted => nextNumber > endNumber;

  /// The highest number already consumed from this booklet, or null if unused.
  int? get lastUsedNumber => isUnused ? null : (nextNumber - 1);

  SiBookletStatus get status {
    if (isExhausted) return SiBookletStatus.exhausted;
    if (isUnused) return SiBookletStatus.unused;
    return SiBookletStatus.active;
  }

  String get startFormatted => formatSiNumber(startNumber, padWidth);
  String get endFormatted => formatSiNumber(endNumber, padWidth);
  String? get nextFormatted =>
      isExhausted ? null : formatSiNumber(nextNumber, padWidth);
  String get rangeLabel => '$startFormatted – $endFormatted';

  String formatValue(int number) => formatSiNumber(number, padWidth);

  bool containsNumber(int number) =>
      number >= startNumber && number <= endNumber;

  bool overlapsRange(int otherStart, int otherEnd) =>
      startNumber <= otherEnd && otherStart <= endNumber;

  SiBooklet copyWith({
    String? id,
    int? startNumber,
    int? endNumber,
    int? padWidth,
    int? nextNumber,
    DateTime? createdAt,
    String? createdBy,
    String? createdByName,
    DateTime? updatedAt,
  }) {
    return SiBooklet(
      id: id ?? this.id,
      startNumber: startNumber ?? this.startNumber,
      endNumber: endNumber ?? this.endNumber,
      padWidth: padWidth ?? this.padWidth,
      nextNumber: nextNumber ?? this.nextNumber,
      createdAt: createdAt ?? this.createdAt,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory SiBooklet.fromMap(Map<String, dynamic> data) {
    final start = (data['startNumber'] as num?)?.toInt() ?? 0;
    final end = (data['endNumber'] as num?)?.toInt() ?? start;
    final padWidth = (data['padWidth'] as num?)?.toInt() ??
        start.toString().length;
    final next = (data['nextNumber'] as num?)?.toInt() ?? start;
    return SiBooklet(
      id: (data['id'] as String? ?? '').trim(),
      startNumber: start,
      endNumber: end,
      padWidth: padWidth,
      nextNumber: next,
      createdAt: _parseSiDateTime(data['createdAt']) ?? DateTime.now(),
      createdBy: (data['createdBy'] as String?)?.trim(),
      createdByName: (data['createdByName'] as String?)?.trim(),
      updatedAt: _parseSiDateTime(data['updatedAt']),
    );
  }

  Map<String, dynamic> toFirestoreMap() {
    return {
      'id': id,
      'startNumber': startNumber,
      'endNumber': endNumber,
      'padWidth': padWidth,
      'nextNumber': nextNumber,
      'createdAt': createdAt,
      if (createdBy != null && createdBy!.isNotEmpty) 'createdBy': createdBy,
      if (createdByName != null && createdByName!.isNotEmpty)
        'createdByName': createdByName,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  Map<String, dynamic> toLocalJson() {
    final map = toFirestoreMap();
    map['createdAt'] = createdAt.millisecondsSinceEpoch;
    if (updatedAt != null) {
      map['updatedAt'] = updatedAt!.millisecondsSinceEpoch;
    }
    return map;
  }
}

/// Audit record for a voided physical Sales Invoice page.
class SiVoidEntry {
  final String siNumber;
  final int numericValue;
  final String? bookletId;
  final int pageNo;
  final String? transactionId;
  final String? invoiceCode;
  final String? reason;
  final DateTime voidedAt;
  final String? voidedBy;
  final String? voidedByRole;
  final String? voidedByName;

  const SiVoidEntry({
    required this.siNumber,
    required this.numericValue,
    this.bookletId,
    required this.pageNo,
    this.transactionId,
    this.invoiceCode,
    this.reason,
    required this.voidedAt,
    this.voidedBy,
    this.voidedByRole,
    this.voidedByName,
  });

  factory SiVoidEntry.fromMap(Map<String, dynamic> data) {
    final siStr = (data['siNumber'] as String? ?? '').trim();
    final numeric = (data['numericValue'] as num?)?.toInt() ??
        int.tryParse(siStr) ??
        0;
    return SiVoidEntry(
      siNumber: siStr,
      numericValue: numeric,
      bookletId: (data['bookletId'] as String?)?.trim(),
      pageNo: (data['pageNo'] as num?)?.toInt() ?? 1,
      transactionId: (data['transactionId'] as String?)?.trim(),
      invoiceCode: (data['invoiceCode'] as String?)?.trim(),
      reason: (data['reason'] as String?)?.trim(),
      voidedAt: _parseSiDateTime(data['voidedAt']) ?? DateTime.now(),
      voidedBy: (data['voidedBy'] as String?)?.trim(),
      voidedByRole: (data['voidedByRole'] as String?)?.trim(),
      voidedByName: (data['voidedByName'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toFirestoreMap() {
    return {
      'siNumber': siNumber,
      'numericValue': numericValue,
      if (bookletId != null && bookletId!.isNotEmpty) 'bookletId': bookletId,
      'pageNo': pageNo,
      if (transactionId != null && transactionId!.isNotEmpty)
        'transactionId': transactionId,
      if (invoiceCode != null && invoiceCode!.isNotEmpty)
        'invoiceCode': invoiceCode,
      if (reason != null && reason!.isNotEmpty) 'reason': reason,
      'voidedAt': voidedAt,
      if (voidedBy != null && voidedBy!.isNotEmpty) 'voidedBy': voidedBy,
      if (voidedByRole != null && voidedByRole!.isNotEmpty)
        'voidedByRole': voidedByRole,
      if (voidedByName != null && voidedByName!.isNotEmpty)
        'voidedByName': voidedByName,
    };
  }

  Map<String, dynamic> toLocalJson() {
    final map = toFirestoreMap();
    map['voidedAt'] = voidedAt.millisecondsSinceEpoch;
    return map;
  }
}

/// Complete booklet state for a single salesman (`si_booklets/{salesmanId}`).
class SalesmanSiBookletState {
  static const int maxRecentVoids = 200;

  final String salesmanId;
  final String? companyId;
  final int revision;
  final List<SiBooklet> booklets;
  final List<SiVoidEntry> recentVoids;
  final DateTime updatedAt;
  final bool hasPendingSync;

  const SalesmanSiBookletState({
    required this.salesmanId,
    this.companyId,
    this.revision = 0,
    this.booklets = const [],
    this.recentVoids = const [],
    required this.updatedAt,
    this.hasPendingSync = false,
  });

  factory SalesmanSiBookletState.empty(
    String salesmanId, {
    String? companyId,
  }) {
    return SalesmanSiBookletState(
      salesmanId: salesmanId,
      companyId: companyId,
      revision: 0,
      booklets: const [],
      recentVoids: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      hasPendingSync: false,
    );
  }

  List<SiBooklet> get sortedBooklets {
    final copy = List<SiBooklet>.from(booklets)
      ..sort((a, b) => a.startNumber.compareTo(b.startNumber));
    return copy;
  }

  SiBooklet? get nextActiveBooklet {
    for (final b in sortedBooklets) {
      if (!b.isExhausted) return b;
    }
    return null;
  }

  int get totalRemainingPages =>
      booklets.fold<int>(0, (acc, b) => acc + b.remainingPages);

  int get totalAssignedPages =>
      booklets.fold<int>(0, (acc, b) => acc + b.totalPages);

  int get totalUsedPages =>
      booklets.fold<int>(0, (acc, b) => acc + b.usedPages);

  bool get hasBooklets => booklets.isNotEmpty;

  bool get hasAvailablePages => totalRemainingPages > 0;

  String? get nextAvailableFormatted => nextActiveBooklet?.nextFormatted;

  SalesmanSiBookletState copyWith({
    String? salesmanId,
    String? companyId,
    int? revision,
    List<SiBooklet>? booklets,
    List<SiVoidEntry>? recentVoids,
    DateTime? updatedAt,
    bool? hasPendingSync,
  }) {
    final sorted = booklets != null
        ? (List<SiBooklet>.from(booklets)
          ..sort((a, b) => a.startNumber.compareTo(b.startNumber)))
        : this.booklets;
    final trimmedVoids = recentVoids != null && recentVoids.length > maxRecentVoids
        ? recentVoids.sublist(recentVoids.length - maxRecentVoids)
        : (recentVoids ?? this.recentVoids);
    return SalesmanSiBookletState(
      salesmanId: salesmanId ?? this.salesmanId,
      companyId: companyId ?? this.companyId,
      revision: revision ?? this.revision,
      booklets: sorted,
      recentVoids: trimmedVoids,
      updatedAt: updatedAt ?? this.updatedAt,
      hasPendingSync: hasPendingSync ?? this.hasPendingSync,
    );
  }

  factory SalesmanSiBookletState.fromMap(
    Map<String, dynamic> data, {
    required String salesmanId,
  }) {
    final rawBooklets = (data['booklets'] as List<dynamic>?) ?? const [];
    final parsedBooklets = rawBooklets
        .whereType<Map<String, dynamic>>()
        .map(SiBooklet.fromMap)
        .toList()
      ..sort((a, b) => a.startNumber.compareTo(b.startNumber));

    final rawVoids = (data['recentVoids'] as List<dynamic>?) ?? const [];
    final parsedVoids = rawVoids
        .whereType<Map<String, dynamic>>()
        .map(SiVoidEntry.fromMap)
        .toList();

    return SalesmanSiBookletState(
      salesmanId: (data['salesmanId'] as String?)?.trim().isNotEmpty == true
          ? (data['salesmanId'] as String).trim()
          : salesmanId,
      companyId: ((data['company_ID'] ?? data['companyId']) as String?)?.trim(),
      revision: (data['revision'] as num?)?.toInt() ?? 0,
      booklets: parsedBooklets,
      recentVoids: parsedVoids,
      updatedAt: _parseSiDateTime(data['updatedAt']) ?? DateTime.now(),
      hasPendingSync: data['hasPendingSync'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toFirestoreMap() {
    final trimmedVoids = recentVoids.length > maxRecentVoids
        ? recentVoids.sublist(recentVoids.length - maxRecentVoids)
        : recentVoids;
    return {
      'salesmanId': salesmanId,
      if (companyId != null && companyId!.isNotEmpty) 'company_ID': companyId,
      'revision': revision,
      'booklets': sortedBooklets.map((b) => b.toFirestoreMap()).toList(),
      'recentVoids': trimmedVoids.map((v) => v.toFirestoreMap()).toList(),
      'updatedAt': updatedAt,
    };
  }

  Map<String, dynamic> toLocalJson() {
    final trimmedVoids = recentVoids.length > maxRecentVoids
        ? recentVoids.sublist(recentVoids.length - maxRecentVoids)
        : recentVoids;
    return {
      'salesmanId': salesmanId,
      if (companyId != null && companyId!.isNotEmpty) 'company_ID': companyId,
      'revision': revision,
      'booklets': sortedBooklets.map((b) => b.toLocalJson()).toList(),
      'recentVoids': trimmedVoids.map((v) => v.toLocalJson()).toList(),
      'updatedAt': updatedAt.millisecondsSinceEpoch,
      'hasPendingSync': hasPendingSync,
    };
  }
}

/// Lightweight entry in `si_booklet_registry/{companyId}` for 1-read company-wide
/// overlap checks and Encoder Home summaries.
class SiRegistryEntry {
  final String bookletId;
  final String salesmanId;
  final String? salesmanName;
  final int startNumber;
  final int endNumber;
  final int padWidth;
  final int nextNumber;

  const SiRegistryEntry({
    required this.bookletId,
    required this.salesmanId,
    this.salesmanName,
    required this.startNumber,
    required this.endNumber,
    required this.padWidth,
    required this.nextNumber,
  });

  int get totalPages =>
      endNumber >= startNumber ? (endNumber - startNumber + 1) : 0;

  int get remainingPages => (endNumber - nextNumber + 1).clamp(0, totalPages);

  bool get isExhausted => nextNumber > endNumber;

  String get startFormatted => formatSiNumber(startNumber, padWidth);
  String get endFormatted => formatSiNumber(endNumber, padWidth);
  String? get nextFormatted =>
      isExhausted ? null : formatSiNumber(nextNumber, padWidth);

  bool overlapsRange(int otherStart, int otherEnd) =>
      startNumber <= otherEnd && otherStart <= endNumber;

  factory SiRegistryEntry.fromMap(
    Map<String, dynamic> data, {
    required String bookletId,
  }) {
    final start = (data['startNumber'] as num?)?.toInt() ?? 0;
    final end = (data['endNumber'] as num?)?.toInt() ?? start;
    return SiRegistryEntry(
      bookletId: bookletId,
      salesmanId: (data['salesmanId'] as String? ?? '').trim(),
      salesmanName: (data['salesmanName'] as String?)?.trim(),
      startNumber: start,
      endNumber: end,
      padWidth: (data['padWidth'] as num?)?.toInt() ??
          start.toString().length,
      nextNumber: (data['nextNumber'] as num?)?.toInt() ?? start,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'salesmanId': salesmanId,
      if (salesmanName != null && salesmanName!.isNotEmpty)
        'salesmanName': salesmanName,
      'startNumber': startNumber,
      'endNumber': endNumber,
      'padWidth': padWidth,
      'nextNumber': nextNumber,
    };
  }
}

class CompanySiRegistry {
  final String companyId;
  final Map<String, SiRegistryEntry> entries;

  const CompanySiRegistry({
    required this.companyId,
    this.entries = const {},
  });

  List<SiRegistryEntry> entriesForSalesman(String salesmanId) {
    final list = entries.values
        .where((e) => e.salesmanId == salesmanId)
        .toList()
      ..sort((a, b) => a.startNumber.compareTo(b.startNumber));
    return list;
  }

  /// Returns the first existing entry overlapping [startNumber..endNumber],
  /// optionally excluding [excludeBookletId] when editing an existing booklet.
  SiRegistryEntry? findOverlap(
    int startNumber,
    int endNumber, {
    String? excludeBookletId,
  }) {
    for (final entry in entries.values) {
      if (excludeBookletId != null && entry.bookletId == excludeBookletId) {
        continue;
      }
      if (entry.overlapsRange(startNumber, endNumber)) {
        return entry;
      }
    }
    return null;
  }

  factory CompanySiRegistry.fromMap(
    Map<String, dynamic> data, {
    required String companyId,
  }) {
    final raw = (data['entries'] as Map<String, dynamic>?) ?? const {};
    final parsed = <String, SiRegistryEntry>{};
    raw.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        parsed[key] = SiRegistryEntry.fromMap(value, bookletId: key);
      }
    });
    return CompanySiRegistry(companyId: companyId, entries: parsed);
  }

  Map<String, dynamic> toFirestoreMap() {
    return {
      'company_ID': companyId,
      'entries': {
        for (final e in entries.entries) e.key: e.value.toMap(),
      },
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}
