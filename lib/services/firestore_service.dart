import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/company_branding_model.dart';
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

  static String _announcementDocId() => uuid.v4();

  // User Management
  Future<void> createUser({
    required String uid,
    required String email,
    required UserRole role,
    String? supervisorId,
    String? name,
    String? fsName,
    bool active = false,
    String? companyId,
  }) async {
    await _firebaseService.firestore.collection('users').doc(uid).set({
      'email': email,
      'name': name,
      'fsName': fsName,
      'role': _roleToString(role),
      'active': active,
      'supervisorId': supervisorId,
      'profilePic': null,
      'logoutRequestPending': false,
      'logoutRequestApproved': false,
      'logoutRequestStatus': null,
      'logoutRequestedAt': null,
      'logoutResolvedAt': null,
      'logoutResolvedBy': null,
      'logoutResolvedByName': null,
      'fcmToken': null,
      'fcmTokenUpdatedAt': null,
      'company_ID': companyId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Company Branding
  Future<CompanyBranding?> getCompanyBranding(String companyId) async {
    final collection = _firebaseService.firestore.collection('company_ID');

    // First try direct doc-id access for schemas where document id == company_ID.
    final doc = await collection.doc(companyId).get();
    if (doc.exists) {
      return CompanyBranding.fromMap(doc.data() ?? {}, companyId);
    }

    // Fallback for schemas where company_ID is a field, not the document id.
    final query = await collection
        .where('company_ID', isEqualTo: companyId)
        .limit(1)
        .get();

    if (query.docs.isEmpty) return null;
    final matched = query.docs.first;
    return CompanyBranding.fromMap(matched.data(), companyId);
  }

  // Company-scoped user queries
  Future<List<AppUser>> getUsersByRoleAndCompany(
    UserRole role,
    String companyId,
  ) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('users')
        .where('role', isEqualTo: _roleToString(role))
        .where('company_ID', isEqualTo: companyId)
        .get();
    return querySnapshot.docs
        .map((doc) => AppUser.fromMap(doc.data(), uid: doc.id))
        .toList();
  }

  Future<List<AppUser>> getAllUsersByCompany(String companyId) async {
    final querySnapshot = await _firebaseService.firestore
        .collection('users')
        .where('company_ID', isEqualTo: companyId)
        .get();
    return querySnapshot.docs
        .map((doc) => AppUser.fromMap(doc.data(), uid: doc.id))
        .toList();
  }

  // Company-scoped route queries
  Future<List<SalesRoute>> getAllRoutesByDateAndCompany(
    String companyId,
    String date,
  ) async {
    final supervisorsSnapshot = await _firebaseService.firestore
        .collection('users')
        .where('company_ID', isEqualTo: companyId)
        .where('role', isEqualTo: 'supervisor')
        .get();

    final supervisorIds =
        supervisorsSnapshot.docs.map((d) => d.id).toList();
    if (supervisorIds.isEmpty) return [];

    // Firestore `whereIn` supports up to 30 items per query.
    final allRoutes = <SalesRoute>[];
    for (var i = 0; i < supervisorIds.length; i += 30) {
      final batch = supervisorIds.sublist(
        i,
        min(i + 30, supervisorIds.length),
      );
      final routeSnapshot = await _firebaseService.firestore
          .collection('routes')
          .where('supervisorId', whereIn: batch)
          .where('date', isEqualTo: date)
          .get();
      allRoutes.addAll(
        routeSnapshot.docs.map(
          (doc) => SalesRoute.fromMap(doc.data(), routeId: doc.id),
        ),
      );
    }
    return allRoutes;
  }

  Future<List<SalesRoute>> getAllRoutesByDateRangeAndCompany({
    required String companyId,
    required String startDate,
    required String endDate,
  }) async {
    final supervisorsSnapshot = await _firebaseService.firestore
        .collection('users')
        .where('company_ID', isEqualTo: companyId)
        .where('role', isEqualTo: 'supervisor')
        .get();

    final supervisorIds =
        supervisorsSnapshot.docs.map((d) => d.id).toList();
    if (supervisorIds.isEmpty) return [];

    final allRoutes = <SalesRoute>[];
    for (var i = 0; i < supervisorIds.length; i += 30) {
      final batch = supervisorIds.sublist(
        i,
        min(i + 30, supervisorIds.length),
      );
      final routeSnapshot = await _firebaseService.firestore
          .collection('routes')
          .where('supervisorId', whereIn: batch)
          .where('date', isGreaterThanOrEqualTo: startDate)
          .where('date', isLessThanOrEqualTo: endDate)
          .get();
      allRoutes.addAll(
        routeSnapshot.docs.map(
          (doc) => SalesRoute.fromMap(doc.data(), routeId: doc.id),
        ),
      );
    }
    return allRoutes;
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
    List<CachedPolylinePoint> points, {
    bool isApproximate = false,
  }) async {
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
      'cachedPolylineApproximate': isApproximate,
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

  Future<void> requestLogoutApproval({required String uid}) async {
    await _firebaseService.firestore.collection('users').doc(uid).update({
      'logoutRequestPending': true,
      'logoutRequestApproved': false,
      'logoutRequestStatus': 'pending',
      'logoutRequestedAt': FieldValue.serverTimestamp(),
      'logoutResolvedAt': null,
      'logoutResolvedBy': null,
    });
  }

  Future<void> resolveLogoutApproval({
    required String uid,
    required bool approved,
    required String resolvedBy,
    required String resolvedByName,
  }) async {
    await _firebaseService.firestore.collection('users').doc(uid).update({
      'logoutRequestPending': false,
      'logoutRequestApproved': approved,
      'logoutRequestStatus': approved ? 'approved' : 'rejected',
      'logoutResolvedAt': FieldValue.serverTimestamp(),
      'logoutResolvedBy': resolvedBy,
      'logoutResolvedByName': resolvedByName,
    });
  }

  Future<void> clearLogoutApproval({required String uid}) async {
    await _firebaseService.firestore.collection('users').doc(uid).update({
      'logoutRequestPending': false,
      'logoutRequestApproved': false,
      'logoutRequestStatus': null,
      'logoutRequestedAt': null,
      'logoutResolvedAt': null,
      'logoutResolvedBy': null,
      'logoutResolvedByName': null,
    });
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

  Future<void> createAnnouncement({
    required String createdBy,
    required UserRole creatorRole,
    required String title,
    required String message,
    required DateTime startAt,
    required DateTime endAt,
    required String occurrence,
    String? imageUrl,
  }) async {
    final firestore = _firebaseService.firestore;
    final trimmedTitle = title.trim();
    final trimmedMessage = message.trim();
    final now = DateTime.now();

    final announcementId = _announcementDocId();

    final announcementData = <String, dynamic>{
      'id': announcementId,
      'createdBy': createdBy,
      'creatorRole': _roleToString(creatorRole),
      'title': trimmedTitle,
      'message': trimmedMessage,
      'startAt': Timestamp.fromDate(startAt),
      'endAt': Timestamp.fromDate(endAt),
      'occurrence': occurrence,
      'imageUrl': imageUrl?.trim() ?? '',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'audience': creatorRole == UserRole.supervisor
          ? 'supervisor_team'
          : 'all_staff',
      if (creatorRole == UserRole.supervisor) 'supervisorId': createdBy,
    };

    final recipientIds = <String>{};
    if (creatorRole == UserRole.supervisor) {
      final team = await firestore
          .collection('users')
          .where('role', isEqualTo: 'salesman')
          .where('supervisorId', isEqualTo: createdBy)
          .get();
      recipientIds.addAll(team.docs.map((doc) => doc.id));
    } else {
      final salesmen = await firestore
          .collection('users')
          .where('role', isEqualTo: 'salesman')
          .get();
      final supervisors = await firestore
          .collection('users')
          .where('role', isEqualTo: 'supervisor')
          .get();
      recipientIds.addAll(salesmen.docs.map((doc) => doc.id));
      recipientIds.addAll(supervisors.docs.map((doc) => doc.id));
    }

    final batch = firestore.batch();
    batch.set(
      firestore.collection('announcements').doc(announcementId),
      announcementData,
    );

    for (final recipientId in recipientIds) {
      final notificationRef = firestore
          .collection('users')
          .doc(recipientId)
          .collection('notifications')
          .doc();
      batch.set(notificationRef, {
        'announcementId': announcementId,
        'title': trimmedTitle,
        'message': trimmedMessage,
        'status': 'info',
        'occurrence': occurrence,
        'imageUrl': imageUrl?.trim() ?? '',
        'startAt': Timestamp.fromDate(startAt),
        'endAt': Timestamp.fromDate(endAt),
        'createdAt': FieldValue.serverTimestamp(),
        'publishedAt': Timestamp.fromDate(now),
        'readAt': null,
      });
    }

    await batch.commit();
  }

  Future<void> updateAnnouncement({
    required String announcementId,
    required String title,
    required String message,
    required DateTime startAt,
    required DateTime endAt,
    required String occurrence,
    String? imageUrl,
  }) async {
    final firestore = _firebaseService.firestore;
    final trimmedTitle = title.trim();
    final trimmedMessage = message.trim();

    final announcementRef = firestore.collection('announcements').doc(announcementId);
    final announcementSnap = await announcementRef.get();
    if (!announcementSnap.exists) {
      throw Exception('Announcement not found.');
    }

    final announcementData = announcementSnap.data() ?? const <String, dynamic>{};
    final audience = announcementData['audience'] as String? ?? 'all_staff';
    final supervisorId = announcementData['supervisorId'] as String?;

    final recipientIds = <String>{};
    if (audience == 'supervisor_team' && supervisorId != null) {
      final team = await firestore
          .collection('users')
          .where('role', isEqualTo: 'salesman')
          .where('supervisorId', isEqualTo: supervisorId)
          .get();
      recipientIds.addAll(team.docs.map((doc) => doc.id));
    } else {
      final salesmen = await firestore
          .collection('users')
          .where('role', isEqualTo: 'salesman')
          .get();
      final supervisors = await firestore
          .collection('users')
          .where('role', isEqualTo: 'supervisor')
          .get();
      recipientIds.addAll(salesmen.docs.map((doc) => doc.id));
      recipientIds.addAll(supervisors.docs.map((doc) => doc.id));
    }

    await announcementRef.update({
      'title': trimmedTitle,
      'message': trimmedMessage,
      'startAt': Timestamp.fromDate(startAt),
      'endAt': Timestamp.fromDate(endAt),
      'occurrence': occurrence,
      'imageUrl': imageUrl?.trim() ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
    });

    try {
      final notificationDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (final recipientId in recipientIds) {
        final snapshot = await firestore
            .collection('users')
            .doc(recipientId)
            .collection('notifications')
            .where('announcementId', isEqualTo: announcementId)
            .get();
        notificationDocs.addAll(snapshot.docs);
      }

      for (var i = 0; i < notificationDocs.length; i += 400) {
        final upper =
            (i + 400 > notificationDocs.length) ? notificationDocs.length : i + 400;
        final batch = firestore.batch();
        for (final doc in notificationDocs.sublist(i, upper)) {
          batch.update(doc.reference, {
            'title': trimmedTitle,
            'message': trimmedMessage,
            'startAt': Timestamp.fromDate(startAt),
            'endAt': Timestamp.fromDate(endAt),
            'occurrence': occurrence,
            'imageUrl': imageUrl?.trim() ?? '',
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
      }
    } on FirebaseException catch (e) {
      // Announcement update already succeeded; do not fail edit UI on fan-out permission gaps.
      if (e.code != 'permission-denied') {
        rethrow;
      }
    }
  }

  Future<void> deleteAnnouncement({required String announcementId}) async {
    final firestore = _firebaseService.firestore;

    final announcementRef = firestore.collection('announcements').doc(announcementId);
    final announcementSnap = await announcementRef.get();
    final announcementData = announcementSnap.data() ?? const <String, dynamic>{};
    final audience = announcementData['audience'] as String? ?? 'all_staff';
    final supervisorId = announcementData['supervisorId'] as String?;

    final recipientIds = <String>{};
    if (audience == 'supervisor_team' && supervisorId != null) {
      final team = await firestore
          .collection('users')
          .where('role', isEqualTo: 'salesman')
          .where('supervisorId', isEqualTo: supervisorId)
          .get();
      recipientIds.addAll(team.docs.map((doc) => doc.id));
    } else {
      final salesmen = await firestore
          .collection('users')
          .where('role', isEqualTo: 'salesman')
          .get();
      final supervisors = await firestore
          .collection('users')
          .where('role', isEqualTo: 'supervisor')
          .get();
      recipientIds.addAll(salesmen.docs.map((doc) => doc.id));
      recipientIds.addAll(supervisors.docs.map((doc) => doc.id));
    }

    await announcementRef.delete();

    try {
      final notificationDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (final recipientId in recipientIds) {
        final snapshot = await firestore
            .collection('users')
            .doc(recipientId)
            .collection('notifications')
            .where('announcementId', isEqualTo: announcementId)
            .get();
        notificationDocs.addAll(snapshot.docs);
      }

      for (var i = 0; i < notificationDocs.length; i += 400) {
        final upper =
            (i + 400 > notificationDocs.length) ? notificationDocs.length : i + 400;
        final batch = firestore.batch();
        for (final doc in notificationDocs.sublist(i, upper)) {
          batch.delete(doc.reference);
        }
        await batch.commit();
      }
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') {
        rethrow;
      }
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchAnnouncementsByCreator({
    required String creatorId,
  }) {
    return _firebaseService.firestore
        .collection('announcements')
        .where('createdBy', isEqualTo: creatorId)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchActiveAnnouncements() {
    return _firebaseService.firestore
        .collection('announcements')
        .where('endAt', isGreaterThanOrEqualTo: Timestamp.now())
        .orderBy('endAt')
        .snapshots();
  }

  Stream<int> watchAnnouncementLikeCount({required String announcementId}) {
    return _firebaseService.firestore
        .collection('announcements')
        .doc(announcementId)
        .collection('likes')
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  Stream<bool> watchIsAnnouncementLiked({
    required String announcementId,
    required String uid,
  }) {
    return _firebaseService.firestore
        .collection('announcements')
        .doc(announcementId)
        .collection('likes')
        .doc(uid)
        .snapshots()
        .map((snapshot) => snapshot.exists);
  }

  Future<void> likeAnnouncement({
    required String announcementId,
    required String uid,
  }) async {
    await _firebaseService.firestore
        .collection('announcements')
        .doc(announcementId)
        .collection('likes')
        .doc(uid)
        .set({
          'uid': uid,
          'likedAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> unlikeAnnouncement({
    required String announcementId,
    required String uid,
  }) async {
    await _firebaseService.firestore
        .collection('announcements')
        .doc(announcementId)
        .collection('likes')
        .doc(uid)
        .delete();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchUserNotifications({
    required String uid,
  }) {
    return _firebaseService.firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<int> watchUnreadUserNotificationCount({required String uid}) {
    return _firebaseService.firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .where('readAt', isNull: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  Future<void> markAllUserNotificationsRead({required String uid}) async {
    final unread = await _firebaseService.firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .where('readAt', isNull: true)
        .get();

    if (unread.docs.isEmpty) return;

    final batch = _firebaseService.firestore.batch();
    for (final doc in unread.docs) {
      batch.update(doc.reference, {'readAt': FieldValue.serverTimestamp()});
    }
    await batch.commit();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchSalesmanNotifications({
    required String uid,
  }) {
    return watchUserNotifications(uid: uid);
  }

  Stream<int> watchUnreadSalesmanNotificationCount({required String uid}) {
    return watchUnreadUserNotificationCount(uid: uid);
  }

  Future<void> markAllSalesmanNotificationsRead({required String uid}) async {
    await markAllUserNotificationsRead(uid: uid);
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
