import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class PushNotificationService {
  static final PushNotificationService _instance =
      PushNotificationService._internal();

  factory PushNotificationService() => _instance;

  PushNotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirestoreService _firestoreService = FirestoreService();
  StreamSubscription<String>? _tokenRefreshSubscription;
  String? _boundUserId;

  Future<void> bindUser(AppUser? user) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    if (user == null || user.role != UserRole.salesman) {
      return;
    }

    final permission = await _messaging.requestPermission();
    final authorized =
        permission.authorizationStatus == AuthorizationStatus.authorized ||
        permission.authorizationStatus == AuthorizationStatus.provisional;
    if (!authorized) {
      return;
    }

    _boundUserId = user.uid;

    final token = await _messaging.getToken();
    if (token != null && token.isNotEmpty) {
      await _firestoreService.updateUser(user.uid, {
        'fcmToken': token,
        'fcmTokenUpdatedAt': DateTime.now(),
      });
    }

    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) {
      final uid = _boundUserId;
      if (uid == null || newToken.isEmpty) return;

      _firestoreService.updateUser(uid, {
        'fcmToken': newToken,
        'fcmTokenUpdatedAt': DateTime.now(),
      });
    });
  }

  Future<void> unbindCurrentUser({String? uid}) async {
    final targetUid = uid ?? _boundUserId;
    if (targetUid != null) {
      try {
        await _firestoreService.updateUser(targetUid, {
          'fcmToken': null,
          'fcmTokenUpdatedAt': null,
        });
      } catch (_) {}
    }

    _boundUserId = null;
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
  }
}
