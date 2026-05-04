import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
  String? _selectedSupervisorFilterId;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      _supervisors = await _firestoreService.getUsersByRole(
        UserRole.supervisor,
      );
      _superusers = await _firestoreService.getUsersByRole(UserRole.superuser);

      final salesmen = await _firestoreService.getUsersByRole(
        UserRole.salesman,
      );
      _allUsers = [..._superusers, ..._supervisors, ...salesmen];
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error loading users: $e')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _getSupervisorName(String? supervisorId) {
    if (supervisorId == null) return 'Not assigned';
    final supervisor = _supervisors
        .where((u) => u.uid == supervisorId)
        .firstOrNull;
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

  String _emailCode(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex <= 0) return email.toUpperCase();
    return email.substring(0, atIndex).toUpperCase();
  }

  int _compareByEmailCode(AppUser left, AppUser right) {
    final codeCompare = _emailCode(
      left.email,
    ).compareTo(_emailCode(right.email));
    if (codeCompare != 0) return codeCompare;
    return left.email.toLowerCase().compareTo(right.email.toLowerCase());
  }

  String _activeFilterLabel() {
    final filterId = _selectedSupervisorFilterId;
    if (filterId == null) return '';
    final supervisor = _supervisors.where((u) => u.uid == filterId).firstOrNull;
    return supervisor == null
        ? ''
        : (supervisor.name?.trim().isNotEmpty == true
              ? supervisor.name!
              : supervisor.email);
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
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard(AppUser user) {
    final isFilterSelected =
        user.role == UserRole.supervisor &&
        _selectedSupervisorFilterId == user.uid;
    final displayName = user.name?.trim() ?? '';
    final showNameLine = displayName.isNotEmpty;
    final title = showNameLine ? displayName : user.email;
    final showEmailLine =
        showNameLine &&
        displayName.toLowerCase() != user.email.trim().toLowerCase();

    final roleBg = switch (user.role) {
      UserRole.superuser => Colors.purple.shade50,
      UserRole.supervisor => Colors.blue.shade50,
      UserRole.salesman => Colors.grey.shade100,
    };
    final roleFg = switch (user.role) {
      UserRole.superuser => Colors.purple.shade700,
      UserRole.supervisor => Colors.blue.shade700,
      UserRole.salesman => Colors.grey.shade700,
    };
    final statusBg = user.active ? Colors.green.shade50 : Colors.orange.shade50;
    final statusFg = user.active
        ? Colors.green.shade700
        : Colors.orange.shade700;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isFilterSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.grey.shade300,
          width: isFilterSelected ? 1.4 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _UserBadge(
                  label: _roleLabel(user.role),
                  backgroundColor: roleBg,
                  foregroundColor: roleFg,
                ),
              ],
            ),
            if (showEmailLine) ...[
              const SizedBox(height: 4),
              Text(
                user.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
              ),
            ],
            const SizedBox(height: 8),
            _UserBadge(
              label: user.active ? 'Active' : 'Inactive',
              backgroundColor: statusBg,
              foregroundColor: statusFg,
            ),
            if (isFilterSelected) ...[
              const SizedBox(height: 6),
              _UserBadge(
                label: 'Filter Active',
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                foregroundColor: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer,
              ),
            ],
            if (user.role == UserRole.salesman) ...[
              const SizedBox(height: 6),
              Text(
                'Supervisor: ${_getSupervisorName(user.supervisorId)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700),
              ),
            ],
            const Spacer(),
            if (user.role != UserRole.superuser)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (user.role == UserRole.supervisor)
                    IconButton(
                      tooltip: 'Filter Salesmen',
                      icon: Icon(
                        _selectedSupervisorFilterId == user.uid
                            ? Icons.filter_alt
                            : Icons.filter_alt_outlined,
                        size: 20,
                        color: _selectedSupervisorFilterId == user.uid
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      onPressed: () {
                        setState(() {
                          _selectedSupervisorFilterId =
                              _selectedSupervisorFilterId == user.uid
                              ? null
                              : user.uid;
                        });
                      },
                    ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                    onPressed: () => _showDeleteUserDialog(user),
                  ),
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _showEditUserDialog(user),
                  ),
                ],
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
                      const SnackBar(content: Text('Please fill all fields')),
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
                      const SnackBar(
                        content: Text('User created successfully'),
                      ),
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
                    decoration: const InputDecoration(labelText: 'Name'),
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
                  final normalizedEmail = emailController.text
                      .trim()
                      .toLowerCase();
                  if (normalizedEmail.isEmpty) {
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(content: Text('Email is required')),
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
                  ScaffoldMessenger.of(
                    rootContext,
                  ).showSnackBar(SnackBar(content: Text('Delete error: $e')));
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
        title: const Text('Manage Users'),
        actions: [
          if (_selectedSupervisorFilterId != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () {
                  setState(() => _selectedSupervisorFilterId = null);
                },
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Remove Filter'),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddUserDialog,
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final supervisorsOnly =
                    _allUsers
                        .where((u) => u.role == UserRole.supervisor)
                        .toList()
                      ..sort(_compareByEmailCode);
                final salesmenOnly =
                    _allUsers.where((u) => u.role == UserRole.salesman).toList()
                      ..sort(_compareByEmailCode);
                final visibleSalesmen = _selectedSupervisorFilterId == null
                    ? salesmenOnly
                    : salesmenOnly
                          .where(
                            (u) =>
                                u.supervisorId == _selectedSupervisorFilterId,
                          )
                          .toList();
                final filterLabel = _activeFilterLabel();

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = _cardsPerRow(constraints.maxWidth);
                    const spacing = 12.0;
                    const cardHeight = 180.0;

                    Widget buildSectionGrid(List<AppUser> users) {
                      if (users.isEmpty) return const SizedBox.shrink();
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: users.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: spacing,
                          mainAxisSpacing: spacing,
                          mainAxisExtent: cardHeight,
                        ),
                        itemBuilder: (_, i) => _buildUserCard(users[i]),
                      );
                    }

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                      children: [
                        _buildSectionHeader('Supervisors'),
                        if (supervisorsOnly.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text('No supervisors found.'),
                          )
                        else
                          buildSectionGrid(supervisorsOnly),
                        _buildSectionHeader('Salesmen'),
                        if (_selectedSupervisorFilterId != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              filterLabel.isEmpty
                                  ? 'Filter active'
                                  : 'Filtered by: $filterLabel',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        if (visibleSalesmen.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text('No salesmen found for this filter.'),
                          )
                        else
                          buildSectionGrid(visibleSalesmen),
                      ],
                    );
                  },
                );
              },
            ),
    );
  }

  int _cardsPerRow(double maxWidth) {
    final isMobileLayout = !kIsWeb && maxWidth < 700;
    if (isMobileLayout) return 1;
    const minCardWidth = 320.0;
    final columns = ((maxWidth + 12) / (minCardWidth + 12)).floor();
    return columns.clamp(2, 4);
  }
}

class _UserBadge extends StatelessWidget {
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  const _UserBadge({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: foregroundColor,
        ),
      ),
    );
  }
}
