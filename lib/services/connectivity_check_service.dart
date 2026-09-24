import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// A real internet connectivity checker.
///
/// Unlike [connectivity_plus] which only checks radio state (Wi-Fi on, Mobile
/// Data on), this service verifies that the device can actually reach the
/// internet by performing a DNS resolution and a raw socket connection.
///
/// Strategy (3-layer, all free — no HTTP, no API keys):
///   1. Fast-fail: Radio status via connectivity_plus (< 1ms)
///   2. DNS lookup: [InternetAddress.lookup] with a 3-second timeout
///   3. Raw socket fallback: TCP connect to 8.8.8.8:53 (Google Public DNS)
class ConnectivityCheckService {
  ConnectivityCheckService._();

  /// Returns [true] if the device has a working internet connection.
  /// Returns [false] if offline or if all checks time out.
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

    // Layer 2: DNS lookup — proves DNS is resolving (real internet access).
    try {
      final addresses = await InternetAddress.lookup('google.com').timeout(
        const Duration(seconds: 3),
      );
      if (addresses.isNotEmpty && addresses[0].rawAddress.isNotEmpty) {
        debugPrint('[ConnectivityCheck] Layer 2 passed: DNS resolved.');
        return true;
      }
    } catch (e) {
      debugPrint('[ConnectivityCheck] Layer 2 failed (trying socket): $e');
    }

    // Layer 3: Raw TCP socket to Google Public DNS IP — bypasses DNS captive
    // portals. If we can open a socket to 8.8.8.8:53 the internet is reachable.
    try {
      final socket = await Socket.connect(
        '8.8.8.8',
        53,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      debugPrint('[ConnectivityCheck] Layer 3 passed: socket connected.');
      return true;
    } catch (e) {
      debugPrint('[ConnectivityCheck] Layer 3 failed: $e');
    }

    debugPrint('[ConnectivityCheck] All layers failed — device is offline.');
    return false;
  }
}
