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

  // Session-aware update deferral.
  bool _sessionActive = false;
  bool _updateDeferred = false;
  String? _deferredDownloadUrl;
  String? _deferredLatestVersion;

  bool get isChecking => _isChecking;
  bool get isOutdated => _isOutdated;
  String? get downloadUrl => _downloadUrl;
  String? get currentVersion => _currentVersion;
  String? get latestVersion => _latestVersion;

  /// True when a version update was found but deferred because an active
  /// call session is in progress. The salesman should be notified via a
  /// non-blocking toast.
  bool get updateDeferred => _updateDeferred;

  /// Called by [SalesmanHomeScreen] when a call session starts (First Call
  /// completed) or ends (Last Call completed or retake).
  ///
  /// When the session ends and an update was deferred, this method applies
  /// the deferred update immediately so [AppRouter] shows [ForceUpdateScreen].
  void setSessionActive(bool active) {
    _sessionActive = active;
    debugPrint('[VersionProvider] Session active: $active, updateDeferred: $_updateDeferred');

    if (!active && _updateDeferred) {
      // Session just ended — apply the previously deferred update.
      _isOutdated = true;
      _downloadUrl = _deferredDownloadUrl;
      _latestVersion = _deferredLatestVersion;
      _updateDeferred = false;
      _deferredDownloadUrl = null;
      _deferredLatestVersion = null;
      debugPrint('[VersionProvider] Deferred update now active. Latest: $_latestVersion');
      notifyListeners();
    }
  }

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
        final fetchedLatest = config['latest_version'] as String?;
        final url = config['download_url'] as String?;

        if (fetchedLatest != null &&
            _isVersionOutdated(_currentVersion!, fetchedLatest)) {
          if (_sessionActive) {
            // A call session is active — defer the update so we don't
            // interrupt the salesman mid-session.
            _updateDeferred = true;
            _deferredDownloadUrl = url;
            _deferredLatestVersion = fetchedLatest;
            _isOutdated = false; // Keep the app usable during the session.
            debugPrint(
              '[VersionProvider] Update available ($fetchedLatest) but session is active. Deferring.',
            );
          } else {
            // No active session — apply immediately.
            _isOutdated = true;
            _downloadUrl = url;
            _latestVersion = fetchedLatest;
            debugPrint('[VersionProvider] Update available. Showing ForceUpdateScreen.');
          }
        } else {
          _latestVersion = fetchedLatest;
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
