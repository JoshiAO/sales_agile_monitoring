import 'package:flutter/foundation.dart';
import 'package:compact_sales_monitoring/widgets/device_activation_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/archive_service.dart';

class DatabaseManagementScreen extends StatefulWidget {
  const DatabaseManagementScreen({super.key});

  @override
  State<DatabaseManagementScreen> createState() =>
      _DatabaseManagementScreenState();
}

class _DatabaseManagementScreenState extends State<DatabaseManagementScreen> {
  static final DateFormat _displayDateFormat = DateFormat('MMM d, yyyy');

  final ArchiveService _archiveService = ArchiveService();

  DateTime _startDate = _normalizeDate(DateTime.now());
  DateTime _endDate = _normalizeDate(DateTime.now());
  bool _isSingleDate = true;

  ImageRangePreview? _preview;
  bool _isLoadingPreview = false;
  bool _isArchiving = false;
  bool _isDeleting = false;
  String? _previewError;

  static DateTime _normalizeDate(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  String _rangeLabel() {
    if (_startDate == _endDate) {
      return _displayDateFormat.format(_startDate);
    }
    return '${_displayDateFormat.format(_startDate)} – ${_displayDateFormat.format(_endDate)}';
  }

  Future<void> _loadPreview() async {
    setState(() {
      _isLoadingPreview = true;
      _previewError = null;
    });

    try {
      final companyId = context.read<AuthProvider>().currentUser?.companyId;
      final preview = await _archiveService.previewSavedImages(
        startDate: _startDate,
        endDate: _endDate,
        companyId: companyId,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _isLoadingPreview = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewError = 'Failed to scan saved images: $e';
        _isLoadingPreview = false;
      });
    }
  }

