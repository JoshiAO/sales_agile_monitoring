import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:usage_stats/usage_stats.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:package_info_plus/package_info_plus.dart';

class TelemetryService {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static final Battery _battery = Battery();

  static Future<String> getUUID() async {
    final prefs = await SharedPreferences.getInstance();
    String? uuid = prefs.getString('device_uuid');
    if (uuid == null) {
      uuid = const Uuid().v4();
      await prefs.setString('device_uuid', uuid);
    }
    return uuid;
  }

  static Future<Map<String, dynamic>> getDeviceTelemetry() async {
    if (kIsWeb) return {};

    String? productName;
    String? modelName;
    String? serialNumber;
    int? batteryLevel;
    String? appVersion;

    try {
      batteryLevel = await _battery.batteryLevel;
    } catch (_) {}

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (_) {}

    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        productName = androidInfo.brand;
        modelName = androidInfo.model;
        
        // Android 10+ removed access to serial number
        serialNumber = null;
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfo.iosInfo;
        productName = 'Apple';
        modelName = iosInfo.model;
        serialNumber = iosInfo.identifierForVendor;
      }
    } catch (_) {}

    final uuid = await getUUID();

    return {
      'productName': productName,
      'modelName': modelName,
      'serialNumber': serialNumber,
      'uuid': uuid,
      'batteryLevel': batteryLevel,
      'appVersion': appVersion,
    };
  }

  static Future<bool> requestUsagePermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    
    // Also request phone state permission which is needed for mobile network stats
    if (!await Permission.phone.isGranted) {
      await Permission.phone.request();
    }

    // Check if permission is already granted
    final isGranted = await UsageStats.checkUsagePermission();
    if (isGranted ?? false) return true;

    // Prompt user to go to settings
    await UsageStats.grantUsagePermission();
    
    // Wait a bit and recheck, though usually the app goes to background
    return await UsageStats.checkUsagePermission() ?? false;
  }

  static Future<Map<String, List<Map<String, dynamic>>>> getDataUsage() async {
    if (kIsWeb || !Platform.isAndroid) return {'mobile': [], 'wifi': []};

    try {
      final isGranted = await UsageStats.checkUsagePermission();
      if (!(isGranted ?? false)) return {'mobile': [], 'wifi': []};

      // Get stats for today
      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);

      // WiFi stats: only requires PACKAGE_USAGE_STATS permission.
      List<NetworkInfo> wifiStats = [];
      try {
        wifiStats = await UsageStats.queryNetworkUsageStats(
          startOfDay,
          now,
          networkType: NetworkType.wifi,
        );
      } catch (e) {
        debugPrint('Failed to get WiFi usage stats: $e');
      }

      // Mobile stats: additionally requires READ_PHONE_STATE for subscriberId.
      List<NetworkInfo> mobileStats = [];
      final hasPhoneState = await Permission.phone.isGranted;
      if (hasPhoneState) {
        try {
          mobileStats = await UsageStats.queryNetworkUsageStats(
            startOfDay,
            now,
            networkType: NetworkType.mobile,
          );
        } catch (e) {
          debugPrint('Failed to get mobile usage stats: $e');
        }
      }

      List<Map<String, dynamic>> parseStats(List<NetworkInfo> statsList) {
        final List<Map<String, dynamic>> result = [];
        double totalBytes = 0;

        for (var stat in statsList) {
          final tx = double.tryParse(stat.txTotalBytes ?? '0') ?? 0;
          final rx = double.tryParse(stat.rxTotalBytes ?? '0') ?? 0;
          final total = tx + rx;
          if (total > 0) {
            totalBytes += total;
            result.add({
              'appName': stat.packageName ?? 'Unknown App',
              'packageName': stat.packageName,
              'bytes': total,
            });
          }
        }

        // Calculate index (percentage) and format to MB
        for (var i = 0; i < result.length; i++) {
          final bytes = result[i]['bytes'] as double;
          final index = totalBytes > 0 ? (bytes / totalBytes) * 100 : 0.0;
          final mb = bytes / (1024 * 1024);
          
          result[i] = {
            'appName': result[i]['appName'],
            'packageName': result[i]['packageName'],
            'usageMB': double.parse(mb.toStringAsFixed(2)),
            'index': double.parse(index.toStringAsFixed(1)),
          };
        }

        // Sort highest usage to lowest
        result.sort((a, b) => (b['usageMB'] as double).compareTo(a['usageMB'] as double));
        
        return result;
      }

      return {
        'mobile': parseStats(mobileStats),
        'wifi': parseStats(wifiStats),
      };
    } catch (e) {
      debugPrint('Failed to get data usage: $e');
      return {'mobile': [], 'wifi': []};
    }
  }
}
