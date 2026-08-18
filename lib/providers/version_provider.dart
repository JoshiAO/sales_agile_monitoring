import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class VersionProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();
  bool _isChecking = true;
  bool _isOutdated = false;
  String? _downloadUrl;
  String? _currentVersion;
  String? _latestVersion;

  bool get isChecking => _isChecking;
  bool get isOutdated => _isOutdated;
  String? get downloadUrl => _downloadUrl;
  String? get currentVersion => _currentVersion;
  String? get latestVersion => _latestVersion;

  Future<void> checkVersion() async {
    if (kIsWeb) {
      _isChecking = false;
      notifyListeners();
      return; // No OTA updates for web
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = packageInfo.version;

      final config = await _firestoreService.getAppConfig();
      if (config != null) {
        _latestVersion = config['latest_version'] as String?;
        final url = config['download_url'] as String?;

        if (_latestVersion != null && _isVersionOutdated(_currentVersion!, _latestVersion!)) {
          _isOutdated = true;
          _downloadUrl = url;
        }
      }
    } catch (e) {
      debugPrint('Failed to check version: $e');
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }

  bool _isVersionOutdated(String current, String latest) {
    // Simple semantic versioning check (e.g. 1.0.0 vs 1.1.0)
    try {
      final currentClean = current.split('+')[0].trim();
      final latestClean = latest.split('+')[0].trim();
      final currentParts = currentClean.split('.').map(int.parse).toList();
      final latestParts = latestClean.split('.').map(int.parse).toList();

      for (var i = 0; i < 3; i++) {
        final c = i < currentParts.length ? currentParts[i] : 0;
        final l = i < latestParts.length ? latestParts[i] : 0;
        if (l > c) return true;
        if (l < c) return false;
      }
    } catch (e) {
      // If parsing fails, do a basic string compare
      return current.trim() != latest.trim();
    }
    return false;
  }
}
