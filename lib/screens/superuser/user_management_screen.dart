import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/user_provisioning_service.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final UserProvisioningService _userProvisioningService =
      UserProvisioningService();
  List<AppUser> _allUsers = [];
  List<AppUser> _supervisors = [];
  List<AppUser> _superusers = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      _supervisors = await _firestoreService.getUsersByRole(UserRole.supervisor);
      _superusers = await _firestoreService.getUsersByRole(UserRole.superuser);

      final salesmen = await _firestoreService.getUsersByRole(UserRole.salesman);
      _allUsers = [..._superusers, ..._supervisors, ...salesmen];
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading users: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _getSupervisorName(String? supervisorId) {
    if (supervisorId == null) return 'Not assigned';
    final supervisor = _supervisors.where((u) => u.uid == supervisorId).firstOrNull;
    if (supervisor == null) return 'Not assigned';
    return supervisor.name ?? supervisor.email;
  }

  String _roleLabel(UserRole role) {
    switch (role) {
      case UserRole.salesman:
        return 'Salesman';
      case UserRole.supervisor:
        return 'Supervisor';
      case UserRole.superuser:
        return 'Superuser';
    }
  }

  String _formatError(Object error) {
    final message = error.toString();
    return message.startsWith('Exception: ')
        ? message.substring('Exception: '.length)
        : message;
  }

  Future<T> _runWithBlockingLoader<T>(
    BuildContext rootContext,
    Future<T> Function() action,
  ) async {
    showDialog<void>(
      context: rootContext,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      return await action();
    } finally {
      if (rootContext.mounted) {
        Navigator.of(rootContext, rootNavigator: true).pop();
      }
    }
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard(AppUser user) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Icon(
            user.role == UserRole.salesman
                ? Icons.person
                : Icons.supervisor_account,
          ),
        ),
        title: Text(user.name ?? user.email),
        subtitle: Text(
          user.role == UserRole.salesman
              ? 'Supervisor/FS Assigned: ${_getSupervisorName(user.supervisorId)}\n'
                  'Role: ${_roleLabel(user.role)}\n'
                  'Status: ${user.active ? 'Active' : 'Inactive'}'
              : 'Role: ${_roleLabel(user.role)}\n'
                  'Status: ${user.active ? 'Active' : 'Inactive'}\n'
                  'Email: ${user.email}',
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (user.role != UserRole.superuser)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: () => _showDeleteUserDialog(user),
              ),
            if (user.role != UserRole.superuser)
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => _showEditUserDialog(user),
              ),
          ],
        ),
      ),
    );
  }

  void _showAddUserDialog() {
    final rootContext = context;
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    UserRole selectedRole = UserRole.salesman;
    String? selectedSupervisorId;
    bool isActive = true;
    bool obscurePassword = true;

    showDialog(
      context: rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          return AlertDialog(
            title: const Text('Add New User'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'Enter full name',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      hintText: 'user@example.com',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      hintText: 'At least 6 characters',
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() => obscurePassword = !obscurePassword);
                        },
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButton<UserRole>(
                    value: selectedRole,
                    isExpanded: true,
                    items: [UserRole.salesman, UserRole.supervisor].map((role) {
                      return DropdownMenuItem(
                        value: role,
                        child: Text(_roleLabel(role)),
                      );
                    }).toList(),
                    onChanged: (role) {
                      if (role != null) {
                        setState(() {
                          selectedRole = role;
                          if (selectedRole != UserRole.salesman) {
                            selectedSupervisorId = null;
                          }
                        });
                      }
                    },
                  ),
                  if (selectedRole == UserRole.salesman) ...[
                    const SizedBox(height: 12),
                    DropdownButton<String>(
                      value: selectedSupervisorId,
                      hint: const Text('Select Supervisor'),
                      isExpanded: true,
                      items: _supervisors.map((supervisor) {
                        return DropdownMenuItem(
                          value: supervisor.uid,
                          child: Text(supervisor.name ?? supervisor.email),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() => selectedSupervisorId = value);
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Status (Active)'),
                    value: isActive,
                    onChanged: (value) {
                      setState(() => isActive = value);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (emailController.text.isEmpty ||
                      passwordController.text.isEmpty) {
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(
                        content: Text('Please fill all fields'),
                      ),
                    );
                    return;
                  }

                  if (selectedRole == UserRole.salesman &&
                      selectedSupervisorId == null) {
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(
                        content: Text('Please select a supervisor'),
                      ),
                    );
                    return;
                  }

                  try {
                    await _runWithBlockingLoader(rootContext, () async {
                      await _userProvisioningService.createManagedUser(
                        email: emailController.text,
                        password: passwordController.text,
                        name: nameController.text.trim().isEmpty
                            ? null
                            : nameController.text.trim(),
                        active: isActive,
                        role: selectedRole,
                        supervisorId: selectedRole == UserRole.salesman
                            ? selectedSupervisorId
                            : null,
                      );
                    });

                    if (!mounted) return;
                    await _loadUsers();
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    if (!rootContext.mounted) return;
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(content: Text('User created successfully')),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    if (!rootContext.mounted) return;
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      SnackBar(content: Text('Error: ${_formatError(e)}')),
                    );
                  }
                },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showEditUserDialog(AppUser user) {
    final rootContext = context;
    final nameController = TextEditingController(text: user.name ?? '');
    final emailController = TextEditingController(text: user.email);
    final passwordController = TextEditingController();
    UserRole selectedRole = user.role;
    String? selectedSupervisorId = user.supervisorId;
    bool isActive = user.active;
    bool obscurePassword = true;

    showDialog(
      context: rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          return AlertDialog(
            title: Text('Edit ${user.email}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      hintText: 'user@example.com',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'New Password',
                      hintText: 'Leave blank to keep current password',
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() => obscurePassword = !obscurePassword);
                        },
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButton<UserRole>(
                    value: selectedRole,
                    isExpanded: true,
                    items: [UserRole.salesman, UserRole.supervisor]
                        .map((role) {
                      return DropdownMenuItem(
                        value: role,
                        child: Text(_roleLabel(role)),
                      );
                    }).toList(),
                    onChanged: (role) {
                      if (role != null) {
                        setState(() {
                          selectedRole = role;
                          if (selectedRole != UserRole.salesman) {
                            selectedSupervisorId = null;
                          }
                        });
                      }
                    },
                  ),
                  if (selectedRole == UserRole.salesman) ...[
                    const SizedBox(height: 12),
                    DropdownButton<String>(
                      value: selectedSupervisorId,
                      hint: const Text('Select Supervisor'),
                      isExpanded: true,
                      items: _supervisors.map((supervisor) {
                        return DropdownMenuItem(
                          value: supervisor.uid,
                          child: Text(supervisor.name ?? supervisor.email),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() => selectedSupervisorId = value);
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: const Text('Active'),
                    value: isActive,
                    onChanged: (value) {
                      setState(() => isActive = value);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final normalizedEmail = emailController.text.trim().toLowerCase();
                  if (normalizedEmail.isEmpty) {
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(content: Text('Email is required')),
                    );
                    return;
                  }

                  if (selectedRole == UserRole.salesman &&
                      selectedSupervisorId == null) {
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(content: Text('Please select a supervisor')),
                    );
                    return;
                  }

                  try {
                    await _runWithBlockingLoader(rootContext, () async {
                      await _userProvisioningService.updateManagedUser(
                        uid: user.uid,
                        currentEmail: user.email,
                        newEmail: normalizedEmail,
                        newPassword: passwordController.text,
                        name: nameController.text,
                        active: isActive,
                        role: selectedRole,
                        supervisorId: selectedRole == UserRole.salesman
                            ? selectedSupervisorId
                            : null,
                      );
                    });

                    if (!mounted) return;
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    await _loadUsers();
                    if (!rootContext.mounted) return;
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(content: Text('User updated')),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    if (!rootContext.mounted) return;
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      SnackBar(content: Text('Error: ${_formatError(e)}')),
                    );
                  }
                },
                child: const Text('Update'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showDeleteUserDialog(AppUser user) {
    final rootContext = context;
    showDialog(
      context: rootContext,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete User'),
          content: Text(
            'Delete ${user.name ?? user.email}?\n\nThis will remove the user document. Salesman routes are also deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                try {
                  await _firestoreService.deleteUserData(
                    uid: user.uid,
                    role: user.role,
                  );

                  if (!mounted) return;
                  if (!dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  await _loadUsers();
                  if (!rootContext.mounted) return;
                  ScaffoldMessenger.of(rootContext).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'User deleted from app database. Auth account may still exist.',
                      ),
                    ),
                  );
                } catch (e) {
                  if (!mounted) return;
                  if (!rootContext.mounted) return;
                  ScaffoldMessenger.of(rootContext).showSnackBar(
                    SnackBar(content: Text('Delete error: $e')),
                  );
                }
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Management'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddUserDialog,
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final supervisorsOnly = _allUsers
                    .where((u) => u.role == UserRole.supervisor)
                    .toList();
                final salesmenOnly = _allUsers
                    .where((u) => u.role == UserRole.salesman)
                    .toList();

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildSectionHeader('Supervisors'),
                    if (supervisorsOnly.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('No supervisors found.'),
                      ),
                    ...supervisorsOnly.map(_buildUserCard),
                    _buildSectionHeader('Salesmen'),
                    if (salesmenOnly.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('No salesmen found.'),
                      ),
                    ...salesmenOnly.map(_buildUserCard),
                  ],
                );
              },
            ),
    );
  }
}
