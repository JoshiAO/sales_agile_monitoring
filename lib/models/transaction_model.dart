import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/services/si_series_engine.dart';

DateTime? _parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is Timestamp) return value.toDate();
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Formats numeric quantities cleanly without unnecessary trailing `.0`.
String formatQuantity(double qty) {
  if ((qty - qty.roundToDouble()).abs() < 0.0001) {
    return qty.round().toString();
  }
  return qty.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Normalizes SFA UOM strings (`Piece`, `Case`, `Sub Case`, etc.) to standard codes.
String normalizeUom(String rawUom) {
  final cleaned = rawUom.trim().toUpperCase().replaceAll(RegExp(r'[\s\-_]+'), '');
  switch (cleaned) {
    case 'PC':
    case 'PCS':
    case 'PIECE':
    case 'PIECES':
    case 'PCE':
      return 'PC';
    case 'CS':
    case 'CASE':
    case 'CASES':
      return 'CS';
    case 'SC':
    case 'SUBCASE':
    case 'SUBCASES':
      return 'SC';
    default:
      return rawUom.trim().toUpperCase();
  }
}

class InvoiceLineItem {
  final int sequence;
  final int pageNo;
  final String code;
  final String description;
  final double qty;
  final String uom;
  final double unitPrice;
  final double totalAmount;

  const InvoiceLineItem({
    required this.sequence,
    required this.pageNo,
    required this.code,
    required this.description,
    required this.qty,
    required this.uom,
    required this.unitPrice,
    required this.totalAmount,
  });

  String get formattedDescription =>
      code.trim().isEmpty ? description.trim() : '${code.trim()} - ${description.trim()}';

  String get formattedQty {
    final qtyText = formatQuantity(qty);
    final uomText = uom.trim();
    return uomText.isEmpty ? qtyText : '$qtyText $uomText';
  }

  InvoiceLineItem copyWith({
    int? sequence,
    int? pageNo,
    String? code,
    String? description,
    double? qty,
    String? uom,
    double? unitPrice,
    double? totalAmount,
  }) {
    return InvoiceLineItem(
      sequence: sequence ?? this.sequence,
      pageNo: pageNo ?? this.pageNo,
      code: code ?? this.code,
      description: description ?? this.description,
      qty: qty ?? this.qty,
      uom: uom ?? this.uom,
      unitPrice: unitPrice ?? this.unitPrice,
      totalAmount: totalAmount ?? this.totalAmount,
    );
  }

  factory InvoiceLineItem.fromMap(Map<String, dynamic> data) {
    return InvoiceLineItem(
      sequence: (data['sequence'] as num?)?.toInt() ?? 1,
      pageNo: (data['pageNo'] as num?)?.toInt() ?? 1,
      code: (data['code'] as String? ?? '').trim(),
      description: (data['description'] as String? ?? '').trim(),
      qty: (data['qty'] as num?)?.toDouble() ?? 0.0,
      uom: normalizeUom(data['uom'] as String? ?? ''),
      unitPrice: (data['unitPrice'] as num?)?.toDouble() ?? 0.0,
      totalAmount: (data['totalAmount'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'sequence': sequence,
      'pageNo': pageNo,
      'code': code,
      'description': description,
      'qty': qty,
      'uom': uom,
      'unitPrice': unitPrice,
      'totalAmount': totalAmount,
    };
  }
}

class InvoicePageData {
  final int pageNo;
  final int totalPages;
  final List<InvoiceLineItem> items;
  final double totalAmountDue;
  final double vatableSales;
  final double vat;

  const InvoicePageData({
    required this.pageNo,
    required this.totalPages,
    required this.items,
    required this.totalAmountDue,
    required this.vatableSales,
    required this.vat,
  });
}

enum TransactionUploadStatus { pending, uploaded }

class RouteTransaction {
  final String transactionId;
  final String routeDate; // YYYY-MM-DD
  final String salesRepName;
  final String salesRepCode;
  final String customerName;
  final String customerCode;
  final String address;
  final String? tin;
  final String invoiceCode;
  final String invoiceDate;
  final List<InvoiceLineItem> items;
  final double csQty;
  final double scQty;
  final double pcQty;
  final double totalAmount;
  final double? printedGrandTotal;
  final int pageCount;

  // GPS & telemetry snapshot captured at commit time
  final double lat;
  final double lon;
  final double? accuracyMeters;
  final DateTime capturedAt;
  final int? batteryLevel;
  final bool? isMobileDataOn;
  final bool? isWifiOn;

  // Sales Invoice booklet series metadata
  final List<String?> pageSiNumbers;
  final List<SiVoidEntry> voidedSiEntries;
  final bool siConflict;
  final int siRevision;

  // Local-only sync metadata
  final TransactionUploadStatus uploadStatus;
  final String? uploadedRouteId;
  final bool needsRemoteUpdate;

  const RouteTransaction({
    required this.transactionId,
    required this.routeDate,
    required this.salesRepName,
    required this.salesRepCode,
    required this.customerName,
    required this.customerCode,
    required this.address,
    this.tin,
    required this.invoiceCode,
    required this.invoiceDate,
    required this.items,
    required this.csQty,
    required this.scQty,
    required this.pcQty,
    required this.totalAmount,
    this.printedGrandTotal,
    required this.pageCount,
    required this.lat,
    required this.lon,
    this.accuracyMeters,
    required this.capturedAt,
    this.batteryLevel,
    this.isMobileDataOn,
    this.isWifiOn,
    this.pageSiNumbers = const [],
    this.voidedSiEntries = const [],
    this.siConflict = false,
    this.siRevision = 0,
    this.uploadStatus = TransactionUploadStatus.uploaded,
    this.uploadedRouteId,
    this.needsRemoteUpdate = false,
  });

  bool get isUploaded => uploadStatus == TransactionUploadStatus.uploaded;

  bool get hasValidLocation => lat != 0.0 || lon != 0.0;

  bool get hasRoundingVariance {
    if (printedGrandTotal == null) return false;
    final diff = (totalAmount - printedGrandTotal!).abs();
    return diff > 0.005;
  }

  /// Returns the assigned SI series number for 1-based [pageNo], or null.
  String? siNumberForPage(int pageNo) {
    final idx = pageNo - 1;
    if (idx < 0 || idx >= pageSiNumbers.length) return null;
    final val = pageSiNumbers[idx]?.trim();
    return (val == null || val.isEmpty) ? null : val;
  }

  bool get hasAnySiAssigned =>
      pageSiNumbers.any((s) => s != null && s.trim().isNotEmpty);

  bool get hasMissingSiPages {
    final count = pageCount > 0 ? pageCount : 1;
    if (pageSiNumbers.length < count) return true;
    for (var i = 0; i < count; i++) {
      final v = pageSiNumbers[i]?.trim();
      if (v == null || v.isEmpty) return true;
    }
    return false;
  }

  int? get firstAssignedSiNumeric {
    for (final s in pageSiNumbers) {
      final parsed = int.tryParse(s?.trim() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  String get formattedSiSeriesSummary =>
      SiSeriesEngine.formatSeriesSummary(pageSiNumbers);

  String get formattedVoidedSiSummary =>
      SiSeriesEngine.formatVoidedSummary(voidedSiEntries);

  RouteTransaction copyWith({
    String? transactionId,
    String? routeDate,
    String? salesRepName,
    String? salesRepCode,
    String? customerName,
    String? customerCode,
    String? address,
    String? tin,
    String? invoiceCode,
    String? invoiceDate,
    List<InvoiceLineItem>? items,
    double? csQty,
    double? scQty,
    double? pcQty,
    double? totalAmount,
    double? printedGrandTotal,
    int? pageCount,
    double? lat,
    double? lon,
    double? accuracyMeters,
    DateTime? capturedAt,
    int? batteryLevel,
    bool? isMobileDataOn,
    bool? isWifiOn,
    List<String?>? pageSiNumbers,
    List<SiVoidEntry>? voidedSiEntries,
    bool? siConflict,
    int? siRevision,
    TransactionUploadStatus? uploadStatus,
    String? uploadedRouteId,
    bool? needsRemoteUpdate,
  }) {
    return RouteTransaction(
      transactionId: transactionId ?? this.transactionId,
      routeDate: routeDate ?? this.routeDate,
      salesRepName: salesRepName ?? this.salesRepName,
      salesRepCode: salesRepCode ?? this.salesRepCode,
      customerName: customerName ?? this.customerName,
      customerCode: customerCode ?? this.customerCode,
      address: address ?? this.address,
      tin: tin ?? this.tin,
      invoiceCode: invoiceCode ?? this.invoiceCode,
      invoiceDate: invoiceDate ?? this.invoiceDate,
      items: items ?? this.items,
      csQty: csQty ?? this.csQty,
      scQty: scQty ?? this.scQty,
      pcQty: pcQty ?? this.pcQty,
      totalAmount: totalAmount ?? this.totalAmount,
      printedGrandTotal: printedGrandTotal ?? this.printedGrandTotal,
      pageCount: pageCount ?? this.pageCount,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      accuracyMeters: accuracyMeters ?? this.accuracyMeters,
      capturedAt: capturedAt ?? this.capturedAt,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isMobileDataOn: isMobileDataOn ?? this.isMobileDataOn,
      isWifiOn: isWifiOn ?? this.isWifiOn,
      pageSiNumbers: pageSiNumbers ?? this.pageSiNumbers,
      voidedSiEntries: voidedSiEntries ?? this.voidedSiEntries,
      siConflict: siConflict ?? this.siConflict,
      siRevision: siRevision ?? this.siRevision,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      uploadedRouteId: uploadedRouteId ?? this.uploadedRouteId,
      needsRemoteUpdate: needsRemoteUpdate ?? this.needsRemoteUpdate,
    );
  }

  factory RouteTransaction.fromMap(
    Map<String, dynamic> data, {
    TransactionUploadStatus defaultUploadStatus = TransactionUploadStatus.uploaded,
  }) {
    final rawItems = (data['items'] as List<dynamic>?) ?? const [];
    final items = rawItems
        .whereType<Map<String, dynamic>>()
        .map(InvoiceLineItem.fromMap)
        .toList();

    final rawPageSi = (data['pageSiNumbers'] as List<dynamic>?) ?? const [];
    final pageSiNumbers = rawPageSi
        .map((e) {
          if (e == null) return null;
          final s = e.toString().trim();
          return s.isEmpty ? null : s;
        })
        .toList();

    final rawVoidedSi = (data['voidedSiEntries'] as List<dynamic>?) ?? const [];
    final voidedSiEntries = rawVoidedSi
        .whereType<Map<String, dynamic>>()
        .map(SiVoidEntry.fromMap)
        .toList();

    final statusStr = data['uploadStatus'] as String?;
    final status = statusStr == 'pending'
        ? TransactionUploadStatus.pending
        : (statusStr == 'uploaded'
            ? TransactionUploadStatus.uploaded
            : defaultUploadStatus);

    return RouteTransaction(
      transactionId: (data['transactionId'] as String? ?? '').trim(),
      routeDate: (data['routeDate'] as String? ?? '').trim(),
      salesRepName: (data['salesRepName'] as String? ?? '').trim(),
      salesRepCode: (data['salesRepCode'] as String? ?? '').trim(),
      customerName: (data['customerName'] as String? ?? '').trim(),
      customerCode: (data['customerCode'] as String? ?? '').trim(),
      address: (data['address'] as String? ?? '').trim(),
      tin: (data['tin'] as String?)?.trim(),
      invoiceCode: (data['invoiceCode'] as String? ?? '').trim(),
      invoiceDate: (data['invoiceDate'] as String? ?? '').trim(),
      items: items,
      csQty: (data['csQty'] as num?)?.toDouble() ?? 0.0,
      scQty: (data['scQty'] as num?)?.toDouble() ?? 0.0,
      pcQty: (data['pcQty'] as num?)?.toDouble() ?? 0.0,
      totalAmount: (data['totalAmount'] as num?)?.toDouble() ?? 0.0,
      printedGrandTotal: (data['printedGrandTotal'] as num?)?.toDouble(),
      pageCount: (data['pageCount'] as num?)?.toInt() ??
          (items.isEmpty ? 1 : ((items.length - 1) ~/ 9) + 1),
      lat: (data['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (data['lon'] as num?)?.toDouble() ?? 0.0,
      accuracyMeters: (data['accuracyMeters'] as num?)?.toDouble(),
      capturedAt: _parseDateTime(data['capturedAt']) ?? DateTime.now(),
      batteryLevel: (data['batteryLevel'] as num?)?.toInt(),
      isMobileDataOn: data['isMobileDataOn'] as bool?,
      isWifiOn: data['isWifiOn'] as bool?,
      pageSiNumbers: pageSiNumbers,
      voidedSiEntries: voidedSiEntries,
      siConflict: data['siConflict'] as bool? ?? false,
      siRevision: (data['siRevision'] as num?)?.toInt() ?? 0,
      uploadStatus: status,
      uploadedRouteId: data['uploadedRouteId'] as String?,
      needsRemoteUpdate: data['needsRemoteUpdate'] as bool? ?? false,
    );
  }

  /// Serializes only fields persisted to Firestore `routes/{routeId}.transactions`.
  Map<String, dynamic> toFirestoreMap() {
    return {
      'transactionId': transactionId,
      'routeDate': routeDate,
      'salesRepName': salesRepName,
      'salesRepCode': salesRepCode,
      'customerName': customerName,
      'customerCode': customerCode,
      'address': address,
      if (tin != null && tin!.isNotEmpty) 'tin': tin,
      'invoiceCode': invoiceCode,
      'invoiceDate': invoiceDate,
      'items': items.map((item) => item.toMap()).toList(),
      'csQty': csQty,
      'scQty': scQty,
      'pcQty': pcQty,
      'totalAmount': totalAmount,
      if (printedGrandTotal != null) 'printedGrandTotal': printedGrandTotal,
      'pageCount': pageCount,
      'lat': lat,
      'lon': lon,
      if (accuracyMeters != null) 'accuracyMeters': accuracyMeters,
      'capturedAt': capturedAt,
      if (batteryLevel != null) 'batteryLevel': batteryLevel,
      if (isMobileDataOn != null) 'isMobileDataOn': isMobileDataOn,
      if (isWifiOn != null) 'isWifiOn': isWifiOn,
      if (pageSiNumbers.isNotEmpty) 'pageSiNumbers': pageSiNumbers,
      if (voidedSiEntries.isNotEmpty)
        'voidedSiEntries': voidedSiEntries.map((v) => v.toFirestoreMap()).toList(),
      if (siConflict) 'siConflict': true,
      if (siRevision > 0) 'siRevision': siRevision,
    };
  }

  /// Serializes all fields including local sync status for JSON file storage.
  Map<String, dynamic> toLocalJson() {
    final map = toFirestoreMap();
    map['capturedAt'] = capturedAt.millisecondsSinceEpoch;
    if (voidedSiEntries.isNotEmpty) {
      map['voidedSiEntries'] =
          voidedSiEntries.map((v) => v.toLocalJson()).toList();
    }
    map['uploadStatus'] =
        uploadStatus == TransactionUploadStatus.pending ? 'pending' : 'uploaded';
    if (uploadedRouteId != null) {
      map['uploadedRouteId'] = uploadedRouteId;
    }
    if (needsRemoteUpdate) {
      map['needsRemoteUpdate'] = true;
    }
    return map;
  }
}

