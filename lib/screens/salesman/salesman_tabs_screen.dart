import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/screens/salesman/salesman_home_screen.dart';
import 'package:compact_sales_monitoring/screens/salesman/salesman_transactions_screen.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/transaction_storage_service.dart';
import 'package:compact_sales_monitoring/widgets/agile_call_form_card.dart';
import 'package:compact_sales_monitoring/services/telemetry_service.dart';

class SalesmanTabsScreen extends StatefulWidget {
  const SalesmanTabsScreen({super.key});

  @override
  State<SalesmanTabsScreen> createState() => _SalesmanTabsScreenState();
}

class _SalesmanTabsScreenState extends State<SalesmanTabsScreen> {
  int _currentIndex = 0;
  int _agileRefreshTrigger = 0;
  int _transactionsRefreshTrigger = 0;
  int _pendingTransactionsCount = 0;
  final FirestoreService _firestoreService = FirestoreService();
  final TransactionStorageService _transactionStorage =
      TransactionStorageService();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _logoutRequestSubscription;
  String? _lastLogoutRequestStatus;
  String? _currentLogoutRequestStatus;
  bool _hasLoadedInitialLogoutStatus = false;

  bool _isBookingUser(AppUser? user) => user?.isBooking ?? false;

  void _onTabSelected(int index, {required bool isBooking}) {
    setState(() {
      _currentIndex = index;
      if (index == 1) {
        if (isBooking) {
          _agileRefreshTrigger++;
        } else {
          _transactionsRefreshTrigger++;
        }
      }
    });
    if (!isBooking) {
      _refreshPendingTransactionsCount();
    }
  }

  List<Widget> _buildPages({required bool isBooking}) => [
    SalesmanHomeScreen(logoutStatusPill: _buildLogoutStatusPill()),
    if (isBooking)
      _AgileTab(refreshTrigger: _agileRefreshTrigger)
    else
      SalesmanTransactionsScreen(
        refreshTrigger: _transactionsRefreshTrigger,
        onPendingCountChanged: _refreshPendingTransactionsCount,
      ),
  ];

  Future<void> _refreshPendingTransactionsCount() async {
    final count = await _transactionStorage.getCachedPendingCount();
    if (mounted && count != _pendingTransactionsCount) {
      setState(() => _pendingTransactionsCount = count);
    }
  }

