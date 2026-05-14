import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:compact_sales_monitoring/firebase_options.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class UserProvisioningService {
  final FirestoreService _firestoreService = FirestoreService();
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  Future<void> createManagedUser({
    required String email,
    required String password,
    required UserRole role,
    String? supervisorId,
    String? name,
    bool active = true,
    String? companyId,
  }) async {
    FirebaseApp? secondaryApp;
    FirebaseAuth? secondaryAuth;
    User? createdUser;
    final normalizedEmail = email.trim().toLowerCase();
    final trimmedName = name?.trim();

    try {
      secondaryApp = await Firebase.initializeApp(
        name: 'user-provisioning-${DateTime.now().microsecondsSinceEpoch}',
        options: DefaultFirebaseOptions.currentPlatform,
      );
      secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);

      final credential = await secondaryAuth.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
      createdUser = credential.user;

      if (createdUser == null) {
        throw Exception('User account was created without a valid UID.');
      }

      await _firestoreService.createUser(
        uid: createdUser.uid,
        email: normalizedEmail,
        role: role,
        supervisorId: role == UserRole.salesman ? supervisorId : null,
        name: trimmedName == null || trimmedName.isEmpty ? null : trimmedName,
        active: active,
        companyId: companyId,
      );
    } on FirebaseAuthException catch (e) {
      throw Exception(e.message ?? 'Failed to create the authentication account.');
    } on FirebaseException catch (e) {
      if (createdUser != null) {
        await _deleteCreatedUser(createdUser);
      }
      throw Exception(e.message ?? 'Failed to create the user profile.');
    } catch (e) {
      if (createdUser != null) {
        await _deleteCreatedUser(createdUser);
      }
      if (e is Exception) {
        rethrow;
      }
      throw Exception('Failed to create user: $e');
    } finally {
      if (secondaryAuth != null) {
        try {
          await secondaryAuth.signOut();
        } catch (_) {}
      }
      if (secondaryApp != null) {
        try {
          await secondaryApp.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _deleteCreatedUser(User user) async {
    try {
      await user.delete();
    } catch (_) {}
  }

  Future<void> updateManagedUser({
    required String uid,
    required String currentEmail,
    required String? name,
    required bool active,
    required UserRole role,
    required String? supervisorId,
    String? newEmail,
    String? newPassword,
  }) async {
    final normalizedCurrentEmail = currentEmail.trim().toLowerCase();
    final normalizedNewEmail = newEmail?.trim().toLowerCase();
    final trimmedPassword = newPassword?.trim();
    final trimmedName = name?.trim();

    final shouldUpdateEmail =
        normalizedNewEmail != null &&
        normalizedNewEmail.isNotEmpty &&
        normalizedNewEmail != normalizedCurrentEmail;
    final shouldUpdatePassword =
        trimmedPassword != null && trimmedPassword.isNotEmpty;

    if (shouldUpdatePassword && trimmedPassword.length < 6) {
      throw Exception('Password must be at least 6 characters long.');
    }

    if (shouldUpdateEmail || shouldUpdatePassword) {
      try {
        final currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser == null) {
          throw Exception('Your session has expired. Please sign in again.');
        }

        // Force a fresh token so callable requests include valid auth context.
        await currentUser.getIdToken(true);

        final callable = _functions.httpsCallable('adminUpdateUserCredentials');
        await callable.call(<String, dynamic>{
          'uid': uid,
          if (shouldUpdateEmail) 'email': normalizedNewEmail,
          if (shouldUpdatePassword) 'password': trimmedPassword,
        });
      } on FirebaseFunctionsException catch (e) {
        if (e.code == 'unauthenticated') {
          throw Exception('Your session has expired. Please sign out and sign in again.');
        }
        throw Exception(
          e.message ??
              'Unable to update authentication credentials. Ensure the adminUpdateUserCredentials Cloud Function is deployed.',
        );
      }
    }

    await _firestoreService.updateUser(uid, {
      'email': shouldUpdateEmail ? normalizedNewEmail : normalizedCurrentEmail,
      'name': trimmedName == null || trimmedName.isEmpty ? null : trimmedName,
      'fsName': null,
      'active': active,
      'role': role.toString().split('.').last,
      'supervisorId': role == UserRole.salesman ? supervisorId : null,
    });
  }
}