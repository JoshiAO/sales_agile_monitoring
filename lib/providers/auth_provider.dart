import 'package:flutter/material.dart';
import 'dart:async';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  StreamSubscription? _authSubscription;

  AppUser? _currentUser;
  bool _isLoading = false;
  bool _loginInProgress = false;
  String? _error;

  AppUser? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _currentUser != null;

  AuthProvider() {
    _authSubscription = _authService.authStateChanges.listen((user) async {
      if (user == null) {
        _currentUser = null;
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
      } catch (e) {
        // Keep existing authenticated session on transient profile fetch errors.
        if (_currentUser == null) {
          _error = e.toString().replaceFirst('Exception: ', '');
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
    try {
      await _authService.logout();
      _currentUser = null;
      _error = null;
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
    super.dispose();
  }
}