  Widget _badgeIcon(IconData icon, int count) {
    if (count <= 0) {
      return Icon(icon);
    }

    final text = count > 99 ? '99+' : '$count';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        Positioned(
          right: -10,
          top: -8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(999),
            ),
            constraints: const BoxConstraints(minWidth: 18),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindLogoutRequestListener();
      TelemetryService.requestUsagePermission();
      _refreshPendingTransactionsCount();
    });
  }

  void _bindLogoutRequestListener() {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) {
      return;
    }

    _logoutRequestSubscription?.cancel();
    _logoutRequestSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snapshot) {
          final data = snapshot.data();
          final nextStatus = data?['logoutRequestStatus'] as String?;

          if (mounted) {
            setState(() {
              _currentLogoutRequestStatus = nextStatus;
            });
          }

          if (!_hasLoadedInitialLogoutStatus) {
            _hasLoadedInitialLogoutStatus = true;
            _lastLogoutRequestStatus = nextStatus;
            return;
          }

          if (nextStatus == _lastLogoutRequestStatus || !mounted) {
            return;
          }

          if (nextStatus == 'approved') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Logout request approved. You may now log out directly.',
                ),
              ),
            );
          } else if (nextStatus == 'rejected') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Logout request rejected by superuser.'),
                action: SnackBarAction(
                  label: 'Dismiss',
                  onPressed: () {
                    _firestoreService
                        .clearLogoutApproval(uid: user.uid)
                        .catchError((_) {});
                  },
                ),
                duration: const Duration(seconds: 6),
              ),
            );
          }

          _lastLogoutRequestStatus = nextStatus;
        });

    _currentLogoutRequestStatus = user.logoutRequestStatus;
  }

  Widget _buildLogoutStatusPill() {
    final status = _currentLogoutRequestStatus;
    if (status == null) {
      return const SizedBox.shrink();
    }

    late final String label;
    late final Color bg;
    late final Color fg;
    bool isDismissible = false;

    switch (status) {
      case 'approved':
        label = 'Logout: Approved (Tap to Logout)';
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        break;
      case 'rejected':
        label = 'Logout: Rejected (Tap to Dismiss)';
        bg = Colors.red.shade50;
        fg = Colors.red.shade800;
        isDismissible = true;
        break;
      default:
        label = 'Logout: Pending';
        bg = Colors.orange.shade50;
        fg = Colors.orange.shade800;
    }

    final user = context.read<AuthProvider>().currentUser;

    return GestureDetector(
      onTap: () async {
        if (status == 'approved') {
          await _handleLogoutTapped();
        } else if (status == 'rejected' && user != null) {
          await _firestoreService.clearLogoutApproval(uid: user.uid);
          if (mounted) {
            setState(() {
              _currentLogoutRequestStatus = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Logout rejection message cleared.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: fg.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (isDismissible) ...[
              const SizedBox(width: 4),
              Icon(Icons.close, size: 14, color: fg),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _handleLogoutTapped() async {
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.currentUser;
    if (user == null) {
      return;
    }

    final latestUser = await _firestoreService.getUser(user.uid);
    if (!mounted) return;

    if (latestUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to validate logout access.')),
      );
      return;
    }

    if (latestUser.logoutRequestApproved) {
      await _firestoreService.clearLogoutApproval(uid: latestUser.uid);
      if (!mounted) return;
      await authProvider.logout();
      return;
    }

    if (latestUser.logoutRequestPending) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Logout Request Pending'),
          content: const Text(
            'Your logout request is still pending. Please wait for superuser approval.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Request Logout Approval'),
        content: const Text(
          'Do you want to send a logout request to superuser?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await _firestoreService.requestLogoutApproval(uid: user.uid);
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Logout request sent. Wait for superuser response.',
                    ),
                  ),
                );
              } catch (error) {
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to send request: $error')),
                );
              }
            },
            child: const Text('Send Request'),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuHeader(bool isExpandedRail) {
    if (!isExpandedRail) {
      return const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 16),
        child: Tooltip(
          message: 'Sales Agile Monitoring\nCreated by: Joshua A. Ocampo',
          child: Icon(Icons.dashboard_customize_outlined),
        ),
      );
    }

    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 16, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sales Agile Monitoring',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 4),
          Text(
            'Created by: Joshua A. Ocampo',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutButton(bool isExpandedRail) {
    return Builder(
      builder: (context) {
        if (!isExpandedRail) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: IconButton(
              tooltip: 'Logout',
              icon: const Icon(Icons.logout),
              onPressed: _handleLogoutTapped,
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: SizedBox(
            width: 172,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(172, 40),
                  maximumSize: const Size(172, 40),
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.logout),
                label: const Text('Logout'),
                onPressed: _handleLogoutTapped,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAlertsButton(bool isExpandedRail, int unreadCount) {
    return Builder(
      builder: (context) {
        if (!isExpandedRail) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  tooltip: 'Notifications',
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: () => _showAlertsModal(context),
                ),
                if (unreadCount > 0)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      constraints: const BoxConstraints(minWidth: 16),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: SizedBox(
            width: 172,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(172, 40),
                  maximumSize: const Size(172, 40),
                  alignment: Alignment.centerLeft,
                ),
                icon: _badgeIcon(Icons.notifications_outlined, unreadCount),
                label: const Text('Notifications'),
                onPressed: () => _showAlertsModal(context),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showAlertsModal(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (modalContext) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) =>
            SalesmanAlertsModalContent(scrollController: scrollController),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = context.watch<AuthProvider>().currentUser;
    final uid = currentUser?.uid;
    final isBooking = _isBookingUser(currentUser);
    final pages = _buildPages(isBooking: isBooking);
    final safeIndex = _currentIndex.clamp(0, pages.length - 1);
    final unreadStream = uid == null
        ? const Stream<int>.empty()
        : _firestoreService.watchUnreadSalesmanNotificationCount(uid: uid);

    if (kIsWeb) {
      return StreamBuilder<int>(
        stream: unreadStream,
        initialData: 0,
        builder: (context, snapshot) {
          final unread = snapshot.data ?? 0;
          return LayoutBuilder(
            builder: (context, constraints) {
              final isExpandedRail = constraints.maxWidth >= 1180;
              return Scaffold(
                body: SafeArea(
                  child: Row(
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          Expanded(
                            child: NavigationRail(
                              selectedIndex: safeIndex,
                              onDestinationSelected: (idx) =>
                                  _onTabSelected(idx, isBooking: isBooking),
                              leading: _buildMenuHeader(isExpandedRail),
                              extended: isExpandedRail,
                              labelType: NavigationRailLabelType.none,
                              minWidth: 68,
                              minExtendedWidth: 210,
                              destinations: [
                                const NavigationRailDestination(
                                  icon: Icon(Icons.co_present_outlined),
                                  selectedIcon: Icon(Icons.co_present),
                                  label: Text('Calls'),
                                ),
                                if (isBooking)
                                  const NavigationRailDestination(
                                    icon: Icon(Icons.auto_graph_outlined),
                                    selectedIcon: Icon(Icons.auto_graph),
                                    label: Text('Agile'),
                                  )
                                else
                                  NavigationRailDestination(
                                    icon: _badgeIcon(
                                      Icons.receipt_long_outlined,
                                      _pendingTransactionsCount,
                                    ),
                                    selectedIcon: _badgeIcon(
                                      Icons.receipt_long,
                                      _pendingTransactionsCount,
                                    ),
                                    label: const Text('Transactions'),
                                  ),
                              ],
                            ),
                          ),
                          _buildLogoutButton(isExpandedRail),
                          _buildAlertsButton(isExpandedRail, unread),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: IndexedStack(
                          index: safeIndex,
                          children: pages,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    }

    return Scaffold(
      body: IndexedStack(index: safeIndex, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: safeIndex,
        onTap: (idx) => _onTabSelected(idx, isBooking: isBooking),
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.co_present_outlined),
            activeIcon: Icon(Icons.co_present),
            label: 'Calls',
          ),
          if (isBooking)
            const BottomNavigationBarItem(
              icon: Icon(Icons.auto_graph_outlined),
              activeIcon: Icon(Icons.auto_graph),
              label: 'Agile',
            )
          else
            BottomNavigationBarItem(
              icon: _badgeIcon(
                Icons.receipt_long_outlined,
                _pendingTransactionsCount,
              ),
              activeIcon: _badgeIcon(
                Icons.receipt_long,
                _pendingTransactionsCount,
              ),
              label: 'Transactions',
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _logoutRequestSubscription?.cancel();
    super.dispose();
  }
}

class _AgileTab extends StatelessWidget {
  final int refreshTrigger;

  const _AgileTab({this.refreshTrigger = 0});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agile')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final maxContentWidth = constraints.maxWidth >= 900 ? 760.0 : 680.0;

          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth),
              child: SizedBox(
                height: constraints.maxHeight,
                child: AgileCallFormCard(refreshTrigger: refreshTrigger),
              ),
            ),
          );
        },
      ),
    );
  }
}
