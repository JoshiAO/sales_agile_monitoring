import 'dart:typed_data';

import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/export_file_saver/export_file_saver.dart';
import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

class CallsGridExportResult {
  final String outputPath;
  final String fileName;
  final int rowCount;

  const CallsGridExportResult({
    required this.outputPath,
    required this.fileName,
    required this.rowCount,
  });
}

class CallsGridExportService {
  Future<CallsGridExportResult> exportWeeklyCallsGrid({
    required String supervisorName,
    required DateTime selectedMonth,
    required int selectedWeek,
    required List<DateTime> weekDays,
    required List<AppUser> orderedSalesmen,
    required Map<String, Map<String, SalesRoute>> routesBySalesmanByDate,
    required String filterLabel,
    required String sortLabel,
  }) async {
    final bytes = _buildWorkbook(
      supervisorName: supervisorName,
      selectedMonth: selectedMonth,
      selectedWeek: selectedWeek,
      weekDays: weekDays,
      orderedSalesmen: orderedSalesmen,
      routesBySalesmanByDate: routesBySalesmanByDate,
      filterLabel: filterLabel,
      sortLabel: sortLabel,
    );

    final safeSupervisor = _sanitizeFileName(supervisorName);
    final monthCode = DateFormat('yyyy_MMM').format(selectedMonth);
    final fileName =
        '${safeSupervisor}_Calls_Grid_${monthCode}_Week$selectedWeek.xlsx';
    final outputPath = await saveExportFile(fileName, bytes);

    return CallsGridExportResult(
      outputPath: outputPath,
      fileName: fileName,
      rowCount: orderedSalesmen.length,
    );
  }

  Uint8List _buildWorkbook({
    required String supervisorName,
    required DateTime selectedMonth,
    required int selectedWeek,
    required List<DateTime> weekDays,
    required List<AppUser> orderedSalesmen,
    required Map<String, Map<String, SalesRoute>> routesBySalesmanByDate,
    required String filterLabel,
    required String sortLabel,
  }) {
    const sheetName = 'Weekly Calls Grid';
    final excel = Excel.createExcel();
    excel.rename('Sheet1', sheetName);
    excel.setDefaultSheet(sheetName);
    final sheet = excel[sheetName];

    final borderSide = Border(
      borderStyle: BorderStyle.Thin,
      borderColorHex: ExcelColor.fromHexString('#9CA3AF'),
    );
    final headerBorderSide = Border(
      borderStyle: BorderStyle.Thin,
      borderColorHex: ExcelColor.fromHexString('#6B7280'),
    );

    final lastCol = 2 + (weekDays.length * 2) - 1; // Col P (index 15) for 7 days

    // Column widths
    sheet.setColumnWidth(0, 28); // Salesman Email
    sheet.setColumnWidth(1, 28); // Salesman Name
    for (int i = 2; i <= lastCol; i++) {
      sheet.setColumnWidth(i, 6.2); // F / L sub-columns
    }

    // ── Row 0: Title Banner ───────────────────────────────────────────────────
    sheet.setRowHeight(0, 28);
    final titleStart = CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0);
    final titleEnd = CellIndex.indexByColumnRow(columnIndex: lastCol, rowIndex: 0);
    sheet.merge(
      titleStart,
      titleEnd,
      customValue: TextCellValue('Calls View Report — $supervisorName'),
    );
    sheet.setMergedCellStyle(
      titleStart,
      CellStyle(
        backgroundColorHex: ExcelColor.fromHexString('#4F468F'),
        fontColorHex: ExcelColor.white,
        bold: true,
        fontSize: 13,
        horizontalAlign: HorizontalAlign.Left,
        verticalAlign: VerticalAlign.Center,
        leftBorder: headerBorderSide,
        rightBorder: headerBorderSide,
        topBorder: headerBorderSide,
        bottomBorder: headerBorderSide,
      ),
    );

