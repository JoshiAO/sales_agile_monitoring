import 'package:flutter/material.dart';
import 'dart:async';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  StreamSubscription? _authSubscription;

  AppUser? _currentUser;
  bool _isLoading = false;
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

      try {
        _currentUser = await _authService.getCurrentUser();
      } catch (_) {
        _currentUser = null;
      }
      notifyListeners();
    });
  }

  Future<void> login(String email, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    final sw = Stopwatch()..start();
    try {
      final user = await _authService.loginWithEmail(email, password);
      _currentUser = user;
    } catch (e) {
      _error = e.toString();
      _currentUser = null;
    } finally {
      final remaining = 3500 - sw.elapsedMilliseconds;
      if (remaining > 0) {
        await Future<void>.delayed(Duration(milliseconds: remaining));
      }
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
