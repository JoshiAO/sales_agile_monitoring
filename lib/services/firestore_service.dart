import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:uuid/uuid.dart';
import 'firebase_service.dart';

class FirestoreService {
  static final FirestoreService _instance = FirestoreService._internal();

  factory FirestoreService() {
    return _instance;
  }

  FirestoreService._internal();

  final FirebaseService _firebaseService = FirebaseService();
  static const uuid = Uuid();

  // User Management
  Future<void> createUser({
    required String uid,
    required String email,
    required UserRole role,
    String? supervisorId,
    String? name,
    String? fsName,
    bool active = false,
  }) async {
    await _firebaseService.firestore.collection('users').doc(uid).set({
      'email': email,
      'name': name,
      'fsName': fsName,
      'role': _roleToString(role),
      'active': active,
      'supervisorId': supervisorId,
      'profilePic': null,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<AppUser?> getUser(String uid) async {
    final doc = await _firebaseService.firestore.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return AppUser.fromMap(doc.data() ?? {}, uid: uid);
  }

  Future<void> updateUser(String uid, Map<String, dynamic> data) async {
    await _firebaseService.firestore.collection('users').doc(uid).update(data);
  }

  Future<void> toggleUserActive(String uid, bool active) async {
    await _firebaseService.firestore
        .collection('users')
        .doc(uid)
        .update({'active': active});
  }

  Future<List<AppUser>> getUsersByRole(UserRole role) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('users')
        .where('role', isEqualTo: _roleToString(role))
        .get();

    return querySnapshot.docs
        .map((doc) => AppUser.fromMap(doc.data(), uid: doc.id))
        .toList();
  }

  Future<List<AppUser>> getSupervisorTeam(String supervisorId) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('users')
        .where('supervisorId', isEqualTo: supervisorId)
        .get();

    return querySnapshot.docs
        .map((doc) => AppUser.fromMap(doc.data(), uid: doc.id))
        .toList();
  }

  // Route Management
  Future<String> createRoute({
    required String salesmanId,
    required String supervisorId,
    required String date,
    required RoutePoint first,
    required RoutePoint last,
    bool hasFirstCall = true,
    bool hasLastCall = true,
    List<RouteCheckpoint> checkpoints = const [],
    double? distance,
  }) async {
    final routeId = uuid.v4();

    await _firebaseService.firestore.collection('routes').doc(routeId).set({
      'salesmanId': salesmanId,
      'supervisorId': supervisorId,
      'date': date,
      'first': first.toMap(),
      'last': last.toMap(),
      'hasFirstCall': hasFirstCall,
      'hasLastCall': hasLastCall,
      'checkpoints': checkpoints.map((checkpoint) => checkpoint.toMap()).toList(),
      'distance': distance,
      'firstRetakeRequested': false,
      'firstRetakeApproved': false,
      'lastRetakeRequested': false,
      'lastRetakeApproved': false,
      'createdAt': FieldValue.serverTimestamp(),
    });

    return routeId;
  }

  Future<List<SalesRoute>> getRoutesByDate(String supervisorId, String date) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('routes')
        .where('supervisorId', isEqualTo: supervisorId)
        .where('date', isEqualTo: date)
        .get();

    return querySnapshot.docs
        .map((doc) => SalesRoute.fromMap(doc.data(), routeId: doc.id))
        .toList();
  }

  Future<List<SalesRoute>> getAllRoutesByDate(String date) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('routes')
        .where('date', isEqualTo: date)
        .get();

    return querySnapshot.docs
        .map((doc) => SalesRoute.fromMap(doc.data(), routeId: doc.id))
        .toList();
  }

  Future<List<SalesRoute>> getRoutesBySalesman(String salesmanId, String date) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('routes')
        .where('salesmanId', isEqualTo: salesmanId)
        .where('date', isEqualTo: date)
        .get();

    return querySnapshot.docs
        .map((doc) => SalesRoute.fromMap(doc.data(), routeId: doc.id))
        .toList();
  }

  Future<void> updateRoute(String routeId, Map<String, dynamic> data) async {
    await _firebaseService.firestore.collection('routes').doc(routeId).update(data);
  }

  Future<void> appendRouteCheckpoint(
    String routeId,
    RouteCheckpoint checkpoint,
  ) async {
    await _firebaseService.firestore.collection('routes').doc(routeId).update({
      'checkpoints': FieldValue.arrayUnion([checkpoint.toMap()]),
    });
  }

  Future<void> savePolylineCache(
    String routeId,
    List<CachedPolylinePoint> points,
  ) async {
    await _firebaseService.firestore.collection('routes').doc(routeId).update({
      'cachedPolyline': points.map((p) => p.toMap()).toList(),
    });
  }

  Future<void> requestCallRetake({
    required String routeId,
    required bool isFirst,
    required String requestedBy,
  }) async {
    await _firebaseService.firestore.collection('routes').doc(routeId).update({
      isFirst ? 'firstRetakeRequested' : 'lastRetakeRequested': true,
      isFirst ? 'firstRetakeApproved' : 'lastRetakeApproved': false,
      isFirst ? 'firstRetakeRequestedBy' : 'lastRetakeRequestedBy': requestedBy,
      isFirst ? 'firstRetakeRequestedAt' : 'lastRetakeRequestedAt':
          FieldValue.serverTimestamp(),
    });
  }

  Future<void> approveCallRetake({
    required String routeId,
    required bool isFirst,
    required String approvedBy,
  }) async {
    await _firebaseService.firestore.collection('routes').doc(routeId).update({
      isFirst ? 'firstRetakeRequested' : 'lastRetakeRequested': false,
      isFirst ? 'firstRetakeApproved' : 'lastRetakeApproved': true,
      isFirst ? 'firstRetakeApprovedBy' : 'lastRetakeApprovedBy': approvedBy,
      isFirst ? 'firstRetakeApprovedAt' : 'lastRetakeApprovedAt':
          FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteUserData({
    required String uid,
    required UserRole role,
  }) async {
    final firestore = _firebaseService.firestore;

    // Delete user routes if the deleted account is a salesman.
    if (role == UserRole.salesman) {
      final routesSnapshot = await firestore
          .collection('routes')
          .where('salesmanId', isEqualTo: uid)
          .get();
      for (final doc in routesSnapshot.docs) {
        await doc.reference.delete();
      }
    }

    // If a supervisor is removed, clear assignments from its team.
    if (role == UserRole.supervisor) {
      final teamSnapshot = await firestore
          .collection('users')
          .where('supervisorId', isEqualTo: uid)
          .get();
      for (final doc in teamSnapshot.docs) {
        await doc.reference.update({
          'supervisorId': null,
        });
      }
    }

    await firestore.collection('users').doc(uid).delete();
  }
}

String _roleToString(UserRole role) {
  switch (role) {
    case UserRole.salesman:
      return 'salesman';
    case UserRole.supervisor:
      return 'supervisor';
    case UserRole.superuser:
      return 'superuser';
  }
}
