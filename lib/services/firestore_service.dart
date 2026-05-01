import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
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

  static String _agileDocId({
    required String date,
    required String salesmanId,
  }) {
    return '${date}_$salesmanId';
  }

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
    final doc = await _firebaseService.firestore
        .collection('users')
        .doc(uid)
        .get();
    if (!doc.exists) return null;
    return AppUser.fromMap(doc.data() ?? {}, uid: uid);
  }

  Future<void> updateUser(String uid, Map<String, dynamic> data) async {
    await _firebaseService.firestore.collection('users').doc(uid).update(data);
  }

  Future<void> toggleUserActive(String uid, bool active) async {
    await _firebaseService.firestore.collection('users').doc(uid).update({
      'active': active,
    });
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

  Future<List<AppUser>> getAllUsers() async {
    final querySnapshot = await _firebaseService.firestore
        .collection('users')
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
      'checkpoints': checkpoints
          .map((checkpoint) => checkpoint.toMap())
          .toList(),
      'distance': distance,
      'firstRetakeRequested': false,
      'firstRetakeApproved': false,
      'lastRetakeRequested': false,
      'lastRetakeApproved': false,
      'createdAt': FieldValue.serverTimestamp(),
    });

    return routeId;
  }

  Future<List<SalesRoute>> getRoutesByDate(
    String supervisorId,
    String date,
  ) async {
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

  Future<List<SalesRoute>> getAllRoutesByDateRange({
    required String startDate,
    required String endDate,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('routes')
        .where('date', isGreaterThanOrEqualTo: startDate)
        .where('date', isLessThanOrEqualTo: endDate)
        .get();

    return querySnapshot.docs
        .map((doc) => SalesRoute.fromMap(doc.data(), routeId: doc.id))
        .toList();
  }

  Future<List<SalesRoute>> getRoutesForSupervisorByDateRange({
    required String supervisorId,
    required String startDate,
    required String endDate,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('routes')
        .where('supervisorId', isEqualTo: supervisorId)
        .where('date', isGreaterThanOrEqualTo: startDate)
        .where('date', isLessThanOrEqualTo: endDate)
        .get();

    return querySnapshot.docs
        .map((doc) => SalesRoute.fromMap(doc.data(), routeId: doc.id))
        .toList();
  }

  Future<List<SalesRoute>> getRoutesBySalesman(
    String salesmanId,
    String date,
  ) async {
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
    await _firebaseService.firestore
        .collection('routes')
        .doc(routeId)
        .update(data);
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
    final cacheTime = DateTime.now();
    await _firebaseService.firestore.collection('routes').doc(routeId).update({
      'cachedPolyline': points
          .map(
            (p) => CachedPolylinePoint(
              lat: p.lat,
              lon: p.lon,
              timestamp: p.timestamp ?? cacheTime,
            ).toMap(),
          )
          .toList(),
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

  Future<void> deleteRoutesByIds(List<String> routeIds) async {
    if (routeIds.isEmpty) return;

    final firestore = _firebaseService.firestore;
    final chunks = <List<String>>[];
    for (var index = 0; index < routeIds.length; index += 400) {
      chunks.add(
        routeIds.sublist(
          index,
          index + 400 > routeIds.length ? routeIds.length : index + 400,
        ),
      );
    }

    for (final chunk in chunks) {
      final batch = firestore.batch();
      for (final routeId in chunk) {
        batch.delete(firestore.collection('routes').doc(routeId));
      }
      await batch.commit();
    }
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
        await doc.reference.update({'supervisorId': null});
      }
    }

    await firestore.collection('users').doc(uid).delete();
  }

  // Agile Targets
  Future<void> upsertAgileTarget({
    required String supervisorId,
    required String salesmanId,
    required String date,
    required int productiveCallsTarget,
    required double sttTarget,
  }) async {
    final docId = _agileDocId(date: date, salesmanId: salesmanId);

    await _firebaseService.firestore
        .collection('agile_targets')
        .doc(docId)
        .set({
          'supervisorId': supervisorId,
          'salesmanId': salesmanId,
          'date': date,
          'productiveCallsTarget': productiveCallsTarget,
          'sttTarget': sttTarget,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<Map<String, AgileTarget>> getAgileTargetsForSupervisorByDate({
    required String supervisorId,
    required String date,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_targets')
        .where('supervisorId', isEqualTo: supervisorId)
        .where('date', isEqualTo: date)
        .get();

    final map = <String, AgileTarget>{};
    for (final doc in querySnapshot.docs) {
      final target = AgileTarget.fromMap(doc.data());
      map[target.salesmanId] = target;
    }
    return map;
  }

  Future<Map<String, AgileTarget>> getAgileTargetsForSupervisorByDateRange({
    required String supervisorId,
    required String startDate,
    required String endDate,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_targets')
        .where('supervisorId', isEqualTo: supervisorId)
        .where('date', isGreaterThanOrEqualTo: startDate)
        .where('date', isLessThanOrEqualTo: endDate)
        .get();

    final map = <String, AgileTarget>{};
    for (final doc in querySnapshot.docs) {
      final target = AgileTarget.fromMap(doc.data());
      map[_agileDocId(date: target.date, salesmanId: target.salesmanId)] =
          target;
    }
    return map;
  }

  Future<Map<String, AgileTarget>> getAgileTargetsByDate({
    required String date,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_targets')
        .where('date', isEqualTo: date)
        .get();

    final map = <String, AgileTarget>{};
    for (final doc in querySnapshot.docs) {
      final target = AgileTarget.fromMap(doc.data());
      map[target.salesmanId] = target;
    }
    return map;
  }

  Future<Map<String, AgileTarget>> getAgileTargetsByDateRange({
    required String startDate,
    required String endDate,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_targets')
        .where('date', isGreaterThanOrEqualTo: startDate)
        .where('date', isLessThanOrEqualTo: endDate)
        .get();

    final map = <String, AgileTarget>{};
    for (final doc in querySnapshot.docs) {
      final target = AgileTarget.fromMap(doc.data());
      map[_agileDocId(date: target.date, salesmanId: target.salesmanId)] =
          target;
    }
    return map;
  }

  // Agile Submissions
  Future<void> submitAgileSubmission({
    required String supervisorId,
    required String salesmanId,
    required String date,
    required int totalCalls,
    required int productiveCalls,
    required double sttActual,
    required bool lastCallCompleted,
  }) async {
    final docId = _agileDocId(date: date, salesmanId: salesmanId);
    final docRef = _firebaseService.firestore
        .collection('agile_submissions')
        .doc(docId);
    final existingDoc = await docRef.get();

    if (existingDoc.exists) {
      final existing = AgileSubmission.fromMap(existingDoc.data() ?? {});
      if (existing.submitted) {
        throw StateError(
          'Agile submission is already finalized for this date.',
        );
      }
    }

    await docRef.set({
      'supervisorId': supervisorId,
      'salesmanId': salesmanId,
      'date': date,
      'totalCalls': totalCalls,
      'productiveCalls': productiveCalls,
      'sttActual': sttActual,
      'lastCallCompleted': lastCallCompleted,
      'submitted': true,
      'submittedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<AgileSubmission?> getAgileSubmissionForSalesmanByDate({
    required String salesmanId,
    required String date,
  }) async {
    final docId = _agileDocId(date: date, salesmanId: salesmanId);
    final doc = await _firebaseService.firestore
        .collection('agile_submissions')
        .doc(docId)
        .get();
    if (!doc.exists) return null;
    return AgileSubmission.fromMap(doc.data() ?? {});
  }

  Future<Map<String, AgileSubmission>> getAgileSubmissionsForSupervisorByDate({
    required String supervisorId,
    required String date,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_submissions')
        .where('supervisorId', isEqualTo: supervisorId)
        .where('date', isEqualTo: date)
        .get();

    final map = <String, AgileSubmission>{};
    for (final doc in querySnapshot.docs) {
      final submission = AgileSubmission.fromMap(doc.data());
      map[submission.salesmanId] = submission;
    }
    return map;
  }

  Future<Map<String, AgileSubmission>>
  getAgileSubmissionsForSupervisorByDateRange({
    required String supervisorId,
    required String startDate,
    required String endDate,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_submissions')
        .where('supervisorId', isEqualTo: supervisorId)
        .where('date', isGreaterThanOrEqualTo: startDate)
        .where('date', isLessThanOrEqualTo: endDate)
        .get();

    final map = <String, AgileSubmission>{};
    for (final doc in querySnapshot.docs) {
      final submission = AgileSubmission.fromMap(doc.data());
      map[_agileDocId(
            date: submission.date,
            salesmanId: submission.salesmanId,
          )] =
          submission;
    }
    return map;
  }

  Future<Map<String, AgileSubmission>> getAllAgileSubmissionsByDate({
    required String date,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_submissions')
        .where('date', isEqualTo: date)
        .get();

    final map = <String, AgileSubmission>{};
    for (final doc in querySnapshot.docs) {
      final submission = AgileSubmission.fromMap(doc.data());
      map[submission.salesmanId] = submission;
    }
    return map;
  }

  Future<Map<String, AgileSubmission>> getAllAgileSubmissionsByDateRange({
    required String startDate,
    required String endDate,
  }) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('agile_submissions')
        .where('date', isGreaterThanOrEqualTo: startDate)
        .where('date', isLessThanOrEqualTo: endDate)
        .get();

    final map = <String, AgileSubmission>{};
    for (final doc in querySnapshot.docs) {
      final submission = AgileSubmission.fromMap(doc.data());
      map[_agileDocId(
            date: submission.date,
            salesmanId: submission.salesmanId,
          )] =
          submission;
    }
    return map;
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
