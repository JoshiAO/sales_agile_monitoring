import 'package:flutter_test/flutter_test.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

void main() {
  group('AppUser Model Tests', () {
    test('should parse valid Map correctly', () {
      final now = DateTime.now();
      final data = {
        'email': 'test@example.com',
        'name': 'Test User',
        'role': 'salesman',
        'active': true,
        'company_ID': 'COMPANY123',
        'logoutRequestedAt': Timestamp.fromDate(now),
      };

      final user = AppUser.fromMap(data, uid: 'user123');

      expect(user.uid, 'user123');
      expect(user.email, 'test@example.com');
      expect(user.name, 'Test User');
      expect(user.role, UserRole.salesman);
      expect(user.active, true);
      expect(user.companyId, 'COMPANY123');
      expect(user.logoutRequestedAt?.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    });

    test('roleToString should return correct string representation', () {
      expect(roleToString(UserRole.salesman), 'salesman');
      expect(roleToString(UserRole.supervisor), 'supervisor');
      expect(roleToString(UserRole.manager), 'manager');
      expect(roleToString(UserRole.superuser), 'superuser');
    });

    test('roleFromString should return correct enum', () {
      expect(roleFromString('salesman'), UserRole.salesman);
      expect(roleFromString('supervisor'), UserRole.supervisor);
      expect(roleFromString('manager'), UserRole.manager);
      expect(roleFromString('superuser'), UserRole.superuser);
      expect(roleFromString('unknown_role'), UserRole.salesman); // fallback
    });
  });
}
