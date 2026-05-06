import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'firebase_service.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();

  factory AuthService() {
    return _instance;
  }

  AuthService._internal();

  final FirebaseService _firebaseService = FirebaseService();

  bool _isRoleAllowedForCurrentPlatform(UserRole role) {
    if (kIsWeb) {
      return role == UserRole.supervisor || role == UserRole.superuser;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      return role == UserRole.salesman;
    }

    return false;
  }

  String _platformRoleAccessMessage() {
    if (kIsWeb) {
      return 'This web app is for supervisor and superuser accounts only.';
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'This Android app is for salesman accounts only.';
    }

    return 'This platform is not supported for this app. Use Android for salesman or Web for supervisor/superuser access.';
  }

  Future<AppUser?> loginWithEmail(String email, String password) async {
    try {
      final UserCredential userCredential = await _firebaseService.auth
          .signInWithEmailAndPassword(email: email, password: password);

      final user = userCredential.user;
      if (user == null) return null;

      // Fetch user data from Firestore
      final userData = await _firebaseService.firestore
          .collection('users')
          .doc(user.uid)
          .get();

      if (!userData.exists) {
        await _firebaseService.auth.signOut();
        throw Exception('User profile was not found. Please contact your administrator.');
      }

      final appUser = AppUser.fromMap(userData.data() ?? {}, uid: user.uid);

      // Check if user is active
      if (!appUser.active) {
        await _firebaseService.auth.signOut();
        throw Exception('User account is inactive');
      }

      if (!_isRoleAllowedForCurrentPlatform(appUser.role)) {
        await _firebaseService.auth.signOut();
        throw Exception(_platformRoleAccessMessage());
      }

      return appUser;
    } on FirebaseAuthException catch (e) {
      throw Exception('Login error: ${e.message}');
    } catch (e) {
      throw Exception('Unexpected error: $e');
    }
  }

  Future<void> logout() async {
    await _firebaseService.auth.signOut();
  }

  Future<AppUser?> getCurrentUser() async {
    final user = _firebaseService.auth.currentUser;
    if (user == null) return null;

    final userData = await _firebaseService.firestore
        .collection('users')
        .doc(user.uid)
        .get();

    if (!userData.exists) {
      await _firebaseService.auth.signOut();
      throw Exception('User profile was not found. Please contact your administrator.');
    }

    final appUser = AppUser.fromMap(userData.data() ?? {}, uid: user.uid);

    if (!_isRoleAllowedForCurrentPlatform(appUser.role)) {
      await _firebaseService.auth.signOut();
      throw Exception(_platformRoleAccessMessage());
    }

    return appUser;
  }

  User? get currentFirebaseUser => _firebaseService.auth.currentUser;

  Stream<User?> get authStateChanges => _firebaseService.auth.authStateChanges();
}
