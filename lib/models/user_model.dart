enum UserRole { salesman, supervisor, superuser }

DateTime? _dateTimeFromDynamic(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }

  try {
    return (value as dynamic).toDate() as DateTime;
  } catch (_) {
    return null;
  }
}

class AppUser {
  final String uid;
  final String email;
  final String? name;
  final String? fsName;
  final UserRole role;
  final bool active;
  final String? supervisorId;
  final String? profilePic;
  final bool logoutRequestPending;
  final bool logoutRequestApproved;
  final String? logoutRequestStatus;
  final DateTime? logoutRequestedAt;
  final DateTime? logoutResolvedAt;
  final String? logoutResolvedBy;
  final String? logoutResolvedByName;
  final String? companyId;

  AppUser({
    required this.uid,
    required this.email,
    this.name,
    this.fsName,
    required this.role,
    required this.active,
    this.supervisorId,
    this.profilePic,
    required this.logoutRequestPending,
    required this.logoutRequestApproved,
    this.logoutRequestStatus,
    this.logoutRequestedAt,
    this.logoutResolvedAt,
    this.logoutResolvedBy,
    this.logoutResolvedByName,
    this.companyId,
  });

  factory AppUser.fromMap(Map<String, dynamic> data, {required String uid}) {
    return AppUser(
      uid: uid,
      email: data['email'] as String? ?? '',
      name: data['name'] as String?,
      fsName: data['fsName'] as String?,
      role: _roleFromString(data['role'] as String? ?? 'salesman'),
      active: data['active'] as bool? ?? false,
      supervisorId: data['supervisorId'] as String?,
      profilePic: data['profilePic'] as String?,
      logoutRequestPending: data['logoutRequestPending'] as bool? ?? false,
      logoutRequestApproved: data['logoutRequestApproved'] as bool? ?? false,
      logoutRequestStatus: data['logoutRequestStatus'] as String?,
      logoutRequestedAt: _dateTimeFromDynamic(data['logoutRequestedAt']),
      logoutResolvedAt: _dateTimeFromDynamic(data['logoutResolvedAt']),
      logoutResolvedBy: data['logoutResolvedBy'] as String?,
      logoutResolvedByName: data['logoutResolvedByName'] as String?,
      companyId: ((data['company_ID'] ??
                  data['companyId'] ??
                  data['company_id'] ??
                  data['companyID']) as String?)
              ?.trim(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'email': email,
      'name': name,
      'fsName': fsName,
      'role': _roleToString(role),
      'active': active,
      'supervisorId': supervisorId,
      'profilePic': profilePic,
      'logoutRequestPending': logoutRequestPending,
      'logoutRequestApproved': logoutRequestApproved,
      'logoutRequestStatus': logoutRequestStatus,
      'logoutRequestedAt': logoutRequestedAt,
      'logoutResolvedAt': logoutResolvedAt,
      'logoutResolvedBy': logoutResolvedBy,
      'logoutResolvedByName': logoutResolvedByName,
      'company_ID': companyId,
    };
  }

  AppUser copyWith({
    String? uid,
    String? email,
    String? name,
    String? fsName,
    UserRole? role,
    bool? active,
    String? supervisorId,
    String? profilePic,
    bool? logoutRequestPending,
    bool? logoutRequestApproved,
    String? logoutRequestStatus,
    DateTime? logoutRequestedAt,
    DateTime? logoutResolvedAt,
    String? logoutResolvedBy,
    String? logoutResolvedByName,
    String? companyId,
  }) {
    return AppUser(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      name: name ?? this.name,
      fsName: fsName ?? this.fsName,
      role: role ?? this.role,
      active: active ?? this.active,
      supervisorId: supervisorId ?? this.supervisorId,
      profilePic: profilePic ?? this.profilePic,
      logoutRequestPending: logoutRequestPending ?? this.logoutRequestPending,
      logoutRequestApproved:
          logoutRequestApproved ?? this.logoutRequestApproved,
      logoutRequestStatus: logoutRequestStatus ?? this.logoutRequestStatus,
      logoutRequestedAt: logoutRequestedAt ?? this.logoutRequestedAt,
      logoutResolvedAt: logoutResolvedAt ?? this.logoutResolvedAt,
      logoutResolvedBy: logoutResolvedBy ?? this.logoutResolvedBy,
      logoutResolvedByName: logoutResolvedByName ?? this.logoutResolvedByName,
      companyId: companyId ?? this.companyId,
    );
  }
}

UserRole _roleFromString(String role) {
  switch (role) {
    case 'salesman':
      return UserRole.salesman;
    case 'supervisor':
      return UserRole.supervisor;
    case 'superuser':
      return UserRole.superuser;
    default:
      return UserRole.salesman;
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
