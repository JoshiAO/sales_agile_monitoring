import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';

class ArchiveResult {
  final String zipPath;
  final String zipFileName;
  final String workbookFileName;
  final String startDate;
  final String endDate;
  final int routeCount;
  final int imageCount;
  final List<String> dateFolders;

  const ArchiveResult({
    required this.zipPath,
    required this.zipFileName,
    required this.workbookFileName,
    required this.startDate,
    required this.endDate,
    required this.routeCount,
    required this.imageCount,
    required this.dateFolders,
  });
}

class ArchiveService {
  ArchiveService({
    FirestoreService? firestoreService,
    StorageService? storageService,
    http.Client? httpClient,
  })  : _firestoreService = firestoreService ?? FirestoreService(),
        _storageService = storageService ?? StorageService(),
        _httpClient = httpClient ?? http.Client();

  final FirestoreService _firestoreService;
  final StorageService _storageService;
  final http.Client _httpClient;

  Future<ArchiveResult> archiveRoutes({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final start = DateFormat('yyyy-MM-dd').format(startDate);
    final end = DateFormat('yyyy-MM-dd').format(endDate);

    final routes = await _firestoreService.getAllRoutesByDateRange(
      startDate: start,
      endDate: end,
    );

    if (routes.isEmpty) {
      throw StateError('No routes found for the selected archive range.');
    }

    routes.sort((left, right) {
      final dateCompare = left.date.compareTo(right.date);
      if (dateCompare != 0) return dateCompare;
      return left.salesmanId.compareTo(right.salesmanId);
    });

    final users = await _firestoreService.getAllUsers();
    final usersById = {for (final user in users) user.uid: user};

    final archive = Archive();
    final exportedImageUrls = <String>{};
    var imageCount = 0;

    for (final route in routes) {
      final salesman = usersById[route.salesmanId];
      final salesmanFolder = _sanitizeFileName(
        _displayName(salesman, fallback: route.salesmanId),
      );
      final dateFolder = route.date;
      final baseFolder = '$dateFolder/$salesmanFolder';

      imageCount += await _tryAddImage(
        archive: archive,
        filePath:
            '$baseFolder/${_buildImageName(route: route, isFirst: true)}.jpg',
        imageUrl: route.first.imageUrl,
        exportedImageUrls: exportedImageUrls,
      );

      if (route.hasLastCall) {
        imageCount += await _tryAddImage(
          archive: archive,
          filePath:
              '$baseFolder/${_buildImageName(route: route, isFirst: false)}.jpg',
          imageUrl: route.last.imageUrl,
          exportedImageUrls: exportedImageUrls,
        );
      }
    }

    final workbookName = 'routes_$start${start == end ? '' : '_to_$end'}.xlsx';
    final workbookBytes = _buildWorkbook(
      startDate: start,
      endDate: end,
      routes: routes,
      usersById: usersById,
    );
    archive.addFile(
      ArchiveFile(
        workbookName,
        workbookBytes.length,
        workbookBytes,
      ),
    );

    final outputDir = await _resolveArchiveDirectory();
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    final zipName = 'archive_$start${start == end ? '' : '_to_$end'}.zip';
    final zipPath = '${outputDir.path}/$zipName';
    final zipFile = File(zipPath);
    final encodedZip = ZipEncoder().encode(archive);
    if (encodedZip == null) {
      throw StateError('Unable to generate archive zip file.');
    }
    await zipFile.writeAsBytes(encodedZip, flush: true);

    for (final imageUrl in exportedImageUrls) {
      await _storageService.deleteImage(imageUrl);
    }
    await _firestoreService.deleteRoutesByIds(
      routes.map((route) => route.routeId).toList(),
    );

    final dateFolders = routes
        .map((route) => route.date)
        .toSet()
        .toList()
      ..sort();

    return ArchiveResult(
      zipPath: zipPath,
      zipFileName: zipName,
      workbookFileName: workbookName,
      startDate: start,
      endDate: end,
      routeCount: routes.length,
      imageCount: imageCount,
      dateFolders: dateFolders,
    );
  }

  Future<int> _tryAddImage({
    required Archive archive,
    required String filePath,
    required String imageUrl,
    required Set<String> exportedImageUrls,
  }) async {
    if (imageUrl.isEmpty) return 0;

    try {
      final response = await _httpClient.get(Uri.parse(imageUrl));
      if (response.statusCode != 200) return 0;

      final bytes = response.bodyBytes;
      archive.addFile(ArchiveFile(filePath, bytes.length, bytes));
      exportedImageUrls.add(imageUrl);
      return 1;
    } catch (_) {
      return 0;
    }
  }

  Uint8List _buildWorkbook({
    required String startDate,
    required String endDate,
    required List<SalesRoute> routes,
    required Map<String, AppUser> usersById,
  }) {
    final excel = Excel.createExcel();
    final sheet = excel['Routes'];

    sheet.appendRow([
      TextCellValue('Archive Start'),
      TextCellValue(startDate),
      TextCellValue('Archive End'),
      TextCellValue(endDate),
    ]);
    sheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('Salesman Name'),
      TextCellValue('Salesman Email'),
      TextCellValue('Supervisor Name'),
      TextCellValue('Supervisor Email'),
      TextCellValue('Route ID'),
      TextCellValue('First Call Time'),
      TextCellValue('First Call Lat'),
      TextCellValue('First Call Lon'),
      TextCellValue('Last Call Time'),
      TextCellValue('Last Call Lat'),
      TextCellValue('Last Call Lon'),
      TextCellValue('Checkpoint Count'),
      TextCellValue('Distance Km'),
      TextCellValue('First Retake Requested'),
      TextCellValue('First Retake Approved'),
      TextCellValue('Last Retake Requested'),
      TextCellValue('Last Retake Approved'),
    ]);

