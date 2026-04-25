import 'package:cloud_firestore/cloud_firestore.dart';

class AgileTarget {
  final String salesmanId;
  final String supervisorId;
  final String date;
  final int productiveCallsTarget;
  final double sttTarget;

  const AgileTarget({
    required this.salesmanId,
    required this.supervisorId,
    required this.date,
    required this.productiveCallsTarget,
    required this.sttTarget,
  });

  factory AgileTarget.fromMap(Map<String, dynamic> data) {
    return AgileTarget(
      salesmanId: data['salesmanId'] as String? ?? '',
      supervisorId: data['supervisorId'] as String? ?? '',
      date: data['date'] as String? ?? '',
      productiveCallsTarget: (data['productiveCallsTarget'] as num?)?.toInt() ?? 0,
      sttTarget: ((data['sttTarget'] as num?)?.toDouble() ?? 0.0),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'salesmanId': salesmanId,
      'supervisorId': supervisorId,
      'date': date,
      'productiveCallsTarget': productiveCallsTarget,
      'sttTarget': sttTarget,
    };
  }
}

class AgileSubmission {
  final String salesmanId;
  final String supervisorId;
  final String date;
  final int totalCalls;
  final int productiveCalls;
  final double sttActual;
  final bool lastCallCompleted;
  final bool submitted;
  final DateTime? submittedAt;

  const AgileSubmission({
    required this.salesmanId,
    required this.supervisorId,
    required this.date,
    required this.totalCalls,
    required this.productiveCalls,
    required this.sttActual,
    required this.lastCallCompleted,
    required this.submitted,
    this.submittedAt,
  });

  factory AgileSubmission.fromMap(Map<String, dynamic> data) {
    return AgileSubmission(
      salesmanId: data['salesmanId'] as String? ?? '',
      supervisorId: data['supervisorId'] as String? ?? '',
      date: data['date'] as String? ?? '',
      totalCalls: (data['totalCalls'] as num?)?.toInt() ?? 0,
      productiveCalls: (data['productiveCalls'] as num?)?.toInt() ?? 0,
      sttActual: ((data['sttActual'] as num?)?.toDouble() ?? 0.0),
      lastCallCompleted: data['lastCallCompleted'] as bool? ?? false,
      submitted: data['submitted'] as bool? ?? false,
      submittedAt: (data['submittedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'salesmanId': salesmanId,
      'supervisorId': supervisorId,
      'date': date,
      'totalCalls': totalCalls,
      'productiveCalls': productiveCalls,
      'sttActual': sttActual,
      'lastCallCompleted': lastCallCompleted,
      'submitted': submitted,
      'submittedAt': submittedAt,
    };
  }
}
