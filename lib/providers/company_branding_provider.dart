import 'dart:convert';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:compact_sales_monitoring/models/company_branding_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class CompanyBrandingProvider extends ChangeNotifier {
  static const String _cacheKeyPrefix = 'company_branding_';
  static const String _lastBrandingCacheKey = 'company_branding_last';
  static const int _maxFetchAttempts = 3;

  final FirestoreService _firestoreService = FirestoreService();

  CompanyBranding? _branding;
  String? _lastCompanyId;
  String? _inFlightCompanyId;

  CompanyBranding? get branding => _branding;

  CompanyBrandingProvider({CompanyBranding? initialBranding}) {
    if (initialBranding != null) {
      _branding = initialBranding;
      _lastCompanyId = initialBranding.companyId;
    }
    _bootstrapLastBranding();
  }

  static Future<CompanyBranding?> loadLastCachedBranding() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastBrandingCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final companyId = (map['company_ID'] as String?)?.trim();
      if (companyId == null || companyId.isEmpty) return null;
      return CompanyBranding.fromMap(map, companyId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _bootstrapLastBranding() async {
    try {
      if (_branding != null) return;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastBrandingCacheKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final companyId = (map['company_ID'] as String?)?.trim();
      if (companyId == null || companyId.isEmpty) return;

      final branding = CompanyBranding.fromMap(map, companyId);
      _branding = branding;
      if (kDebugMode) {
        debugPrint(
          '[Branding] bootstrapped last cache company=$companyId logo=${_branding?.logoUrl != null}',
        );
      }
      notifyListeners();
    } catch (_) {
      // Ignore stale bootstrap cache errors.
    }
  }

  /// Called by [ChangeNotifierProxyProvider] whenever [AuthProvider] changes.
  void updateFromUser(AppUser? user) {
    final companyId = user?.companyId?.trim();
    if (kDebugMode) {
      debugPrint('[Branding] updateFromUser companyId=$companyId');
    }

    if (companyId == null || companyId.isEmpty) {
      // Keep the last known branding visible while auth/session transitions.
      // This avoids flicker back to default splash when auth briefly emits null.
      return;
    }

    final sameCompany = companyId == _lastCompanyId;

    if (!sameCompany) {
      _lastCompanyId = companyId;
      final hasDifferentBranding =
          _branding != null && _branding!.companyId != companyId;
      if (hasDifferentBranding) {
        _branding = null;
        notifyListeners();
      }
    }

    final hasBrandingForCompany =
        _branding != null && _branding!.companyId == companyId;

    if (!hasBrandingForCompany && _inFlightCompanyId != companyId) {
      _loadBranding(companyId, attempt: 1);
    }
  }

  Future<void> _loadBranding(String companyId, {required int attempt}) async {
    _inFlightCompanyId = companyId;
    if (kDebugMode) {
      debugPrint('[Branding] loading company=$companyId attempt=$attempt');
    }

    // Show cached branding instantly while remote fetch runs.
    final cached = await _loadCachedBranding(companyId);
    if (cached != null && _lastCompanyId == companyId) {
      _branding = cached;
      if (kDebugMode) {
        debugPrint(
          '[Branding] loaded cached logo=${_branding?.logoUrl != null} tagline=${_branding?.tagline}',
        );
      }
      notifyListeners();
    }

    // Refresh from Firestore in background.
    try {
      final fresh = await _firestoreService.getCompanyBranding(companyId);
      if (_lastCompanyId != companyId) return;
      _branding = fresh == null ? null : await _withResolvedLogo(fresh);
      if (fresh != null) await _cacheBranding(fresh);
      if (kDebugMode) {
        debugPrint(
          '[Branding] loaded remote found=${fresh != null} logo=${_branding?.logoUrl != null} tagline=${_branding?.tagline}',
        );
      }
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[Branding] load failed company=$companyId attempt=$attempt error=$e',
        );
      }
      // Retry transient startup failures a few times before giving up.
      if (_lastCompanyId == companyId &&
          (_branding == null || _branding!.companyId != companyId) &&
          attempt < _maxFetchAttempts) {
        _inFlightCompanyId = null;
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        if (_lastCompanyId == companyId) {
          await _loadBranding(companyId, attempt: attempt + 1);
        }
      }
    } finally {
      if (_inFlightCompanyId == companyId) {
        _inFlightCompanyId = null;
      }
    }
  }

  Future<CompanyBranding?> _loadCachedBranding(String companyId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_cacheKeyPrefix$companyId');
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return CompanyBranding.fromMap(map, companyId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheBranding(CompanyBranding branding) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_cacheKeyPrefix${branding.companyId}',
        jsonEncode(branding.toMap()),
      );
      await prefs.setString(
        _lastBrandingCacheKey,
        jsonEncode({
          'company_ID': branding.companyId,
          ...branding.toMap(),
        }),
      );
    } catch (_) {}
  }

  Future<CompanyBranding> _withResolvedLogo(CompanyBranding branding) async {
    final resolvedLogo = await _resolveImageUrl(branding.logoUrl);
    return CompanyBranding(
      companyId: branding.companyId,
      logoUrl: resolvedLogo,
      tagline: branding.tagline,
    );
  }

  Future<String?> _resolveImageUrl(String? value) async {
    final normalized = _normalizeImageUrl(value);
    if (normalized == null || normalized.isEmpty) return null;

    if (normalized.startsWith('gs://')) {
      try {
        return await FirebaseStorage.instance
            .refFromURL(normalized)
            .getDownloadURL();
      } catch (_) {
        return null;
      }
    }

    final parsed = Uri.tryParse(normalized);
    if (parsed != null && parsed.hasScheme) {
      if (parsed.host.contains('firebasestorage.googleapis.com')) {
        final objectPath = _extractStorageObjectPath(parsed);
        if (objectPath != null) {
          try {
            return await FirebaseStorage.instance
                .ref(objectPath)
                .getDownloadURL();
          } catch (_) {
            // If refresh fails, still use the original URL.
          }
        }
      }
      return parsed.toString();
    }

    final objectPath = normalized.replaceAll('\\', '/').replaceFirst(
      RegExp(r'^/+'),
      '',
    );
    if (objectPath.isNotEmpty) {
      try {
        return await FirebaseStorage.instance.ref(objectPath).getDownloadURL();
      } catch (_) {
        return null;
      }
    }

    return normalized;
  }

  String? _normalizeImageUrl(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;
    if (raw.startsWith('gs://')) return raw;

    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.hasScheme) {
      if (parsed.scheme == 'http') {
        return parsed.replace(scheme: 'https').toString();
      }
      return parsed.toString();
    }

    return Uri.encodeFull(raw);
  }

  String? _extractStorageObjectPath(Uri uri) {
    final segments = uri.pathSegments;
    final objectIndex = segments.indexOf('o');
    if (objectIndex < 0 || objectIndex + 1 >= segments.length) {
      return null;
    }

    final encodedPath = segments[objectIndex + 1];
    if (encodedPath.isEmpty) return null;
    return Uri.decodeComponent(encodedPath);
  }
}
