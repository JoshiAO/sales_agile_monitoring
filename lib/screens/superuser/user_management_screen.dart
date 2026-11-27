import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/widgets/device_activation_banner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';
import 'package:compact_sales_monitoring/services/user_provisioning_service.dart';
import 'package:compact_sales_monitoring/widgets/profile_image_crop_dialog.dart';
import 'package:compact_sales_monitoring/widgets/user_avatar.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final StorageService _storageService = StorageService();
  final ImagePicker _imagePicker = ImagePicker();
  final UserProvisioningService _userProvisioningService =
      UserProvisioningService();

  List<AppUser> _allUsers = [];
  List<AppUser> _supervisors = [];
  List<AppUser> _encoders = [];
  String? _selectedSupervisorFilterId;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers({bool silent = false}) async {
    if (!silent || _allUsers.isEmpty) {
      setState(() => _isLoading = true);
    }
    try {
      final companyId =
          context.read<AuthProvider>().currentUser?.companyId;

      final List<AppUser> superusers;
      final List<AppUser> managers;
      final List<AppUser> salesmen;

      if (companyId != null && companyId.isNotEmpty) {
        final results = await Future.wait([
          _firestoreService.getUsersByRoleAndCompany(
            UserRole.superuser,
            companyId,
          ),
          _firestoreService.getUsersByRoleAndCompany(
            UserRole.manager,
            companyId,
          ),
          _firestoreService.getUsersByRoleAndCompany(
            UserRole.supervisor,
            companyId,
          ),
          _firestoreService.getUsersByRoleAndCompany(
            UserRole.encoder,
            companyId,
          ),
          _firestoreService.getUsersByRoleAndCompany(
            UserRole.salesman,
            companyId,
          ),
        ]);
        superusers = results[0];
        managers = results[1];
        _supervisors = results[2];
        _encoders = results[3];
        salesmen = results[4];
      } else {
        final results = await Future.wait([
          _firestoreService.getUsersByRole(UserRole.superuser),
          _firestoreService.getUsersByRole(UserRole.manager),
          _firestoreService.getUsersByRole(UserRole.supervisor),
          _firestoreService.getUsersByRole(UserRole.encoder),
          _firestoreService.getUsersByRole(UserRole.salesman),
        ]);
        superusers = results[0];
        managers = results[1];
        _supervisors = results[2];
        _encoders = results[3];
        salesmen = results[4];
      }

      _allUsers = [
        ...superusers,
        ...managers,
        ..._supervisors,
        ..._encoders,
        ...salesmen,
      ];
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error loading users: $e')));
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<String?> _pickCropAndUploadProfilePhoto(AppUser user) async {
    final rootContext = context;
    try {
      final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (picked == null) return null;

      final sourceBytes = await picked.readAsBytes();
      if (!mounted || !rootContext.mounted) return null;

      final displayName = (user.name?.trim().isNotEmpty ?? false)
          ? user.name!.trim()
          : user.email;

      final cropped = await ProfileImageCropDialog.show(
        rootContext,
        imageBytes: sourceBytes,
        userDisplayName: displayName,
      );
      if (cropped == null || !mounted || !rootContext.mounted) return null;

      late final String uploadedUrl;
      await _runWithBlockingLoader(rootContext, () async {
        uploadedUrl = await _storageService.uploadProfilePicBytes(
          cropped.bytes,
          user.uid,
        );
        await _firestoreService.updateUser(user.uid, {
          'profilePic': uploadedUrl,
        });
      });

      if (!mounted) return uploadedUrl;
      await _loadUsers(silent: true);
      if (rootContext.mounted) {
        final kb = (cropped.bytes.length / 1024).toStringAsFixed(0);
        ScaffoldMessenger.of(rootContext).showSnackBar(
          SnackBar(content: Text('Profile photo updated ($kb KB)')),
        );
      }
      return uploadedUrl;
    } catch (e) {
      if (mounted && rootContext.mounted) {
        ScaffoldMessenger.of(rootContext).showSnackBar(
          SnackBar(content: Text('Photo upload error: ${_formatError(e)}')),
        );
      }
      return null;
    }
  }

  Future<bool> _removeProfilePhoto(AppUser user) async {
    final rootContext = context;
    final existingUrl = user.profilePic;
    if (existingUrl == null || existingUrl.isEmpty) return false;
    try {
      await _runWithBlockingLoader(rootContext, () async {
        await _storageService.deleteImage(existingUrl);
        await _firestoreService.updateUser(user.uid, {'profilePic': null});
      });
      if (!mounted) return true;
      await _loadUsers(silent: true);
      if (rootContext.mounted) {
        ScaffoldMessenger.of(rootContext).showSnackBar(
          const SnackBar(content: Text('Profile photo removed')),
        );
      }
      return true;
    } catch (e) {
      if (mounted && rootContext.mounted) {
        ScaffoldMessenger.of(rootContext).showSnackBar(
          SnackBar(content: Text('Remove photo error: ${_formatError(e)}')),
        );
      }
      return false;
    }
  }

  String _roleLabel(UserRole role) {
    switch (role) {
      case UserRole.salesman:
        return 'Salesman';
      case UserRole.supervisor:
        return 'Supervisor';
      case UserRole.manager:
        return 'Manager';
      case UserRole.encoder:
        return 'Encoder';
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

  String _formatDateTime(DateTime? value) {
    if (value == null) return 'Not available';
    return DateFormat('MMM d, yyyy h:mm a').format(value.toLocal());
  }

  String _emailCode(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex <= 0) return email.toUpperCase();
    return email.substring(0, atIndex).toUpperCase();
  }

  int _compareByEmailCode(AppUser left, AppUser right) {
    final codeCompare = _emailCode(left.email).compareTo(_emailCode(right.email));
    if (codeCompare != 0) return codeCompare;
    return left.email.toLowerCase().compareTo(right.email.toLowerCase());
  }

  String _getSupervisorName(String? supervisorId) {
    if (supervisorId == null) return 'Not assigned';
    final supervisor = _supervisors.where((u) => u.uid == supervisorId).firstOrNull;
    if (supervisor == null) return 'Not assigned';
    return (supervisor.name?.trim().isNotEmpty == true)
        ? supervisor.name!
        : supervisor.email;
  }

  String _getEncoderName(String? encoderId) {
    if (encoderId == null || encoderId.isEmpty) return 'Not assigned';
    final encoder = _encoders.where((u) => u.uid == encoderId).firstOrNull;
    if (encoder == null) return 'Not assigned';
    return (encoder.name?.trim().isNotEmpty == true)
        ? encoder.name!
        : encoder.email;
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
    final hasLogoutRequest =
        user.role == UserRole.salesman && user.logoutRequestPending;
    final isFilterSelected =
        user.role == UserRole.supervisor &&
        _selectedSupervisorFilterId == user.uid;

    final displayName = user.name?.trim() ?? '';
    final showNameLine = displayName.isNotEmpty;
    final title = showNameLine ? displayName : user.email;
    final showEmailLine =
        showNameLine && displayName.toLowerCase() != user.email.trim().toLowerCase();

    final roleBg = switch (user.role) {
      UserRole.superuser => Colors.purple.shade50,
      UserRole.manager => Colors.teal.shade50,
      UserRole.supervisor => Colors.blue.shade50,
      UserRole.encoder => Colors.indigo.shade50,
      UserRole.salesman => Colors.grey.shade100,
    };
    final roleFg = switch (user.role) {
      UserRole.superuser => Colors.purple.shade700,
      UserRole.manager => Colors.teal.shade700,
      UserRole.supervisor => Colors.blue.shade700,
      UserRole.encoder => Colors.indigo.shade700,
      UserRole.salesman => Colors.grey.shade700,
    };
    final statusBg = user.active ? Colors.green.shade50 : Colors.orange.shade50;
    final statusFg = user.active ? Colors.green.shade700 : Colors.orange.shade700;

    return Stack(
      children: [
        Card(
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
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Tooltip(
                      message: 'Upload / Change Profile Photo',
                      child: UserAvatar(
                        profilePicUrl: user.profilePic,
                        displayName: title,
                        radius: 21,
                        showEditBadge: true,
                        onTap: () => _pickCropAndUploadProfilePhoto(user),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (showEmailLine) ...[
                            const SizedBox(height: 2),
                            Text(
                              user.email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ],
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
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _UserBadge(
                      label: user.active ? 'Active' : 'Inactive',
                      backgroundColor: statusBg,
                      foregroundColor: statusFg,
                    ),
                    if (user.role == UserRole.salesman)
                      _UserBadge(
                        label: classificationLabel(user.salesmanClassification),
                        backgroundColor: user.isVanExTruck
                            ? Colors.teal.shade50
                            : Colors.amber.shade50,
                        foregroundColor: user.isVanExTruck
                            ? Colors.teal.shade800
                            : Colors.amber.shade900,
                      ),
                    if (isFilterSelected)
                      _UserBadge(
                        label: 'Filter Active',
                        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                        foregroundColor:
                            Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                  ],
                ),
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
                  const SizedBox(height: 2),
                  Text(
                    'Encoder: ${_getEncoderName(user.encoderId)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700),
                  ),
                ],
                const SizedBox(height: 10),
                if (user.role != UserRole.superuser)
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 2,
                    runSpacing: 2,
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
                        tooltip: 'Upload Profile Photo',
                        icon: const Icon(Icons.add_a_photo_outlined, size: 20),
                        onPressed: () => _pickCropAndUploadProfilePhoto(user),
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
        ),
        if (hasLogoutRequest)
          Positioned(
            left: 10,
            bottom: 10,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => _showLogoutRequestDecisionDialog(user),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.red.shade600,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Logout Request',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _formatDateTime(user.logoutRequestedAt),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showLogoutRequestDecisionDialog(AppUser user) {
    final rootContext = context;
    final requesterName = user.name?.trim().isNotEmpty == true
        ? user.name!
        : user.email;
    final requestedAtText = _formatDateTime(user.logoutRequestedAt);
    final lastResolvedAtText = _formatDateTime(user.logoutResolvedAt);
    final lastResolvedByText = user.logoutResolvedByName ?? 'Not available';

    showDialog(
      context: rootContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Logout Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$requesterName requested to log out.'),
            const SizedBox(height: 8),
            Text('Requested at: $requestedAtText'),
            const SizedBox(height: 4),
            Text('Last approver: $lastResolvedByText'),
            const SizedBox(height: 4),
            Text('Last resolved at: $lastResolvedAtText'),
            const SizedBox(height: 12),
            const Text('Approve or reject this request?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              try {
                final approver = rootContext.read<AuthProvider>().currentUser;
                final approverId = approver?.uid ?? 'unknown';
                final approverName = approver?.name?.trim().isNotEmpty == true
                    ? approver!.name!
                    : (approver?.email ?? 'Unknown');

                await _firestoreService.resolveLogoutApproval(
                  uid: user.uid,
                  approved: false,
                  resolvedBy: approverId,
                  resolvedByName: approverName,
                );

                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                await _loadUsers(silent: true);
                if (!rootContext.mounted) return;
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  const SnackBar(content: Text('Logout request rejected.')),
                );
              } catch (error) {
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                if (!rootContext.mounted) return;
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  SnackBar(content: Text('Failed to reject request: $error')),
                );
              }
            },
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                final approver = rootContext.read<AuthProvider>().currentUser;
                final approverId = approver?.uid ?? 'unknown';
                final approverName = approver?.name?.trim().isNotEmpty == true
                    ? approver!.name!
                    : (approver?.email ?? 'Unknown');

                await _firestoreService.resolveLogoutApproval(
                  uid: user.uid,
                  approved: true,
                  resolvedBy: approverId,
                  resolvedByName: approverName,
                );

                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                await _loadUsers(silent: true);
                if (!rootContext.mounted) return;
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  const SnackBar(content: Text('Logout request approved.')),
                );
              } catch (error) {
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                if (!rootContext.mounted) return;
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  SnackBar(content: Text('Failed to approve request: $error')),
                );
              }
            },
            child: const Text('Approve'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddUserDialog() async {
    final rootContext = context;
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    UserRole selectedRole = UserRole.salesman;
    String? selectedSupervisorId;
    String? selectedEncoderId;
    SalesmanClassification selectedClassification =
        SalesmanClassification.booking;
    bool isActive = true;
    bool obscurePassword = true;

    try {
      await showDialog<void>(
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
                    items: [
                      UserRole.salesman,
                      UserRole.supervisor,
                      UserRole.encoder,
                      UserRole.manager,
                    ].map((role) {
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
                            selectedEncoderId = null;
                          }
                        });
                      }
                    },
                  ),
                  if (selectedRole == UserRole.salesman) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<SalesmanClassification>(
                      initialValue: selectedClassification,
                      decoration: const InputDecoration(
                        labelText: 'Salesman Classification',
                        isDense: true,
                      ),
                      items: SalesmanClassification.values.map((c) {
                        return DropdownMenuItem(
                          value: c,
                          child: Text(classificationLabel(c)),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => selectedClassification = value);
                        }
                      },
                    ),
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
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      initialValue: _encoders.any((e) => e.uid == selectedEncoderId)
                          ? selectedEncoderId
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Assigned Encoder (Optional)',
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None'),
                        ),
                        ..._encoders.map((encoder) {
                          return DropdownMenuItem<String?>(
                            value: encoder.uid,
                            child: Text(encoder.name ?? encoder.email),
                          );
                        }),
                      ],
                      onChanged: (value) {
                        setState(() => selectedEncoderId = value);
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
                      final companyId = rootContext
                          .read<AuthProvider>()
                          .currentUser
                          ?.companyId;
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
                        encoderId: selectedRole == UserRole.salesman
                            ? selectedEncoderId
                            : null,
                        salesmanClassification: selectedClassification,
                        companyId: companyId,
                      );
                    });

                    if (!mounted) return;
                    await _loadUsers(silent: true);
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
    } finally {
      nameController.dispose();
      emailController.dispose();
      passwordController.dispose();
    }
  }

  Future<void> _showEditUserDialog(AppUser user) async {
    final rootContext = context;
    final nameController = TextEditingController(text: user.name ?? '');
    final emailController = TextEditingController(text: user.email);
    final passwordController = TextEditingController();
    UserRole selectedRole = user.role;
    String? selectedSupervisorId = user.supervisorId;
    String? selectedEncoderId = user.encoderId;
    SalesmanClassification selectedClassification = user.salesmanClassification;
    bool isActive = user.active;
    bool obscurePassword = true;
    String? currentProfilePic = user.profilePic;

    try {
      await showDialog<void>(
      context: rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          return AlertDialog(
            title: Text('Edit ${user.email}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  UserAvatar(
                    profilePicUrl: currentProfilePic,
                    displayName: (user.name?.trim().isNotEmpty ?? false)
                        ? user.name!.trim()
                        : user.email,
                    radius: 38,
                    showEditBadge: true,
                    onTap: () async {
                      final updatedUrl = await _pickCropAndUploadProfilePhoto(
                        user.copyWith(profilePic: currentProfilePic),
                      );
                      if (updatedUrl != null && dialogContext.mounted) {
                        setState(() => currentProfilePic = updatedUrl);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final updatedUrl =
                              await _pickCropAndUploadProfilePhoto(
                                user.copyWith(profilePic: currentProfilePic),
                              );
                          if (updatedUrl != null && dialogContext.mounted) {
                            setState(() => currentProfilePic = updatedUrl);
                          }
                        },
                        icon: const Icon(Icons.photo_camera_outlined, size: 16),
                        label: Text(
                          currentProfilePic?.isNotEmpty == true
                              ? 'Change Photo'
                              : 'Upload Photo',
                        ),
                      ),
                      if (currentProfilePic?.isNotEmpty == true)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                          onPressed: () async {
                            final removed = await _removeProfilePhoto(
                              user.copyWith(profilePic: currentProfilePic),
                            );
                            if (removed && dialogContext.mounted) {
                              setState(() => currentProfilePic = null);
                            }
                          },
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: const Text('Remove'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
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
                    items: [
                      UserRole.salesman,
                      UserRole.supervisor,
                      UserRole.encoder,
                      UserRole.manager,
                    ].map((role) {
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
                            selectedEncoderId = null;
                          }
                        });
                      }
                    },
                  ),
                  if (selectedRole == UserRole.salesman) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<SalesmanClassification>(
                      initialValue: selectedClassification,
                      decoration: const InputDecoration(
                        labelText: 'Salesman Classification',
                        isDense: true,
                      ),
                      items: SalesmanClassification.values.map((c) {
                        return DropdownMenuItem(
                          value: c,
                          child: Text(classificationLabel(c)),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => selectedClassification = value);
                        }
                      },
                    ),
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
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      initialValue: _encoders.any((e) => e.uid == selectedEncoderId)
                          ? selectedEncoderId
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Assigned Encoder (Optional)',
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None'),
                        ),
                        ..._encoders.map((encoder) {
                          return DropdownMenuItem<String?>(
                            value: encoder.uid,
                            child: Text(encoder.name ?? encoder.email),
                          );
                        }),
                      ],
                      onChanged: (value) {
                        setState(() => selectedEncoderId = value);
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
                        encoderId: selectedRole == UserRole.salesman
                            ? selectedEncoderId
                            : null,
                        salesmanClassification: selectedClassification,
                      );
                    });

                    if (!mounted) return;
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    await _loadUsers(silent: true);
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
    } finally {
      nameController.dispose();
      emailController.dispose();
      passwordController.dispose();
    }
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
                  await _loadUsers(silent: true);
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

  int _cardsPerRow(double maxWidth) {
    final isMobileLayout = maxWidth < 700;
    if (isMobileLayout) {
      return 1;
    }

    const minCardWidth = 300.0;
    final columns = ((maxWidth + 12) / (minCardWidth + 12)).floor();
    return columns.clamp(1, 4);
  }

  @override
  Widget build(BuildContext context) {
    final compactAppBarAction = MediaQuery.sizeOf(context).width < 620;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Users'),
        actions: [
          if (_selectedSupervisorFilterId != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: compactAppBarAction
                  ? IconButton(
                      tooltip: 'Remove Filter',
                      onPressed: () {
                        setState(() => _selectedSupervisorFilterId = null);
                      },
                      icon: const Icon(Icons.filter_alt_off),
                    )
                  : TextButton.icon(
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
      body: DeviceActivationBannerWrapper(
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final managersOnly = _allUsers
                    .where((u) => u.role == UserRole.manager)
                    .toList()
                  ..sort(_compareByEmailCode);
                final supervisorsOnly = _allUsers
                    .where((u) => u.role == UserRole.supervisor)
                    .toList()
                  ..sort(_compareByEmailCode);
                final encodersOnly = _allUsers
                    .where((u) => u.role == UserRole.encoder)
                    .toList()
                  ..sort(_compareByEmailCode);
                final salesmenOnly =
                    _allUsers.where((u) => u.role == UserRole.salesman).toList()
                      ..sort(_compareByEmailCode);

                final visibleSalesmen = _selectedSupervisorFilterId == null
                    ? salesmenOnly
                    : salesmenOnly
                          .where(
                            (u) => u.supervisorId == _selectedSupervisorFilterId,
                          )
                          .toList();
                final filterLabel = _activeFilterLabel();

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = _cardsPerRow(constraints.maxWidth);
                    const spacing = 12.0;
                    const horizontalPadding = 32.0;
                    final availableWidth =
                        constraints.maxWidth -
                        horizontalPadding -
                        ((columns - 1) * spacing);
                    final cardWidth = (availableWidth / columns)
                        .floorToDouble()
                        .clamp(0.0, constraints.maxWidth);

                    Widget buildSectionGrid(List<AppUser> users) {
                      if (users.isEmpty) return const SizedBox.shrink();
                      return Wrap(
                        spacing: spacing,
                        runSpacing: spacing,
                        children: users
                            .map(
                              (u) => SizedBox(
                                width: cardWidth,
                                child: _buildUserCard(u),
                              ),
                            )
                            .toList(),
                      );
                    }

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                      children: [
                        _buildSectionHeader('Managers'),
                        buildSectionGrid(managersOnly),
                        _buildSectionHeader('Supervisors'),
                        buildSectionGrid(supervisorsOnly),
                        _buildSectionHeader('Encoders'),
                        buildSectionGrid(encodersOnly),
                        if (encodersOnly.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'No encoders found.',
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                          ),
                        _buildSectionHeader(
                          _selectedSupervisorFilterId == null
                              ? 'Salesmen'
                              : 'Salesmen ($filterLabel)',
                        ),
                        if (_selectedSupervisorFilterId != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Filtered by supervisor: $filterLabel',
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                          ),
                        buildSectionGrid(visibleSalesmen),
                        if (visibleSalesmen.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _selectedSupervisorFilterId == null
                                  ? 'No salesmen found.'
                                  : 'No salesmen assigned to this supervisor.',
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
      ),
    );
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foregroundColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
