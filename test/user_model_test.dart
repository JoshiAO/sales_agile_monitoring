import 'package:flutter_test/flutter_test.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

void main() {
  group('AppUser Model Tests', () {
    test('should parse valid Map correctly and default salesman to Booking', () {
      final now = DateTime.now();
      final data = {
        'email': 'test@example.com',
        'name': 'Test User',
        'role': 'salesman',
        'active': true,
        'company_ID': 'COMPANY123',
        'encoderId': 'enc_01',
        'logoutRequestedAt': Timestamp.fromDate(now),
      };

      final user = AppUser.fromMap(data, uid: 'user123');

      expect(user.uid, 'user123');
      expect(user.email, 'test@example.com');
      expect(user.name, 'Test User');
      expect(user.role, UserRole.salesman);
      expect(user.active, true);
      expect(user.companyId, 'COMPANY123');
      expect(user.encoderId, 'enc_01');
      expect(user.salesmanClassification, SalesmanClassification.booking);
      expect(user.isBooking, true);
      expect(user.isVanExTruck, false);
      expect(
        user.logoutRequestedAt?.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
    });

    test('should parse Van Ex-Truck classification and encoder role correctly', () {
      final vanSalesman = AppUser.fromMap({
        'email': 'van@example.com',
        'role': 'salesman',
        'active': true,
        'salesmanClassification': 'van_ex_truck',
      }, uid: 's_van');

      expect(
        vanSalesman.salesmanClassification,
        SalesmanClassification.vanExTruck,
      );
      expect(vanSalesman.isVanExTruck, true);
      expect(vanSalesman.isBooking, false);
      expect(vanSalesman.toMap()['salesmanClassification'], 'van_ex_truck');

      final encoder = AppUser.fromMap({
        'email': 'encoder@example.com',
        'role': 'encoder',
        'active': true,
      }, uid: 'enc_1');
      expect(encoder.role, UserRole.encoder);
      expect(encoder.toMap()['role'], 'encoder');
    });

    test('roleToString should return correct string representation', () {
      expect(roleToString(UserRole.salesman), 'salesman');
      expect(roleToString(UserRole.supervisor), 'supervisor');
      expect(roleToString(UserRole.manager), 'manager');
      expect(roleToString(UserRole.encoder), 'encoder');
      expect(roleToString(UserRole.superuser), 'superuser');
    });

    test('roleFromString should return correct enum', () {
      expect(roleFromString('salesman'), UserRole.salesman);
      expect(roleFromString('supervisor'), UserRole.supervisor);
      expect(roleFromString('manager'), UserRole.manager);
      expect(roleFromString('encoder'), UserRole.encoder);
      expect(roleFromString('superuser'), UserRole.superuser);
      expect(roleFromString('unknown_role'), UserRole.salesman);
    });
  });
}