  Future<void> _pickSingleDate() async {
    final today = _normalizeDate(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate.isAfter(today) ? today : _startDate,
      firstDate: DateTime(2024),
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startDate = _normalizeDate(picked);
      _endDate = _startDate;
    });
    await _loadPreview();
  }

  Future<void> _pickDateRange() async {
    final today = _normalizeDate(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: today,
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      helpText: 'Select date range for database management',
      saveText: 'Apply',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startDate = _normalizeDate(picked.start);
      _endDate = _normalizeDate(picked.end);
    });
    await _loadPreview();
  }

  Future<void> _handleArchive() async {
    if (_isArchiving || _isDeleting) return;
    setState(() => _isArchiving = true);
    try {
      final companyId = context.read<AuthProvider>().currentUser?.companyId;
      final result = await _archiveService.archiveRoutes(
        startDate: _startDate,
        endDate: _endDate,
        deleteAfterArchive: false,
        companyId: companyId,
      );
      if (!mounted) return;
      await _showArchiveCompleteDialog(result);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Archive failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isArchiving = false);
      }
    }
  }

  Future<void> _handleDeleteSavedImages() async {
    if (_isArchiving || _isDeleting) return;
    final imageCount = _preview?.imageCount ?? 0;
    final routeCount = _preview?.routeCount ?? 0;

    if (imageCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved images found for the selected date/range.'),
        ),
      );
      return;
    }

    final confirmController = TextEditingController();
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final matchesDelete =
                confirmController.text.trim().toUpperCase() == 'DELETE';
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.red),
                  SizedBox(width: 8),
                  Expanded(child: Text('Delete Saved Images?')),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Date Range: ${_rangeLabel()}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This will permanently delete $imageCount saved call image(s) across $routeCount route(s) from Firebase Storage.',
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: const Text(
                        'Route GPS checkpoints, call timestamps, and captured sales transactions in Firestore will be preserved.',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Tip: Run "Archive Saved Images" first if you need an offline backup.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirmController,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Type DELETE to confirm',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                  ),
                  onPressed: matchesDelete
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                  child: const Text('Delete Saved Images'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      confirmController.dispose();
    }

    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);
    try {
      final companyId = context.read<AuthProvider>().currentUser?.companyId;
      final result = await _archiveService.deleteSavedImages(
        startDate: _startDate,
        endDate: _endDate,
        companyId: companyId,
      );
      if (!mounted) return;
      await _loadPreview();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted ${result.deletedImageCount} image(s) across ${result.affectedRouteCount} route(s).'
            '${result.failedImageCount > 0 ? ' (${result.failedImageCount} already missing or skipped)' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  Future<void> _showArchiveCompleteDialog(ArchiveResult result) async {
    final dateFolderLabel = result.dateFolders.length <= 3
        ? result.dateFolders.join(', ')
        : '${result.dateFolders.first}, ${result.dateFolders[1]}, +${result.dateFolders.length - 2} more';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive Complete'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Date range: ${result.startDate} to ${result.endDate}'),
              const SizedBox(height: 8),
              Text('Routes included: ${result.routeCount}'),
              Text('Images exported: ${result.imageCount}'),
              const SizedBox(height: 8),
              const Text(
                'No images or route records were deleted. Use "Delete Saved Images" separately when you are ready to free storage.',
                style: TextStyle(fontSize: 12.5, color: Colors.black87),
              ),
              const SizedBox(height: 12),
              const Text(
                'Saved ZIP',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              SelectableText('${result.zipFileName} (${result.zipPath})'),
              const SizedBox(height: 12),
              const Text(
                'ZIP structure',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text('- ${result.workbookFileName}'),
              Text('- Date folders: $dateFolderLabel'),
              const Text(
                '- Inside each date: salesman folders with first/last call images',
              ),
            ],
          ),
        ),
        actions: [
          if (!kIsWeb)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.zipPath));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Archive path copied')),
                );
              },
              child: const Text('Copy Path'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isArchiving || _isDeleting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Database Management'),
        actions: [
          IconButton(
            tooltip: 'Refresh Storage Scan',
            onPressed: (_isLoadingPreview || busy) ? null : _loadPreview,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DeviceActivationBannerWrapper(
        child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Date Selection & Preview Card
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Select Target Date or Date Range',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Choose a single day or range to archive or clean up saved call images in Firebase Storage.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(
                                value: true,
                                label: Text('Single Date'),
                                icon: Icon(Icons.today, size: 16),
                              ),
                              ButtonSegment(
                                value: false,
                                label: Text('Date Range'),
                                icon: Icon(Icons.date_range, size: 16),
                              ),
                            ],
                            selected: {_isSingleDate},
                            onSelectionChanged: busy
                                ? null
                                : (sel) {
                                    setState(() {
                                      _isSingleDate = sel.first;
                                      if (_isSingleDate) {
                                        _endDate = _startDate;
                                      }
                                    });
                                    _loadPreview();
                                  },
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : (_isSingleDate
                                    ? _pickSingleDate
                                    : _pickDateRange),
                            icon: const Icon(Icons.calendar_month, size: 18),
                            label: Text(_rangeLabel()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 14),
                      if (_isLoadingPreview)
                        const Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text('Scanning routes and saved images...'),
                          ],
                        )
                      else if (_previewError != null)
                        Text(
                          _previewError!,
                          style: const TextStyle(color: Colors.red),
                        )
                      else
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            _StatChip(
                              icon: Icons.route_outlined,
                              label: 'Matching Routes',
                              value: '${_preview?.routeCount ?? 0}',
                              color: Colors.indigo,
                            ),
                            _StatChip(
                              icon: Icons.photo_library_outlined,
                              label: 'Saved Call Images',
                              value: '${_preview?.imageCount ?? 0}',
                              color: Colors.teal.shade700,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Card 1: Archive Saved Images (Download Only)
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.teal.shade200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.teal.shade50,
                            child: Icon(
                              Icons.archive_outlined,
                              color: Colors.teal.shade800,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '1. Archive Saved Images (Download ZIP)',
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Downloads a ZIP organized by Date / Salesman with all saved First & Last Call images plus the Routes Excel workbook. Does not delete anything.',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: (busy ||
                                  _isLoadingPreview ||
                                  (_preview?.routeCount ?? 0) == 0)
                              ? null
                              : _handleArchive,
                          icon: _isArchiving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          label: Text(
                            _isArchiving
                                ? 'Building Archive...'
                                : 'Archive Saved Images',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Card 2: Delete Saved Images (Separate Process, Images Only)
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.red.shade200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.red.shade50,
                            child: Icon(
                              Icons.delete_sweep_outlined,
                              color: Colors.red.shade700,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '2. Delete Saved Images (Free Storage Space)',
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Permanently removes saved call photos from Firebase Storage for the selected date/range while preserving all route GPS checkpoints, call timestamps, and sales transactions.',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                          ),
                          onPressed: (busy ||
                                  _isLoadingPreview ||
                                  (_preview?.imageCount ?? 0) == 0)
                              ? null
                              : _handleDeleteSavedImages,
                          icon: _isDeleting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.delete_forever_outlined),
                          label: Text(
                            _isDeleting
                                ? 'Deleting Images...'
                                : 'Delete Saved Images',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

