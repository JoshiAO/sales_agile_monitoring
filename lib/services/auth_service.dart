import 'package:firebase_auth/firebase_auth.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'firebase_service.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();

  factory AuthService() {
    return _instance;
  }

  AuthService._internal();

  final FirebaseService _firebaseService = FirebaseService();

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

      if (!userData.exists) return null;

      final appUser = AppUser.fromMap(userData.data() ?? {}, uid: user.uid);

      // Check if user is active
      if (!appUser.active) {
        await _firebaseService.auth.signOut();
        throw Exception('User account is inactive');
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

    if (!userData.exists) return null;

    return AppUser.fromMap(userData.data() ?? {}, uid: user.uid);
  }

  Stream<User?> get authStateChanges => _firebaseService.auth.authStateChanges();
}
