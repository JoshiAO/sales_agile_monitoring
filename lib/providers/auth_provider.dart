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
  String? _error;

  AppUser? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  bool get isInitializing => _isInitializing;
  String? get error => _error;
  bool get isAuthenticated => _currentUser != null;

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
    final firebaseUser = _authService.currentFirebaseUser;

    if (firebaseUser == null) {
      _isInitializing = false;
      notifyListeners();
      return;
    }

    try {
      final fetchedUser = await _authService.getCurrentUser();
      _currentUser = fetchedUser;
      if (_currentUser != null) {
        await _cacheUser(_currentUser!);
      }
      await _pushNotificationService.bindUser(_currentUser);
      _error = null;
    } catch (e) {
      final cached = await _loadCachedUser();
      if (cached != null && cached.uid == firebaseUser.uid) {
        _currentUser = cached;
        _error = null;
      } else {
        _error = e.toString().replaceFirst('Exception: ', '');
      }
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  AuthProvider() {
    _bootstrapPersistedSession();

    _authSubscription = _authService.authStateChanges.listen((user) async {
      if (user == null) {
        if (_isInitializing || _currentUser != null) {
          // During startup or transient auth null blips, keep current session.
          _isInitializing = false;
          notifyListeners();
          return;
        }

        final previousUserId = _currentUser?.uid;
        _currentUser = null;
        await _clearCachedUser();
        await _pushNotificationService.unbindCurrentUser(uid: previousUserId);
        _isInitializing = false;
        notifyListeners();
        return;
      }

      _isInitializing = false;

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
      } catch (e) {
        // Firestore unreachable (offline). Restore from local cache so the
        // user stays logged in with their last-known profile.
        if (_currentUser == null) {
          final cached = await _loadCachedUser();
          if (cached != null && cached.uid == user.uid) {
            _currentUser = cached;
          } else {
            _error = e.toString().replaceFirst('Exception: ', '');
          }
        }
      }
      notifyListeners();
    });
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