    // ── Row 1: Filter / Sort / Month / Week Summary ───────────────────────────
    sheet.setRowHeight(1, 21);
    final monthStr = DateFormat('MMM yyyy').format(selectedMonth);
    final rangeStr =
        '${DateFormat('MMM d').format(weekDays.first)} - ${DateFormat('MMM d, yyyy').format(weekDays.last)}';
    final metaText =
        'Month: $monthStr   |   Week $selectedWeek ($rangeStr)   |   Filter: $filterLabel   |   Sort: $sortLabel   |   Salesmen: ${orderedSalesmen.length}';
    final metaStart = CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1);
    final metaEnd = CellIndex.indexByColumnRow(columnIndex: lastCol, rowIndex: 1);
    sheet.merge(metaStart, metaEnd, customValue: TextCellValue(metaText));
    sheet.setMergedCellStyle(
      metaStart,
      CellStyle(
        backgroundColorHex: ExcelColor.fromHexString('#EDE9FE'),
        fontColorHex: ExcelColor.fromHexString('#312E81'),
        bold: true,
        fontSize: 10,
        horizontalAlign: HorizontalAlign.Left,
        verticalAlign: VerticalAlign.Center,
        leftBorder: borderSide,
        rightBorder: borderSide,
        topBorder: borderSide,
        bottomBorder: borderSide,
      ),
    );

    // ── Row 2: Color & Symbol Legend ──────────────────────────────────────────
    sheet.setRowHeight(2, 20);
    final legendItems = <({int startCol, int endCol, String label, String bgHex, String fgHex})>[
      (
        startCol: 0,
        endCol: 0,
        label: 'Legend:',
        bgHex: '#F3F4F6',
        fgHex: '#374151',
      ),
      (
        startCol: 1,
        endCol: 1,
        label: '✓ Accomplished   |   ✕ Not Taken',
        bgHex: '#F3F4F6',
        fgHex: '#374151',
      ),
      (
        startCol: 2,
        endCol: 5,
        label: '✓✓ Completed (F & L)',
        bgHex: '#D1FAE5',
        fgHex: '#15803D',
      ),
      (
        startCol: 6,
        endCol: 9,
        label: '✓✕ 1 Call Only',
        bgHex: '#FEF3C7',
        fgHex: '#B45309',
      ),
      (
        startCol: 10,
        endCol: 12,
        label: '✕✕ No Calls',
        bgHex: '#FEE2E2',
        fgHex: '#B91C1C',
      ),
      (
        startCol: 13,
        endCol: 15,
        label: 'Upcoming',
        bgHex: '#E5E7EB',
        fgHex: '#4B5563',
      ),
    ];

    for (final item in legendItems) {
      final startIdx = CellIndex.indexByColumnRow(columnIndex: item.startCol, rowIndex: 2);
      final endIdx = CellIndex.indexByColumnRow(columnIndex: item.endCol, rowIndex: 2);
      final style = CellStyle(
        backgroundColorHex: ExcelColor.fromHexString(item.bgHex),
        fontColorHex: ExcelColor.fromHexString(item.fgHex),
        bold: true,
        fontSize: 9,
        horizontalAlign: item.startCol <= 1 ? HorizontalAlign.Left : HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        leftBorder: borderSide,
        rightBorder: borderSide,
        topBorder: borderSide,
        bottomBorder: borderSide,
      );
      if (item.startCol == item.endCol) {
        final cell = sheet.cell(startIdx);
        cell.value = TextCellValue(item.label);
        cell.cellStyle = style;
      } else {
        sheet.merge(startIdx, endIdx, customValue: TextCellValue(item.label));
        sheet.setMergedCellStyle(startIdx, style);
      }
    }

    // ── Row 3: Spacer ─────────────────────────────────────────────────────────
    sheet.setRowHeight(3, 8);

    // ── Rows 4..6: 3-Tier Table Header ────────────────────────────────────────
    sheet.setRowHeight(4, 20);
    sheet.setRowHeight(5, 20);
    sheet.setRowHeight(6, 19);

    final headerBg = ExcelColor.fromHexString('#E8E5F8');
    final todayHeaderBg = ExcelColor.fromHexString('#D8D0F5');
    final subHeaderBg = ExcelColor.fromHexString('#F3F1FC');
    final headerTextColor = ExcelColor.fromHexString('#1E1B4B');

    final emailHeaderStart = CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 4);
    final emailHeaderEnd = CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 6);
    sheet.merge(emailHeaderStart, emailHeaderEnd, customValue: TextCellValue('Salesman Email'));
    sheet.setMergedCellStyle(
      emailHeaderStart,
      CellStyle(
        backgroundColorHex: headerBg,
        fontColorHex: headerTextColor,
        bold: true,
        fontSize: 11,
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        leftBorder: headerBorderSide,
        rightBorder: headerBorderSide,
        topBorder: headerBorderSide,
        bottomBorder: headerBorderSide,
      ),
    );

    final nameHeaderStart = CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 4);
    final nameHeaderEnd = CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 6);
    sheet.merge(nameHeaderStart, nameHeaderEnd, customValue: TextCellValue('Salesman Name'));
    sheet.setMergedCellStyle(
      nameHeaderStart,
      CellStyle(
        backgroundColorHex: headerBg,
        fontColorHex: headerTextColor,
        bold: true,
        fontSize: 11,
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        leftBorder: headerBorderSide,
        rightBorder: headerBorderSide,
        topBorder: headerBorderSide,
        bottomBorder: headerBorderSide,
      ),
    );

    final now = DateTime.now();
    final todayDateOnly = DateTime(now.year, now.month, now.day);
    final dayNameFmt = DateFormat('EEE');
    final dateKeyFmt = DateFormat('yyyy-MM-dd');

    for (int d = 0; d < weekDays.length; d++) {
      final day = weekDays[d];
      final dateOnly = DateTime(day.year, day.month, day.day);
      final isToday = dateOnly == todayDateOnly;
      final cF = 2 + (d * 2);
      final cL = cF + 1;
      final dayBg = isToday ? todayHeaderBg : headerBg;

      // Day Name (Sun..Sat)
      final dayNameStart = CellIndex.indexByColumnRow(columnIndex: cF, rowIndex: 4);
      final dayNameEnd = CellIndex.indexByColumnRow(columnIndex: cL, rowIndex: 4);
      sheet.merge(
        dayNameStart,
        dayNameEnd,
        customValue: TextCellValue(dayNameFmt.format(day)),
      );
      sheet.setMergedCellStyle(
        dayNameStart,
        CellStyle(
          backgroundColorHex: dayBg,
          fontColorHex: headerTextColor,
          bold: true,
          fontSize: 10,
          horizontalAlign: HorizontalAlign.Center,
          verticalAlign: VerticalAlign.Center,
          leftBorder: headerBorderSide,
          rightBorder: headerBorderSide,
          topBorder: headerBorderSide,
          bottomBorder: borderSide,
        ),
      );

      // Day Number (1..31)
      final dayNumStart = CellIndex.indexByColumnRow(columnIndex: cF, rowIndex: 5);
      final dayNumEnd = CellIndex.indexByColumnRow(columnIndex: cL, rowIndex: 5);
      sheet.merge(
        dayNumStart,
        dayNumEnd,
        customValue: IntCellValue(day.day),
      );
      sheet.setMergedCellStyle(
        dayNumStart,
        CellStyle(
          backgroundColorHex: isToday ? todayHeaderBg : subHeaderBg,
          fontColorHex: headerTextColor,
          bold: true,
          fontSize: 10,
          horizontalAlign: HorizontalAlign.Center,
          verticalAlign: VerticalAlign.Center,
          leftBorder: headerBorderSide,
          rightBorder: headerBorderSide,
          topBorder: borderSide,
          bottomBorder: borderSide,
        ),
      );

      // F | L Sub-headers
      final fCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: cF, rowIndex: 6));
      fCell.value = TextCellValue('F');
      fCell.cellStyle = CellStyle(
        backgroundColorHex: subHeaderBg,
        fontColorHex: ExcelColor.fromHexString('#374151'),
        bold: true,
        fontSize: 10,
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        leftBorder: headerBorderSide,
        rightBorder: borderSide,
        topBorder: borderSide,
        bottomBorder: headerBorderSide,
      );

      final lCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: cL, rowIndex: 6));
      lCell.value = TextCellValue('L');
      lCell.cellStyle = CellStyle(
        backgroundColorHex: subHeaderBg,
        fontColorHex: ExcelColor.fromHexString('#374151'),
        bold: true,
        fontSize: 10,
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        leftBorder: borderSide,
        rightBorder: headerBorderSide,
        topBorder: borderSide,
        bottomBorder: headerBorderSide,
      );
    }

    // ── Prebuilt Cell Styles for Data Rows ────────────────────────────────────
    final completedBg = ExcelColor.fromHexString('#D1FAE5');
    final partialBg = ExcelColor.fromHexString('#FEF3C7');
    final missedBg = ExcelColor.fromHexString('#FEE2E2');
    final futureBg = ExcelColor.fromHexString('#E5E7EB');

    final checkColor = ExcelColor.fromHexString('#15803D');
    final crossColor = ExcelColor.fromHexString('#B91C1C');
    final futureColor = ExcelColor.fromHexString('#6B7280');

    CellStyle buildIndicatorStyle({
      required ExcelColor bg,
      required ExcelColor fg,
      required bool isLeftSubCol,
    }) {
      return CellStyle(
        backgroundColorHex: bg,
        fontColorHex: fg,
        bold: true,
        fontSize: 11,
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        leftBorder: isLeftSubCol ? headerBorderSide : borderSide,
        rightBorder: isLeftSubCol ? borderSide : headerBorderSide,
        topBorder: borderSide,
        bottomBorder: borderSide,
      );
    }

    // ── Data Rows (Row 7+) ────────────────────────────────────────────────────
    for (int i = 0; i < orderedSalesmen.length; i++) {
      final rowIdx = 7 + i;
      sheet.setRowHeight(rowIdx, 21);

      final salesman = orderedSalesmen[i];
      final displayName = (salesman.name?.trim().isNotEmpty == true)
          ? salesman.name!.trim()
          : salesman.email;
      final rowBg = ExcelColor.fromHexString(i.isEven ? '#FFFFFF' : '#FAF9FE');

      final emailCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIdx));
      emailCell.value = TextCellValue(salesman.email);
      emailCell.cellStyle = CellStyle(
        backgroundColorHex: rowBg,
        fontColorHex: ExcelColor.fromHexString('#1F2937'),
        fontSize: 10,
        horizontalAlign: HorizontalAlign.Left,
        verticalAlign: VerticalAlign.Center,
        leftBorder: headerBorderSide,
        rightBorder: borderSide,
        topBorder: borderSide,
        bottomBorder: borderSide,
      );

      final nameCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIdx));
      nameCell.value = TextCellValue(displayName);
      nameCell.cellStyle = CellStyle(
        backgroundColorHex: rowBg,
        fontColorHex: ExcelColor.fromHexString('#111827'),
        bold: true,
        fontSize: 10,
        horizontalAlign: HorizontalAlign.Left,
        verticalAlign: VerticalAlign.Center,
        leftBorder: borderSide,
        rightBorder: headerBorderSide,
        topBorder: borderSide,
        bottomBorder: borderSide,
      );

      final byDate = routesBySalesmanByDate[salesman.uid] ?? const <String, SalesRoute>{};
      for (int d = 0; d < weekDays.length; d++) {
        final day = weekDays[d];
        final dateOnly = DateTime(day.year, day.month, day.day);
        final isFuture = dateOnly.isAfter(todayDateOnly);
        final route = byDate[dateKeyFmt.format(day)];
        final hasFirst = !isFuture && route != null && route.hasFirstCall;
        final hasLast = !isFuture && route != null && route.hasLastCall;

        late final ExcelColor dayBg;
        if (isFuture) {
          dayBg = futureBg;
        } else if (hasFirst && hasLast) {
          dayBg = completedBg;
        } else if (hasFirst || hasLast) {
          dayBg = partialBg;
        } else {
          dayBg = missedBg;
        }

        final cF = 2 + (d * 2);
        final cL = cF + 1;

        final fCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: cF, rowIndex: rowIdx));
        fCell.value = TextCellValue(isFuture ? '' : (hasFirst ? '✓' : '✕'));
        fCell.cellStyle = buildIndicatorStyle(
          bg: dayBg,
          fg: isFuture ? futureColor : (hasFirst ? checkColor : crossColor),
          isLeftSubCol: true,
        );

        final lCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: cL, rowIndex: rowIdx));
        lCell.value = TextCellValue(isFuture ? '' : (hasLast ? '✓' : '✕'));
        lCell.cellStyle = buildIndicatorStyle(
          bg: dayBg,
          fg: isFuture ? futureColor : (hasLast ? checkColor : crossColor),
          isLeftSubCol: false,
        );
      }
    }

    final encoded = excel.encode();
    if (encoded == null) {
      throw StateError('Unable to encode Weekly Calls Grid Excel workbook.');
    }
    return Uint8List.fromList(encoded);
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  }
}

