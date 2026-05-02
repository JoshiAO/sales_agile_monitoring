import 'dart:typed_data';

import 'export_file_saver_io.dart'
    if (dart.library.html) 'export_file_saver_web.dart'
    as saver;

Future<String> saveExportFile(String fileName, Uint8List bytes) {
  return saver.saveExportFile(fileName, bytes);
}