    for (final route in routes) {
      final salesman = usersById[route.salesmanId];
      final supervisor = usersById[route.supervisorId];

      sheet.appendRow([
        TextCellValue(route.date),
        TextCellValue(_displayName(salesman, fallback: route.salesmanId)),
        TextCellValue(salesman?.email ?? ''),
        TextCellValue(_displayName(supervisor, fallback: route.supervisorId)),
        TextCellValue(supervisor?.email ?? ''),
        TextCellValue(route.routeId),
        TextCellValue(_formatDateTime(route.first.timestamp)),
        TextCellValue(route.first.lat.toStringAsFixed(6)),
        TextCellValue(route.first.lon.toStringAsFixed(6)),
        TextCellValue(route.hasLastCall ? _formatDateTime(route.last.timestamp) : ''),
        TextCellValue(route.hasLastCall ? route.last.lat.toStringAsFixed(6) : ''),
        TextCellValue(route.hasLastCall ? route.last.lon.toStringAsFixed(6) : ''),
        TextCellValue(route.sortedCheckpoints.length.toString()),
        TextCellValue(route.distanceKm.toStringAsFixed(2)),
        TextCellValue(route.firstRetakeRequested ? 'Yes' : 'No'),
        TextCellValue(route.firstRetakeApproved ? 'Yes' : 'No'),
        TextCellValue(route.lastRetakeRequested ? 'Yes' : 'No'),
        TextCellValue(route.lastRetakeApproved ? 'Yes' : 'No'),
      ]);
    }

    excel.setDefaultSheet('Routes');
    final bytes = excel.encode();
    if (bytes == null) {
      throw StateError('Unable to generate archive workbook.');
    }
    return Uint8List.fromList(bytes);
  }

  Future<Directory> _resolveArchiveDirectory() async {
    // Prefer public Downloads so users can immediately access archives.
    if (Platform.isAndroid) {
      final publicDownloads = Directory('/storage/emulated/0/Download');
      if (await publicDownloads.exists()) {
        return Directory('${publicDownloads.path}/compact_sales_archives');
      }
    }

    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        final windowsDownloads = Directory('$userProfile/Downloads');
        if (await windowsDownloads.exists()) {
          return Directory('${windowsDownloads.path}/compact_sales_archives');
        }
      }
    }

    try {
      final directories = await getExternalStorageDirectories(
        type: StorageDirectory.downloads,
      );
      final candidate = directories?.firstOrNull;
      if (candidate != null) {
        return Directory('${candidate.path}/compact_sales_archives');
      }
    } catch (_) {
      // Fallback below.
    }

    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/compact_sales_archives');
  }

  String _buildImageName({
    required SalesRoute route,
    required bool isFirst,
  }) {
    final timestamp = isFirst ? route.first.timestamp : route.last.timestamp;
    final prefix = isFirst ? 'first_call' : 'last_call';
    return '${prefix}_${DateFormat('yyyyMMdd_HHmmss').format(timestamp)}';
  }

  String _displayName(AppUser? user, {required String fallback}) {
    final name = user?.name?.trim();
    final fsName = user?.fsName?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (fsName != null && fsName.isNotEmpty) return fsName;
    final email = user?.email.trim();
    if (email != null && email.isNotEmpty) return email;
    return fallback;
  }

  String _formatDateTime(DateTime value) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(value);
  }

  String _sanitizeFileName(String value) {
    return value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
