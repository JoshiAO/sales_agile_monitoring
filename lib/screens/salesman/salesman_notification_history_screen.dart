import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class SalesmanNotificationHistoryScreen extends StatefulWidget {
  const SalesmanNotificationHistoryScreen({super.key});

  @override
  State<SalesmanNotificationHistoryScreen> createState() =>
      _SalesmanNotificationHistoryScreenState();
}

class _SalesmanNotificationHistoryScreenState
    extends State<SalesmanNotificationHistoryScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  bool _isMarkingRead = false;

  String _formatDate(dynamic value) {
    if (value is Timestamp) {
      return DateFormat('MMM d, yyyy h:mm a').format(value.toDate().toLocal());
    }
    return 'Unknown time';
  }

  Future<void> _markAllAsRead(String uid) async {
    setState(() => _isMarkingRead = true);
    try {
      await _firestoreService.markAllSalesmanNotificationsRead(uid: uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notifications marked as read.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to mark as read: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isMarkingRead = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please sign in again.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          StreamBuilder<int>(
            stream: _firestoreService.watchUnreadSalesmanNotificationCount(
              uid: user.uid,
            ),
            initialData: 0,
            builder: (context, snapshot) {
              final unread = snapshot.data ?? 0;
              return TextButton.icon(
                onPressed: unread == 0 || _isMarkingRead
                    ? null
                    : () => _markAllAsRead(user.uid),
                icon: const Icon(Icons.mark_email_read_outlined),
                label: Text('Mark all ($unread)'),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _firestoreService.watchSalesmanNotifications(uid: user.uid),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Unable to load notifications: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final docs = snapshot.data?.docs ?? const [];
          if (docs.isEmpty) {
            return const Center(child: Text('No notifications yet.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemBuilder: (context, index) {
              final data = docs[index].data();
              final title = (data['title'] as String?) ?? 'Notification';
              final message = (data['message'] as String?) ?? '';
              final status = (data['status'] as String?) ?? 'info';
              final createdAt = data['createdAt'];
              final isUnread = data['readAt'] == null;

              final statusColor = switch (status) {
                'approved' => Colors.green,
                'rejected' => Colors.red,
                _ => Colors.blueGrey,
              };

              return ListTile(
                tileColor: isUnread ? Colors.yellow.shade50 : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                leading: CircleAvatar(
                  backgroundColor: statusColor.withValues(alpha: 0.12),
                  child: Icon(Icons.notifications, color: statusColor),
                ),
                title: Row(
                  children: [
                    Expanded(child: Text(title)),
                    if (isUnread)
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(message),
                    const SizedBox(height: 6),
                    Text(
                      _formatDate(createdAt),
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
            separatorBuilder: (separatorContext, separatorIndex) =>
                const SizedBox(height: 8),
            itemCount: docs.length,
          );
        },
      ),
    );
  }
}
