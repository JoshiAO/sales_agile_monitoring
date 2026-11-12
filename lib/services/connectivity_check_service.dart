import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// A real internet connectivity checker that validates actual HTTP/HTTPS data
/// pass-through (preventing false-positives on zero-balance SIM cards or
/// carrier captive portals where DNS port 53 still resolves).
///
/// Strategy (all free — no API keys, zero Firebase quota usage):
///   1. Fast-fail: Radio status via [connectivity_plus] (< 1ms)
///   2. Primary HTTP 204 check: `https://connectivitycheck.gstatic.com/generate_204`
///   3. Failover HTTP 204 checks: `https://clients3.google.com/generate_204`
///      and `https://cp.cloudflare.com/generate_204`
class ConnectivityCheckService {
  ConnectivityCheckService._();

  static const List<String> _probeUrls = <String>[
    'https://connectivitycheck.gstatic.com/generate_204',
    'https://clients3.google.com/generate_204',
    'https://cp.cloudflare.com/generate_204',
  ];

  static const Duration _probeTimeout = Duration(seconds: 4);

  /// Returns [true] if the device has a working internet connection capable of
  /// reaching external HTTPS endpoints without captive-portal redirection.
  /// Returns [false] if offline, zero-balance captive portal, or timed out.
  static Future<bool> hasInternetConnection() async {
    // Layer 1: Radio status — instant fail if airplane mode / Wi-Fi off / no SIM.
    try {
      final result = await Connectivity().checkConnectivity();
      if (result.contains(ConnectivityResult.none)) {
        debugPrint('[ConnectivityCheck] Layer 1 failed: no radio connection.');
        return false;
      }
    } catch (e) {
      debugPrint('[ConnectivityCheck] Layer 1 error (continuing): $e');
    }

    if (kIsWeb) return true;

    // Layer 2: HTTP 204 No Content verification across failover endpoints.
    // Zero-load SIMs and captive portals either time out on HTTPS or return
    // 200/302 redirect HTML pages instead of 204.
    for (final url in _probeUrls) {
      final passed = await _probeHttp204(url);
      if (passed) {
        debugPrint('[ConnectivityCheck] HTTP 204 passed via $url');
        return true;
      }
    }

    debugPrint('[ConnectivityCheck] All HTTP 204 probes failed — device is offline.');
    return false;
  }

  static Future<bool> _probeHttp204(String url) async {
    final client = HttpClient()..connectionTimeout = _probeTimeout;
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri).timeout(_probeTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');

      final response = await request.close().timeout(_probeTimeout);
      await response.drain<void>().timeout(_probeTimeout);

      return response.statusCode == HttpStatus.noContent;
    } catch (e) {
      debugPrint('[ConnectivityCheck] Probe failed ($url): $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
