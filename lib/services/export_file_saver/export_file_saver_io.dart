import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> saveExportFile(String fileName, Uint8List bytes) async {
  final outputDir = await _resolveDownloadsDirectory();
  if (!await outputDir.exists()) {
    await outputDir.create(recursive: true);
  }

  final outputPath = '${outputDir.path}/$fileName';
  await File(outputPath).writeAsBytes(bytes, flush: true);
  return outputPath;
}

Future<Directory> _resolveDownloadsDirectory() async {
  if (Platform.isAndroid) {
    final dir = Directory('/storage/emulated/0/Download');
    if (await dir.exists()) return dir;
  }

  if (Platform.isWindows) {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null && userProfile.isNotEmpty) {
      return Directory('$userProfile/Downloads');
    }
  }

  if (Platform.isMacOS || Platform.isLinux) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home/Downloads');
    }
  }

  return getApplicationDocumentsDirectory();
}
