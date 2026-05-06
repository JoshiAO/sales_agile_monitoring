import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/auth_service.dart';
import 'package:compact_sales_monitoring/services/push_notification_service.dart';

class AuthProvider extends ChangeNotifier {
  static const String _cachedUserKey = 'cached_app_user';

  final AuthService _authService = AuthService();
  final PushNotificationService _pushNotificationService =
      PushNotificationService();
  StreamSubscription? _authSubscription;

  AppUser? _currentUser;
  bool _isLoading = false;
  bool _loginInProgress = false;
  bool _isInitializing = true;
  bool _requiresLaunchRetry = false;
  String? _launchRetryMessage;
  String? _error;

  AppUser? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  bool get isInitializing => _isInitializing;
  bool get requiresLaunchRetry => _requiresLaunchRetry;
  String? get launchRetryMessage => _launchRetryMessage;
  String? get error => _error;
  bool get isAuthenticated => _currentUser != null;

  bool _isLikelyOfflineError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('unavailable') ||
        message.contains('network') ||
        message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('connection');
  }

  Map<String, dynamic> _toJsonSafeMap(Map<String, dynamic> source) {
    final safe = <String, dynamic>{};
    source.forEach((key, value) {
      if (value is DateTime) {
        safe[key] = value.millisecondsSinceEpoch;
      } else {
        safe[key] = value;
      }
    });
    return safe;
  }

  // Persist the user profile locally so it can be restored when offline.
  Future<void> _cacheUser(AppUser user) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _toJsonSafeMap({
        'uid': user.uid,
        ...user.toMap(),
      });
      await prefs.setString(_cachedUserKey, jsonEncode(map));
    } catch (_) {}
  }

  Future<AppUser?> _loadCachedUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cachedUserKey);
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final uid = map['uid'] as String? ?? '';
      if (uid.isEmpty) return null;
      return AppUser.fromMap(map, uid: uid);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearCachedUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cachedUserKey);
    } catch (_) {}
  }

  Future<void> _bootstrapPersistedSession() async {
    _requiresLaunchRetry = false;
    _launchRetryMessage = null;

    final firebaseUser = _authService.currentFirebaseUser;

    if (firebaseUser == null) {
      _isInitializing = false;
      notifyListeners();
      return;
    }

    // First, try to restore from local cache immediately. If cached uid matches
    // the persisted Firebase user we can show the app right away and refresh
    // the profile in the background once online.
    final cached = await _loadCachedUser();
    if (cached != null && cached.uid == firebaseUser.uid) {
      _currentUser = cached;
      _error = null;
      _isInitializing = false;
      notifyListeners();
      // Kick off a background refresh so the profile stays up to date.
      _refreshProfileInBackground(firebaseUser.uid);
      return;
    }

    // No cache — must fetch from Firestore. Apply a tight timeout so we never
    // hang on the splash when the device is offline.
    try {
      final fetchedUser = await _authService.getCurrentUser().timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw Exception('network timeout'),
      );
      _currentUser = fetchedUser;
      if (_currentUser != null) {
        await _cacheUser(_currentUser!);
      }
      await _pushNotificationService.bindUser(_currentUser);
      _error = null;
    } catch (e) {
      // Timeout or network error — no cache available for this uid.
      _requiresLaunchRetry = true;
      _launchRetryMessage =
          'No internet connection. Connect to the internet and tap Retry.';
      _error = null;
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  Future<void> _refreshProfileInBackground(String uid) async {
    try {
      final fetchedUser = await _authService.getCurrentUser().timeout(
        const Duration(seconds: 12),
        onTimeout: () => null,
      );
      if (fetchedUser != null && fetchedUser.uid == uid) {
        _currentUser = fetchedUser;
        await _cacheUser(fetchedUser);
        await _pushNotificationService.bindUser(_currentUser);
        notifyListeners();
      }
    } catch (_) {
      // Silently ignore — the cached profile is already displayed.
    }
  }

  AuthProvider() {
    _bootstrapPersistedSession();

    _authSubscription = _authService.authStateChanges.listen((user) async {
      // Bootstrap is the sole authority during startup. The stream fires
      // immediately (even before Firestore resolves), so we must ignore every
      // event until bootstrap has set a definitive state.
      if (_isInitializing) return;

      if (user == null) {
        // Genuine post-bootstrap sign-out (e.g. admin-forced, token revoked).
        if (_currentUser == null) return;
        final previousUserId = _currentUser?.uid;
        _currentUser = null;
        await _clearCachedUser();
        await _pushNotificationService.unbindCurrentUser(uid: previousUserId);
        notifyListeners();
        return;
      }

      // Skip re-fetch if login() is already handling it to avoid race condition
      if (_loginInProgress) return;

      // Skip re-fetch if we already have data for this user
      if (_currentUser != null && _currentUser!.uid == user.uid) return;

      try {
        final fetchedUser = await _authService.getCurrentUser();
        _currentUser = fetchedUser;
        _error = null;
        if (_currentUser != null) await _cacheUser(_currentUser!);
        await _pushNotificationService.bindUser(_currentUser);
      } catch (_) {
        // Ignore post-bootstrap stream refresh failures — the user is already
        // loaded from bootstrap. This avoids disrupting an active session due
        // to a transient network hiccup.
      }
      notifyListeners();
    });
  }

  Future<void> retryLaunchValidation() async {
    if (_isInitializing) return;
    _isInitializing = true;
    _requiresLaunchRetry = false;
    _launchRetryMessage = null;
    _error = null;
    notifyListeners();
    await _bootstrapPersistedSession();
  }

  Future<void> login(String email, String password) async {
    _loginInProgress = true;
    _isLoading = true;
    _error = null;
    notifyListeners();

    final sw = Stopwatch()..start();
    try {
      final user = await _authService.loginWithEmail(email, password);
      if (user == null) {
        _error = 'Login failed: account not found or inactive. Please contact your administrator.';
        _currentUser = null;
      } else {
        _currentUser = user;
        _error = null;
        await _cacheUser(_currentUser!);
        await _pushNotificationService.bindUser(_currentUser);
      }
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _currentUser = null;
    } finally {
      final remaining = 3500 - sw.elapsedMilliseconds;
      if (remaining > 0) {
        await Future<void>.delayed(Duration(milliseconds: remaining));
      }
      _loginInProgress = false;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    final sw = Stopwatch()..start();
    final previousUserId = _currentUser?.uid;
    try {
      await _authService.logout();
      _currentUser = null;
      _error = null;
      await _clearCachedUser();
      await _pushNotificationService.unbindCurrentUser(uid: previousUserId);
    } catch (e) {
      _error = e.toString();
    } finally {
      final remaining = 3500 - sw.elapsedMilliseconds;
      if (remaining > 0) {
        await Future<void>.delayed(Duration(milliseconds: remaining));
      }
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> checkCurrentUser() async {
    try {
      final user = await _authService.getCurrentUser();
      _currentUser = user;
      await _pushNotificationService.bindUser(_currentUser);
    } catch (e) {
      _currentUser = null;
    }
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _pushNotificationService.unbindCurrentUser(uid: _currentUser?.uid);
    super.dispose();
  }
}
