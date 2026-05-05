import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/storage_service.dart';

class AnnouncementPage extends StatefulWidget {
  final String title;

  const AnnouncementPage({super.key, this.title = 'Announcements'});

  @override
  State<AnnouncementPage> createState() => _AnnouncementPageState();
}

class _AnnouncementPageState extends State<AnnouncementPage> {
  final FirestoreService _firestoreService = FirestoreService();
  final StorageService _storageService = StorageService();
  final ImagePicker _imagePicker = ImagePicker();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();

  DateTime? _startAt;
  DateTime? _endAt;
  String _occurrence = 'Daily';
  Uint8List? _pickedImageBytes;
  String? _pickedImageName;
  bool _isSubmitting = false;

  static const List<String> _occurrences = [
    'Once',
    'Daily',
    'Weekly',
    'Monthly',
    'Yearly',
  ];

  @override
  void dispose() {
    _titleController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) return 'Select date and time';
    return DateFormat('MMM d, yyyy h:mm a').format(value);
  }

  DateTime? _dateTimeFromDynamic(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is Timestamp) return value.toDate();

    try {
      return (value as dynamic).toDate() as DateTime;
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> _pickDateTimeInContext(
    BuildContext pickerContext,
    DateTime? initialValue,
  ) async {
    final now = DateTime.now();
    final initial = initialValue ?? now;

    final pickedDate = await showDatePicker(
      context: pickerContext,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
      initialDate: initial,
    );
    if (pickedDate == null) return null;

    final pickedTime = await showTimePicker(
      context: pickerContext,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (pickedTime == null) return null;

    return DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
  }

  Future<DateTime?> _pickDateTime(DateTime? initialValue) async {
    return _pickDateTimeInContext(context, initialValue);
  }

  Future<void> _pickAnnouncementImage() async {
    final xfile = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 65,
      maxWidth: 2200,
      maxHeight: 2200,
    );
    if (xfile == null) return;

    final bytes = await xfile.readAsBytes();
    if (!mounted) return;
    setState(() {
      _pickedImageBytes = bytes;
      _pickedImageName = xfile.name;
    });
  }

  String _buildAnnouncementImageName(String userId, String originalName) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final dotIndex = originalName.lastIndexOf('.');
    final ext = dotIndex > -1
        ? originalName.substring(dotIndex + 1).toLowerCase()
        : 'jpg';
    return '${userId}_${timestamp}.$ext';
  }

  String _contentTypeFromFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    return 'application/octet-stream';
  }

  ({Uint8List bytes, String fileName, String contentType})
  _prepareAnnouncementImageUpload({
    required Uint8List sourceBytes,
    required String userId,
    required String originalName,
  }) {
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null) {
      // Keep original bytes and extension when format cannot be decoded.
      final fallbackName = _buildAnnouncementImageName(userId, originalName);
      return (
        bytes: sourceBytes,
        fileName: fallbackName,
        contentType: _contentTypeFromFileName(fallbackName),
      );
    }

    var output = decoded;
    const maxDimension = 1280;
    final longestSide = output.width > output.height ? output.width : output.height;
    if (longestSide > maxDimension) {
      final ratio = maxDimension / longestSide;
      final targetWidth = (output.width * ratio).round();
      final targetHeight = (output.height * ratio).round();
      output = img.copyResize(
        output,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.average,
      );
    }

    var quality = 35;
    var encoded = Uint8List.fromList(img.encodeJpg(output, quality: quality));

    const targetBytes = 220 * 1024;
    while (encoded.lengthInBytes > targetBytes && quality > 20) {
      quality -= 5;
      encoded = Uint8List.fromList(img.encodeJpg(output, quality: quality));
    }

    return (
      bytes: encoded,
      fileName: _buildAnnouncementImageName(userId, 'announcement.jpg'),
      contentType: 'image/jpeg',
    );
  }

  Future<void> _showEditAnnouncementDialog(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    final titleController = TextEditingController(
      text: (data['title'] as String?) ?? '',
    );
    final messageController = TextEditingController(
      text: (data['message'] as String?) ?? '',
    );
    var startAt = _dateTimeFromDynamic(data['startAt']);
    var endAt = _dateTimeFromDynamic(data['endAt']);
    var occurrence = (data['occurrence'] as String?) ?? 'Daily';
    var imageUrl = (data['imageUrl'] as String?) ?? '';
    var isSaving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Announcement'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: messageController,
                      minLines: 3,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Text',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: occurrence,
                      decoration: const InputDecoration(
                        labelText: 'Occurrence',
                        border: OutlineInputBorder(),
                      ),
                      items: _occurrences
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => occurrence = value);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _pickDateTimeInContext(
                              dialogContext,
                              startAt,
                            );
                            if (picked != null) {
                              setDialogState(() => startAt = picked);
                            }
                          },
                          icon: const Icon(Icons.schedule),
                          label: Text('Start: ${_formatDateTime(startAt)}'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _pickDateTimeInContext(
                              dialogContext,
                              endAt,
                            );
                            if (picked != null) {
                              setDialogState(() => endAt = picked);
                            }
                          },
                          icon: const Icon(Icons.event),
                          label: Text('End: ${_formatDateTime(endAt)}'),
                        ),
                      ],
                    ),
                    if (imageUrl.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Current Attachment',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(
                          minHeight: 120,
                          maxHeight: 260,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                          color: Colors.grey.shade50,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.network(
                          imageUrl,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Container(
                            alignment: Alignment.center,
                            color: Colors.grey.shade200,
                            child: const Text('Unable to load image'),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          final title = titleController.text.trim();
                          final message = messageController.text.trim();
                          if (title.isEmpty || message.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Title and text are required.'),
                              ),
                            );
                            return;
                          }
                          if (startAt == null || endAt == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Start and end time are required.'),
                              ),
                            );
                            return;
                          }
                          if (!endAt!.isAfter(startAt!)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'End time must be after start time.',
                                ),
                              ),
                            );
                            return;
                          }

                          setDialogState(() => isSaving = true);
                          try {
                            final editingUser =
                                context.read<AuthProvider>().currentUser;
                            if (editingUser == null) {
                              throw Exception('Please sign in again.');
                            }

                            await _firestoreService.updateAnnouncement(
                              announcementId: doc.id,
                              title: title,
                              message: message,
                              startAt: startAt!,
                              endAt: endAt!,
                              occurrence: occurrence,
                              imageUrl: imageUrl,
                            );
                            if (!mounted || !dialogContext.mounted) return;
                            Navigator.pop(dialogContext);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Announcement updated.'),
                              ),
                            );
                          } catch (error) {
                            if (!mounted) return;
                            setDialogState(() => isSaving = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Failed to update: $error'),
                              ),
                            );
                          }
                        },
                  child: isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    titleController.dispose();
    messageController.dispose();
  }

  Future<void> _showDeleteAnnouncementDialog(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final title = (doc.data()['title'] as String?) ?? 'this announcement';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Announcement'),
        content: Text('Delete "$title"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      await _firestoreService.deleteAnnouncement(announcementId: doc.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Announcement deleted.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $error')),
      );
    }
  }

  Future<void> _submitAnnouncement() async {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in again.')),
      );
      return;
    }

    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) return;

    if (_startAt == null || _endAt == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select start and end time.')),
      );
      return;
    }

    if (!_endAt!.isAfter(_startAt!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be after start time.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      String imageUrl = '';
      if (_pickedImageBytes != null) {
        final prepared = _prepareAnnouncementImageUpload(
          sourceBytes: _pickedImageBytes!,
          userId: user.uid,
          originalName: _pickedImageName ?? 'announcement.jpg',
        );
        imageUrl = await _storageService.uploadImageBytes(
          bytes: prepared.bytes,
          folder: 'announcement_images',
          filename: prepared.fileName,
          contentType: prepared.contentType,
        );
      }

      await _firestoreService.createAnnouncement(
        createdBy: user.uid,
        creatorRole: user.role,
        title: _titleController.text,
        message: _messageController.text,
        startAt: _startAt!,
        endAt: _endAt!,
        occurrence: _occurrence,
        imageUrl: imageUrl,
      );

      _titleController.clear();
      _messageController.clear();
      setState(() {
        _startAt = null;
        _endAt = null;
        _occurrence = 'Daily';
        _pickedImageBytes = null;
        _pickedImageName = null;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Announcement published.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to publish: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = context.watch<AuthProvider>().currentUser;

    if (currentUser == null) {
      return const Scaffold(body: Center(child: Text('Please sign in again.')));
    }

    final audienceText = currentUser.role == UserRole.superuser
        ? 'Visible to all salesmen and supervisors.'
        : 'Visible to salesmen under your supervision only.';

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;

          final formCard = Card(
            margin: EdgeInsets.zero,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create Announcement',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      audienceText,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _titleController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if ((value ?? '').trim().isEmpty) {
                          return 'Title is required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _messageController,
                      minLines: 3,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Text',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if ((value ?? '').trim().isEmpty) {
                          return 'Text is required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _occurrence,
                      decoration: const InputDecoration(
                        labelText: 'Occurrence',
                        border: OutlineInputBorder(),
                      ),
                      items: _occurrences
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _occurrence = value);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _pickDateTime(_startAt);
                            if (picked != null && mounted) {
                              setState(() => _startAt = picked);
                            }
                          },
                          icon: const Icon(Icons.schedule),
                          label: Text('Start: ${_formatDateTime(_startAt)}'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _pickDateTime(_endAt);
                            if (picked != null && mounted) {
                              setState(() => _endAt = picked);
                            }
                          },
                          icon: const Icon(Icons.event),
                          label: Text('End: ${_formatDateTime(_endAt)}'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _isSubmitting ? null : _pickAnnouncementImage,
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('Attach Image'),
                        ),
                        if (_pickedImageBytes != null)
                          OutlinedButton.icon(
                            onPressed: _isSubmitting
                                ? null
                                : () {
                                    setState(() {
                                      _pickedImageBytes = null;
                                      _pickedImageName = null;
                                    });
                                  },
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove Image'),
                          ),
                      ],
                    ),
                    if (_pickedImageBytes != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          _pickedImageBytes!,
                          fit: BoxFit.contain,
                          height: 240,
                          width: double.infinity,
                          errorBuilder: (_, __, ___) => Container(
                            height: 120,
                            color: Colors.grey.shade200,
                            alignment: Alignment.center,
                            child: const Text('Unable to preview image'),
                          ),
                        ),
                      ),
                      if ((_pickedImageName ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _pickedImageName!,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isSubmitting ? null : _submitAnnouncement,
                        icon: _isSubmitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.campaign_outlined),
                        label: const Text('Publish Announcement'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

          final listCard = Card(
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: Text(
                    'Published Announcements',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _firestoreService.watchAnnouncementsByCreator(
                      creatorId: currentUser.uid,
                    ),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'Unable to load announcements: ${snapshot.error}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }

                      final docs = snapshot.data?.docs ?? const [];
                      if (docs.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('No announcements yet.'),
                          ),
                        );
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final doc = docs[index];
                          final data = doc.data();
                          final title = (data['title'] as String?) ?? 'Announcement';
                          final message = (data['message'] as String?) ?? '';
                            final imageUrl = (data['imageUrl'] as String?) ?? '';
                          final occurrence =
                              (data['occurrence'] as String?) ?? 'Daily';
                          final startAt = _dateTimeFromDynamic(data['startAt']);
                          final endAt = _dateTimeFromDynamic(data['endAt']);

                          return ListTile(
                            tileColor: Colors.grey.shade50,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                            title: Text(title),
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Announcement actions',
                              onSelected: (value) {
                                if (value == 'edit') {
                                  _showEditAnnouncementDialog(doc);
                                } else if (value == 'delete') {
                                  _showDeleteAnnouncementDialog(doc);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem<String>(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                                PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text(message),
                                if (imageUrl.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      imageUrl,
                                      fit: BoxFit.contain,
                                      height: 140,
                                      width: double.infinity,
                                      errorBuilder: (_, __, ___) => Container(
                                        height: 80,
                                        color: Colors.grey.shade200,
                                        alignment: Alignment.center,
                                        child: const Text('Unable to load image'),
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Text(
                                  'Occurrence: $occurrence',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'Start: ${_formatDateTime(startAt)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                Text(
                                  'End: ${_formatDateTime(endAt)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ],
                            ),
                            isThreeLine: true,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );

          if (wide) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 4, child: formCard),
                  const SizedBox(width: 12),
                  Expanded(flex: 6, child: listCard),
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              children: [
                formCard,
                const SizedBox(height: 12),
                Expanded(child: listCard),
              ],
            ),
          );
        },
      ),
    );
  }
}
