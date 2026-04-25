enum UserRole { salesman, supervisor, superuser }

class AppUser {
  final String uid;
  final String email;
  final String? name;
  final String? fsName;
  final UserRole role;
  final bool active;
  final String? supervisorId;
  final String? profilePic;

  AppUser({
    required this.uid,
    required this.email,
    this.name,
    this.fsName,
    required this.role,
    required this.active,
    this.supervisorId,
    this.profilePic,
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
