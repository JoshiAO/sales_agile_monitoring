import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class FeedsPage extends StatelessWidget {
  const FeedsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _FeedsView(user: user);
  }
}

class _FeedsView extends StatefulWidget {
  final AppUser user;
  const _FeedsView({required this.user});

  @override
  State<_FeedsView> createState() => _FeedsViewState();
}

class _FeedsViewState extends State<_FeedsView> {
  final FirestoreService _firestoreService = FirestoreService();

  Future<void> _showFocusedAnnouncementCard({
    required String announcementId,
    required Map<String, dynamic> data,
    required bool allowUnlike,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (dialogContext) {
        return SafeArea(
          child: LayoutBuilder(
            builder: (context, viewport) {
              final availableWidth =
                  (viewport.maxWidth - 32).clamp(280.0, viewport.maxWidth);
              final minDialogWidth = availableWidth < 578 ? availableWidth : 578.0;
              final maxDialogWidth = availableWidth < 853 ? availableWidth : 853.0;

              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: minDialogWidth,
                      maxWidth: maxDialogWidth,
                      maxHeight: viewport.maxHeight - 24,
                    ),
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 10, right: 10),
                          child: SingleChildScrollView(
                            child: _AnnouncementFeedCard(
                              announcementId: announcementId,
                              data: data,
                              currentUserId: widget.user.uid,
                              enableFocusMode: false,
                              isFocusView: true,
                              allowUnlike: allowUnlike,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Material(
                            color: Colors.white,
                            elevation: 2,
                            shape: const CircleBorder(),
                            child: IconButton(
                              tooltip: 'Close',
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(dialogContext).pop(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filterAnnouncements(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final user = widget.user;
    final now = DateTime.now();

    final filtered = docs.where((doc) {
      final data = doc.data();
      final endAt = (data['endAt'] as Timestamp?)?.toDate();
      if (endAt == null || endAt.isBefore(now)) return false;

      final audience = data['audience'] as String? ?? 'all_staff';
      final supervisorId = data['supervisorId'] as String?;

      if (user.role == UserRole.superuser) {
        return true;
      } else if (user.role == UserRole.supervisor) {
        if (audience == 'all_staff') return true;
        if (data['createdBy'] == user.uid) return true;
        return false;
      } else {
        // salesman
        if (audience == 'all_staff') return true;
        if (audience == 'supervisor_team' &&
            supervisorId != null &&
            supervisorId == user.supervisorId) {
          return true;
        }
        return false;
      }
    }).toList();

    filtered.sort((a, b) {
      final aTs = a.data()['createdAt'];
      final bTs = b.data()['createdAt'];
      if (aTs == null && bTs == null) return 0;
      if (aTs == null) return 1;
      if (bTs == null) return -1;
      final aDate = (aTs as Timestamp).toDate();
      final bDate = (bTs as Timestamp).toDate();
      return bDate.compareTo(aDate);
    });

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feeds'),
        centerTitle: false,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _firestoreService.watchActiveAnnouncements(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final docs = snapshot.data?.docs ?? [];
          final announcements = _filterAnnouncements(docs);

          if (announcements.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.feed_outlined,
                    size: 64,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No active announcements',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Announcements will appear here when published.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final isCenteredWeb = kIsWeb && constraints.maxWidth >= 900;
              final centeredWidth = (constraints.maxWidth * 0.32)
                  .clamp(420.0, 620.0)
                  .toDouble();

              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                itemCount: announcements.length,
                separatorBuilder: (_, _) => const SizedBox(height: 16),
                itemBuilder: (context, index) {
                  final doc = announcements[index];
                  final enableFocusMode = true;
                  final allowUnlike = widget.user.role != UserRole.salesman;
                  final card = _AnnouncementFeedCard(
                    announcementId: doc.id,
                    data: doc.data(),
                    currentUserId: widget.user.uid,
                    enableFocusMode: enableFocusMode,
                    allowUnlike: allowUnlike,
                    onOpenFocus: () => _showFocusedAnnouncementCard(
                          announcementId: doc.id,
                          data: doc.data(),
                          allowUnlike: allowUnlike,
                        ),
                  );
                  if (!isCenteredWeb) {
                    return card;
                  }

                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: centeredWidth),
                      child: card,
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _AnnouncementFeedCard extends StatelessWidget {
  final String announcementId;
  final Map<String, dynamic> data;
  final String currentUserId;
  final bool enableFocusMode;
  final bool isFocusView;
  final bool allowUnlike;
  final VoidCallback? onOpenFocus;
  const _AnnouncementFeedCard({
    required this.announcementId,
    required this.data,
    required this.currentUserId,
    this.enableFocusMode = false,
    this.isFocusView = false,
    this.allowUnlike = true,
    this.onOpenFocus,
  });

  static final _dtFmt = DateFormat('MMM d, yyyy h:mm a');

  Color _occurrenceColor(String occurrence) {
    switch (occurrence) {
      case 'Once':
        return Colors.purple;
      case 'Daily':
        return Colors.blue;
      case 'Weekly':
        return Colors.teal;
      case 'Monthly':
        return Colors.orange;
      case 'Yearly':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  Color _creatorColor(String role) {
    return role == 'superuser' ? Colors.indigo : Colors.green.shade700;
  }

  String _creatorLabel(String role) {
    return role == 'superuser' ? 'Superuser' : 'Supervisor';
  }

  String _timeRemaining(DateTime endAt) {
    final now = DateTime.now();
    final diff = endAt.difference(now);
    if (diff.inDays >= 1) {
      return '${diff.inDays}d remaining';
    } else if (diff.inHours >= 1) {
      return '${diff.inHours}h remaining';
    } else if (diff.inMinutes >= 1) {
      return '${diff.inMinutes}m remaining';
    } else {
      return 'Expiring soon';
    }
  }

  @override
  Widget build(BuildContext context) {
    final firestoreService = FirestoreService();
    final title = data['title'] as String? ?? '';
    final message = data['message'] as String? ?? '';
    final imageUrl = data['imageUrl'] as String? ?? '';
    final occurrence = data['occurrence'] as String? ?? 'Once';
    final creatorRole = data['creatorRole'] as String? ?? 'supervisor';
    final startAt = (data['startAt'] as Timestamp?)?.toDate();
    final endAt = (data['endAt'] as Timestamp?)?.toDate();
    final createdAt = (data['createdAt'] as Timestamp?)?.toDate();

    final occColor = _occurrenceColor(occurrence);
    final creatorColor = _creatorColor(creatorRole);

    Widget buildEngagementSection() {
      return StreamBuilder<bool>(
        stream: firestoreService.watchIsAnnouncementLiked(
          announcementId: announcementId,
          uid: currentUserId,
        ),
        initialData: false,
        builder: (context, likedSnapshot) {
          final isLiked = likedSnapshot.data ?? false;
          return StreamBuilder<int>(
            stream: firestoreService.watchAnnouncementLikeCount(
              announcementId: announcementId,
            ),
            initialData: 0,
            builder: (context, countSnapshot) {
              final likeCount = countSnapshot.data ?? 0;
              return Row(
                children: [
                  IconButton(
                    tooltip: isLiked ? (allowUnlike ? 'Unlike' : 'Liked') : 'Like',
                    visualDensity: VisualDensity.compact,
                    onPressed: isLiked && !allowUnlike
                        ? null
                        : () async {
                            if (isLiked) {
                              await firestoreService.unlikeAnnouncement(
                                announcementId: announcementId,
                                uid: currentUserId,
                              );
                            } else {
                              await firestoreService.likeAnnouncement(
                                announcementId: announcementId,
                                uid: currentUserId,
                              );
                            }
                          },
                    icon: Icon(
                      isLiked ? Icons.favorite : Icons.favorite_border,
                      color: isLiked ? Colors.red : Colors.grey.shade700,
                    ),
                  ),
                  Text(
                    likeCount == 1 ? '1 heart' : '$likeCount hearts',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    }

    final showWebFocusSplit = isFocusView && kIsWeb && imageUrl.isNotEmpty;

    final card = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: showWebFocusSplit
            ? SizedBox(
                height: 560,
                child: Row(
                  children: [
                    Expanded(
                      flex: 13,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.03),
                          alignment: Alignment.center,
                          child: Image.network(
                            imageUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => Container(
                              alignment: Alignment.center,
                              color: Colors.grey.shade200,
                              child: const Text('Unable to load image'),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 7,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _Chip(label: occurrence, color: occColor),
                              _Chip(
                                label: _creatorLabel(creatorRole),
                                color: creatorColor,
                              ),
                              if (endAt != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade50,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: Colors.green.shade300),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.access_time,
                                        size: 12,
                                        color: Colors.green.shade700,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _timeRemaining(endAt),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.green.shade700,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Text(
                                message,
                                style: const TextStyle(fontSize: 14, height: 1.5),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                          buildEngagementSection(),
                          const SizedBox(height: 6),
                          if (startAt != null && endAt != null)
                            Row(
                              children: [
                                Icon(
                                  Icons.date_range,
                                  size: 14,
                                  color: Colors.grey.shade600,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '${_dtFmt.format(startAt)}  →  ${_dtFmt.format(endAt)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          if (createdAt != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.publish_outlined,
                                  size: 14,
                                  color: Colors.grey.shade500,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Published ${_dtFmt.format(createdAt)}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _Chip(
                        label: occurrence,
                        color: occColor,
                      ),
                      _Chip(
                        label: _creatorLabel(creatorRole),
                        color: creatorColor,
                      ),
                      if (endAt != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.green.shade300),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.access_time,
                                size: 12,
                                color: Colors.green.shade700,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _timeRemaining(endAt),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.green.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                  if (imageUrl.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 620),
                        color: Colors.black.withValues(alpha: 0.03),
                        child: Image.network(
                          imageUrl,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => Container(
                            height: 120,
                            alignment: Alignment.center,
                            color: Colors.grey.shade200,
                            child: const Text('Unable to load image'),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  buildEngagementSection(),
                  const SizedBox(height: 6),
                  if (startAt != null && endAt != null)
                    Row(
                      children: [
                        Icon(Icons.date_range, size: 14, color: Colors.grey.shade600),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${_dtFmt.format(startAt)}  →  ${_dtFmt.format(endAt)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (createdAt != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.publish_outlined,
                          size: 14,
                          color: Colors.grey.shade500,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Published ${_dtFmt.format(createdAt)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );

    if (!enableFocusMode || onOpenFocus == null) {
      return card;
    }

    return InkWell(
      onTap: onOpenFocus,
      borderRadius: BorderRadius.circular(14),
      child: card,
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
