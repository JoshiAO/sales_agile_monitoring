import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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

  bool _isTransientFirestoreError(FirebaseException e) {
    return e.code == 'unavailable' ||
        e.code == 'deadline-exceeded' ||
        e.code == 'aborted';
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _getUserDocWithRetry(
    String uid,
  ) async {
    const maxAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _firebaseService.firestore
            .collection('users')
            .doc(uid)
            .get();
      } on FirebaseException catch (e) {
        lastError = e;
        final shouldRetry = _isTransientFirestoreError(e) && attempt < maxAttempts;
        if (!shouldRetry) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }

    throw lastError ?? Exception('Failed to load user profile.');
  }

  String _friendlyAuthMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Invalid email format.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'network-request-failed':
        return 'No internet connection. Please check your network and try again.';
      default:
        return e.message ?? 'Login failed. Please try again.';
    }
  }

  String _friendlyFirestoreMessage(FirebaseException e) {
    if (_isTransientFirestoreError(e)) {
      return 'Service is temporarily unavailable. Please try again in a moment.';
    }
    return e.message ?? 'Unable to load your user profile. Please try again.';
  }

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
        final userData = await _getUserDocWithRetry(user.uid);

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
      throw Exception(_friendlyAuthMessage(e));
    } on FirebaseException catch (e) {
      // If profile fetch fails after auth succeeds, sign out to avoid a partial session.
      await _firebaseService.auth.signOut();
      throw Exception(_friendlyFirestoreMessage(e));
    } catch (e) {
      throw Exception('Login failed. Please try again.');
    }
  }

  Future<void> logout() async {
    await _firebaseService.auth.signOut();
  }

  Future<AppUser?> getCurrentUser() async {
    final user = _firebaseService.auth.currentUser;
    if (user == null) return null;

    final userData = await _getUserDocWithRetry(user.uid);

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
