import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/services/export_file_saver/export_file_saver.dart';

class AgileExportResult {
  final String outputPath;
  final String fileName;
  final int rowCount;

  const AgileExportResult({
    required this.outputPath,
    required this.fileName,
    required this.rowCount,
  });
}

class AgileExportService {
  AgileExportService({FirestoreService? firestoreService})
    : _firestoreService = firestoreService ?? FirestoreService();

  final FirestoreService _firestoreService;

  Future<AgileExportResult> exportSupervisorAgile({
    required AppUser supervisor,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final start = DateFormat('yyyy-MM-dd').format(startDate);
    final end = DateFormat('yyyy-MM-dd').format(endDate);

    final results = await Future.wait([
      _firestoreService.getSupervisorTeam(supervisor.uid),
      _firestoreService.getRoutesForSupervisorByDateRange(
        supervisorId: supervisor.uid,
        startDate: start,
        endDate: end,
      ),
      _firestoreService.getAgileTargetsForSupervisorByDateRange(
        supervisorId: supervisor.uid,
        startDate: start,
        endDate: end,
      ),
      _firestoreService.getAgileSubmissionsForSupervisorByDateRange(
        supervisorId: supervisor.uid,
        startDate: start,
        endDate: end,
      ),
    ]);

    final team = results[0] as List<AppUser>;
    final routes = results[1] as List<SalesRoute>;
    final targets = results[2] as Map<String, AgileTarget>;
    final submissions = results[3] as Map<String, AgileSubmission>;

    final teamById = {for (final salesman in team) salesman.uid: salesman};
    final rows = _buildRows(
      teamById: teamById,
      routeByKey: _latestRouteByKey(routes),
      targetsByKey: targets,
      submissionsByKey: submissions,
    );

    if (rows.isEmpty) {
      throw StateError('No Agile dataset found for the selected date range.');
    }

    final workbook = _buildWorkbook(rows);
    final rangeLabel = _formatRangeLabel(startDate, endDate);
    final supervisorName = _displayName(supervisor);
    final fileName = '${_sanitizeFileName(supervisorName)} - $rangeLabel.xlsx';
    final outputPath = await _saveToDownloads(fileName, workbook);

    return AgileExportResult(
      outputPath: outputPath,
      fileName: fileName,
      rowCount: rows.length,
    );
  }

  Future<AgileExportResult> exportSuperuserAgileZip({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final start = DateFormat('yyyy-MM-dd').format(startDate);
    final end = DateFormat('yyyy-MM-dd').format(endDate);

    final results = await Future.wait([
      _firestoreService.getUsersByRole(UserRole.supervisor),
      _firestoreService.getUsersByRole(UserRole.salesman),
      _firestoreService.getAllRoutesByDateRange(startDate: start, endDate: end),
      _firestoreService.getAgileTargetsByDateRange(
        startDate: start,
        endDate: end,
      ),
      _firestoreService.getAllAgileSubmissionsByDateRange(
        startDate: start,
        endDate: end,
      ),
    ]);

    final supervisors = results[0] as List<AppUser>;
    final salesmen = results[1] as List<AppUser>;
    final allRoutes = results[2] as List<SalesRoute>;
    final targets = results[3] as Map<String, AgileTarget>;
    final submissions = results[4] as Map<String, AgileSubmission>;

    final salesmenBySupervisor = <String, Map<String, AppUser>>{};
    for (final salesman in salesmen) {
      final supervisorId = salesman.supervisorId;
      if (supervisorId == null || supervisorId.isEmpty) continue;
      salesmenBySupervisor.putIfAbsent(supervisorId, () => {});
      salesmenBySupervisor[supervisorId]![salesman.uid] = salesman;
    }

    final routesBySupervisor = <String, List<SalesRoute>>{};
    for (final route in allRoutes) {
      routesBySupervisor.putIfAbsent(route.supervisorId, () => []);
      routesBySupervisor[route.supervisorId]!.add(route);
    }

    final archive = Archive();
    var totalRows = 0;

    for (final supervisor in supervisors) {
      final teamById = salesmenBySupervisor[supervisor.uid] ?? {};
      final supervisorRoutes = routesBySupervisor[supervisor.uid] ?? const [];
      final routeByKey = _latestRouteByKey(supervisorRoutes);

      final scopedTargets = <String, AgileTarget>{};
      final scopedSubmissions = <String, AgileSubmission>{};

      for (final entry in targets.entries) {
        if (entry.value.supervisorId == supervisor.uid) {
          scopedTargets[entry.key] = entry.value;
        }
      }
      for (final entry in submissions.entries) {
        if (entry.value.supervisorId == supervisor.uid) {
          scopedSubmissions[entry.key] = entry.value;
        }
      }

      final rows = _buildRows(
        teamById: teamById,
        routeByKey: routeByKey,
        targetsByKey: scopedTargets,
        submissionsByKey: scopedSubmissions,
      );

      if (rows.isEmpty) {
        continue;
      }

      final workbookBytes = _buildWorkbook(rows);
      final supervisorFileName =
          '${_sanitizeFileName(_displayName(supervisor))} - ${_formatRangeLabel(startDate, endDate)}.xlsx';

      archive.addFile(
        ArchiveFile(supervisorFileName, workbookBytes.length, workbookBytes),
      );

      totalRows += rows.length;
    }

    if (archive.isEmpty) {
      throw StateError('No Agile dataset found for the selected date range.');
    }

    final zipName = 'KENEA_Agil_${_formatRangeLabel(startDate, endDate)}.zip';
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw StateError('Unable to generate Agile zip export.');
    }

    final outputPath = await _saveToDownloads(
      zipName,
      Uint8List.fromList(zipBytes),
    );

    return AgileExportResult(
      outputPath: outputPath,
      fileName: zipName,
      rowCount: totalRows,
    );
  }

  Map<String, SalesRoute> _latestRouteByKey(List<SalesRoute> routes) {
    final routeByKey = <String, SalesRoute>{};

    DateTime sortTime(SalesRoute route) {
      if (route.hasLastCall) return route.last.timestamp;
      if (route.hasFirstCall) return route.first.timestamp;
      if (route.sortedCheckpoints.isNotEmpty) {
        return route.sortedCheckpoints.last.timestamp;
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    for (final route in routes) {
      final key = '${route.date}_${route.salesmanId}';
      final existing = routeByKey[key];
      if (existing == null || sortTime(route).isAfter(sortTime(existing))) {
        routeByKey[key] = route;
      }
    }

    return routeByKey;
  }

  List<_AgileExportRow> _buildRows({
    required Map<String, AppUser> teamById,
    required Map<String, SalesRoute> routeByKey,
    required Map<String, AgileTarget> targetsByKey,
    required Map<String, AgileSubmission> submissionsByKey,
  }) {
    final keys = <String>{
      ...routeByKey.keys,
      ...targetsByKey.keys,
      ...submissionsByKey.keys,
    };

    for (final salesmanId in teamById.keys) {
      final hasAnyKey = keys.any((key) => key.endsWith('_$salesmanId'));
      if (!hasAnyKey) {
        // Keep rows focused on dates that actually have inputs.
        continue;
      }
    }

    final orderedKeys = keys.toList()..sort();
    final rows = <_AgileExportRow>[];

    for (final key in orderedKeys) {
      final target = targetsByKey[key];
      final submission = submissionsByKey[key];
      final route = routeByKey[key];
      final salesmanId =
          target?.salesmanId ?? submission?.salesmanId ?? route?.salesmanId;

      if (salesmanId == null || salesmanId.isEmpty) {
        continue;
      }

      final salesman = teamById[salesmanId];
      final dateText = _dateFromDocKey(key);
      if (dateText == null) {
        continue;
      }

      rows.add(
        _AgileExportRow(
          date: dateText,
          salesmanId: salesmanId,
          salesmanEmail: salesman?.email ?? '',
          salesmanName: _displayName(salesman, fallback: salesmanId),
          firstCall: route != null && route.hasFirstCall
              ? _formatTime(route.first.timestamp)
              : '--',
          lastCall: route != null && route.hasLastCall
              ? _formatTime(route.last.timestamp)
              : '--',
          routeTotalCalls: route == null
              ? 0
              : (route.hasFirstCall ? 1 : 0) +
                    (route.hasLastCall ? 1 : 0) +
                    route.sortedCheckpoints.length,
          productiveCallsTarget: target?.productiveCallsTarget ?? 0,
          actualProductiveCalls: submission?.productiveCalls ?? 0,
          sttTarget: target?.sttTarget ?? 0.0,
          actualStt: submission?.sttActual ?? 0.0,
        ),
      );
    }

    return rows;
  }

  Uint8List _buildWorkbook(List<_AgileExportRow> rows) {
    final excel = Excel.createExcel();
    final sheet = excel['Agile'];

    sheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('Salesman ID'),
      TextCellValue('Salesman Email'),
      TextCellValue('Salesman Name'),
      TextCellValue('First Call'),
      TextCellValue('Last Call'),
      TextCellValue('Route Total Calls'),
      TextCellValue('Productive Calls Target'),
      TextCellValue('Actual Productive Calls'),
      TextCellValue('STT Target'),
      TextCellValue('Actual STT'),
    ]);

    for (final row in rows) {
      sheet.appendRow([
        TextCellValue(row.date),
        TextCellValue(row.salesmanId),
        TextCellValue(row.salesmanEmail),
        TextCellValue(row.salesmanName),
        TextCellValue(row.firstCall),
        TextCellValue(row.lastCall),
        TextCellValue('${row.routeTotalCalls}'),
        TextCellValue('${row.productiveCallsTarget}'),
        TextCellValue('${row.actualProductiveCalls}'),
        TextCellValue(row.sttTarget.toStringAsFixed(2)),
        TextCellValue(row.actualStt.toStringAsFixed(2)),
      ]);
    }

    excel.setDefaultSheet('Agile');
    final bytes = excel.encode();
    if (bytes == null) {
      throw StateError('Unable to generate Agile workbook.');
    }

    return Uint8List.fromList(bytes);
  }

  Future<String> _saveToDownloads(String fileName, Uint8List bytes) async {
    return saveExportFile(fileName, bytes);
  }

  String _formatRangeLabel(DateTime startDate, DateTime endDate) {
    final short = DateFormat('yyyyMMdd');
    final start = short.format(startDate);
    final end = short.format(endDate);
    return start == end ? start : '${start}_to_$end';
  }

  String _formatTime(DateTime dateTime) {
    return DateFormat('hh:mm a').format(dateTime);
  }

  String? _dateFromDocKey(String key) {
    final underscoreIndex = key.indexOf('_');
    if (underscoreIndex <= 0) return null;

    final rawDate = key.substring(0, underscoreIndex);
    try {
      final parsed = DateTime.parse(rawDate);
      return DateFormat('MM/dd/yyyy').format(parsed);
    } catch (_) {
      return null;
    }
  }

  String _displayName(AppUser? user, {String fallback = 'Unknown'}) {
    if (user == null) return fallback;
    final trimmedName = user.name?.trim() ?? '';
    if (trimmedName.isNotEmpty) return trimmedName;
    if (user.email.trim().isNotEmpty) return user.email.trim();
    return fallback;
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  }
}

class _AgileExportRow {
  final String date;
  final String salesmanId;
  final String salesmanEmail;
  final String salesmanName;
  final String firstCall;
  final String lastCall;
  final int routeTotalCalls;
  final int productiveCallsTarget;
  final int actualProductiveCalls;
  final double sttTarget;
  final double actualStt;

  const _AgileExportRow({
    required this.date,
    required this.salesmanId,
    required this.salesmanEmail,
    required this.salesmanName,
    required this.firstCall,
    required this.lastCall,
    required this.routeTotalCalls,
    required this.productiveCallsTarget,
    required this.actualProductiveCalls,
    required this.sttTarget,
    required this.actualStt,
  });
}
