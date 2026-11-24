import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/storage_url_resolver.dart';
import 'package:compact_sales_monitoring/widgets/itemized_invoice_table.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';
import 'package:compact_sales_monitoring/widgets/web_storage_image.dart';
import 'package:compact_sales_monitoring/widgets/route_data_usage_view.dart';
import 'package:compact_sales_monitoring/widgets/route_call_detail_card.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class RouteDetailModal extends StatefulWidget {
  final SalesRoute route;
  final AppUser salesman;
  final Future<void> Function()? onRouteChanged;

  const RouteDetailModal({
    super.key,
    required this.route,
    required this.salesman,
    this.onRouteChanged,
  });

  @override
  State<RouteDetailModal> createState() => _RouteDetailModalState();
}

class _RouteDetailModalState extends State<RouteDetailModal> {
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');
  static const Color _tealPrimary = Color(0xFF0F766E);

  RoutePoint? _viewingDataPoint;
  RouteTransaction? _selectedTransaction;
  bool _showFullTable = false;
  bool _isApprovingRetake = false;
  final TextEditingController _txSearchController = TextEditingController();
  String _txSearchQuery = '';
  final Map<String, Future<String?>> _imageUrlFutureCache = {};

  Future<String?> _getCachedImageUrl(String imageUrl) {
    return _imageUrlFutureCache.putIfAbsent(
      imageUrl,
      () => StorageUrlResolver.resolveUrl(imageUrl),
    );
  }

  @override
  void didUpdateWidget(covariant RouteDetailModal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route.routeId != widget.route.routeId ||
        oldWidget.route.first.imageUrl != widget.route.first.imageUrl ||
        oldWidget.route.last.imageUrl != widget.route.last.imageUrl) {
      _imageUrlFutureCache.clear();
    }
    if (_selectedTransaction != null) {
      final match = widget.route.sortedTransactions.where(
        (t) => t.transactionId == _selectedTransaction!.transactionId,
      );
      _selectedTransaction = match.isNotEmpty ? match.first : null;
    }
  }

  @override
  void dispose() {
    _txSearchController.dispose();
    super.dispose();
  }

  Widget _buildImageError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined),
            const SizedBox(height: 8),
            Text(message),
          ],
        ),
      ),
    );
  }

  Widget _buildAdaptiveImage({
    required String imageUrl,
    required BoxFit fit,
    double? width,
    double? height,
  }) {
    if (kIsWeb) {
      return WebStorageImage(
        imageUrl: imageUrl,
        fit: fit,
        width: width,
        height: height,
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: fit,
      width: width,
      height: height,
      placeholder: (context, url) =>
          const Center(child: CircularProgressIndicator()),
      errorWidget: (context, url, error) {
        return _buildImageError('Failed to load image');
      },
    );
  }

  Widget _buildRouteImage(String imageUrl) {
    return FutureBuilder<String?>(
      future: _getCachedImageUrl(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.expand(
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final resolvedImageUrl = snapshot.data;
        if (resolvedImageUrl == null || resolvedImageUrl.isEmpty) {
          return const SizedBox.expand(
            child: Center(child: Icon(Icons.error_outline)),
          );
        }

        return _buildAdaptiveImage(
          imageUrl: resolvedImageUrl,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
        );
      },
    );
  }

  Future<void> _openGoogleMaps(
    BuildContext context,
    double lat,
    double lon,
  ) async {
    final googleMapsUri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
    );
    final geoUri = Uri.parse('geo:$lat,$lon?q=$lat,$lon(Call Location)');

    try {
      final openedGoogleMaps = await launchUrl(
        googleMapsUri,
        mode: LaunchMode.externalApplication,
      );
      if (openedGoogleMaps) return;

      final openedGeo = await launchUrl(
        geoUri,
        mode: LaunchMode.externalApplication,
      );
      if (openedGeo) return;

      final openedInBrowser = await launchUrl(
        googleMapsUri,
        mode: LaunchMode.platformDefault,
      );
      if (openedInBrowser) return;
    } catch (_) {
      // Fall through to show message below.
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Unable to open map for this location.')),
    );
  }

  void _openFullImagePreview(
    BuildContext context,
    String imageUrl,
    String title,
  ) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: FutureBuilder<String?>(
                  future: _getCachedImageUrl(imageUrl),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final resolvedImageUrl = snapshot.data;
                    if (resolvedImageUrl == null || resolvedImageUrl.isEmpty) {
                      return _buildImageError('Failed to load image');
                    }

                    return InteractiveViewer(
                      child: _buildAdaptiveImage(
                        imageUrl: resolvedImageUrl,
                        fit: BoxFit.contain,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _approveRetake(
    BuildContext context, {
    required bool isFirst,
  }) async {
    if (_isApprovingRetake) return;
    final authProvider = context.read<AuthProvider>();
    final approver = authProvider.currentUser;
    if (approver == null) return;

    setState(() => _isApprovingRetake = true);
    try {
      await FirestoreService().approveCallRetake(
        routeId: widget.route.routeId,
        isFirst: isFirst,
        approvedBy: approver.uid,
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${isFirst ? 'First' : 'Last'} call retake approved.'),
        ),
      );

      if (widget.onRouteChanged != null) {
        await widget.onRouteChanged!();
      }

      if (!context.mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to approve retake: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isApprovingRetake = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final salesman = widget.salesman;
    final currentUser = context.watch<AuthProvider>().currentUser;
    final canApprove =
        currentUser?.role == UserRole.supervisor ||
        currentUser?.role == UserRole.superuser;

    final size = MediaQuery.sizeOf(context);
    final isWide = size.width >= 900;
    final maxAllowedWidth = (size.width - 32).clamp(280.0, 1280.0);
    final dialogWidth = isWide
        ? math.min((size.width * 0.84).clamp(920.0, 1280.0), maxAllowedWidth)
        : maxAllowedWidth.clamp(280.0, 720.0);
    final dialogHeight = isWide
        ? (size.height * 0.88).clamp(480.0, 900.0)
        : size.height * 0.90;

    final transactions = route.sortedTransactions;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: const Color(0xFFF8FAFC),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            _buildHeader(context, route, salesman, transactions, isWide),
            const Divider(height: 1, thickness: 1),
            Expanded(
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 46,
                          child: _buildLeftCallsPane(
                            context,
                            route,
                            canApprove,
                          ),
                        ),
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: Colors.grey.shade200,
                        ),
                        Expanded(
                          flex: 54,
                          child: _buildRightTransactionsPane(
                            context,
                            transactions,
                          ),
                        ),
                      ],
                    )
                  : DefaultTabController(
                      length: 2,
                      child: Column(
                        children: [
                          Container(
                            color: Colors.white,
                            child: TabBar(
                              labelColor: _tealPrimary,
                              unselectedLabelColor: Colors.grey.shade600,
                              indicatorColor: _tealPrimary,
                              tabs: [
                                const Tab(
                                  icon: Icon(Icons.route_outlined, size: 18),
                                  text: 'Calls & Route',
                                ),
                                Tab(
                                  icon: const Icon(
                                    Icons.receipt_long_outlined,
                                    size: 18,
                                  ),
                                  text: 'Transactions (${transactions.length})',
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _buildLeftCallsPane(context, route, canApprove),
                                _buildRightTransactionsPane(
                                  context,
                                  transactions,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    SalesRoute route,
    AppUser salesman,
    List<RouteTransaction> transactions,
    bool isWide,
  ) {
    final displayName = (salesman.name != null && salesman.name!.trim().isNotEmpty)
        ? salesman.name!.trim()
        : salesman.email;
    final showEmailSubtitle =
        salesman.name != null &&
        salesman.name!.trim().isNotEmpty &&
        salesman.email.isNotEmpty;
    final routeDateStr = DateFormat('MMM d, yyyy').format(route.first.timestamp);
    final txTotal = transactions.fold<double>(0.0, (s, t) => s + t.totalAmount);
    final callCount = route.hasLastCall ? '2/2 Calls' : '1/2 Calls';

    return Container(
      color: Colors.white,
      padding: EdgeInsets.symmetric(
        horizontal: isWide ? 20 : 14,
        vertical: 12,
      ),
      child: Row(
        children: [
          // Salesman Avatar
          if (salesman.profilePic != null && salesman.profilePic!.isNotEmpty)
            ClipOval(
              child: SizedBox(
                width: 42,
                height: 42,
                child: FutureBuilder<String?>(
                  future: _getCachedImageUrl(salesman.profilePic!),
                  builder: (context, snap) {
                    final url = snap.data;
                    if (url == null || url.isEmpty) {
                      return Container(
                        color: Colors.teal.shade50,
                        child: const Icon(Icons.person_rounded, color: _tealPrimary),
                      );
                    }
                    return _buildAdaptiveImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      width: 42,
                      height: 42,
                    );
                  },
                ),
              ),
            )
          else
            CircleAvatar(
              radius: 21,
              backgroundColor: Colors.teal.shade50,
              child: const Icon(Icons.person_rounded, color: _tealPrimary),
            ),
          const SizedBox(width: 12),

          // Name, Email, Status & Date
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: salesman.active
                            ? const Color(0xFFCCFBF1)
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        salesman.active ? 'Active' : 'Inactive',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: salesman.active
                              ? _tealPrimary
                              : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  showEmailSubtitle
                      ? '${salesman.email}  •  $routeDateStr'
                      : 'Salesman  •  $routeDateStr',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // Wide KPI Pills
          if (isWide) ...[
            const SizedBox(width: 12),
            _HeaderKpiPill(
              icon: Icons.camera_alt_outlined,
              label: callCount,
              bgColor: const Color(0xFFF1F5F9),
              fgColor: const Color(0xFF334155),
            ),
            const SizedBox(width: 8),
            _HeaderKpiPill(
              icon: Icons.route_outlined,
              label: 'Est. ${route.estimatedDistanceKm.toStringAsFixed(2)} km',
              bgColor: const Color(0xFFF1F5F9),
              fgColor: const Color(0xFF334155),
            ),
            const SizedBox(width: 8),
            _HeaderKpiPill(
              icon: Icons.receipt_long_rounded,
              label:
                  '${transactions.length} ${transactions.length == 1 ? 'Invoice' : 'Invoices'} • ₱${_moneyFormat.format(txTotal)}',
              bgColor: Colors.teal.shade50,
              fgColor: _tealPrimary,
              borderColor: Colors.teal.shade200,
            ),
          ],

          const SizedBox(width: 10),
          IconButton(
            onPressed: () => Navigator.pop(context),
            tooltip: 'Close',
            style: IconButton.styleFrom(
              backgroundColor: Colors.grey.shade100,
              foregroundColor: Colors.grey.shade800,
            ),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftCallsPane(
    BuildContext context,
    SalesRoute route,
    bool canApprove,
  ) {
    return Container(
      color: const Color(0xFFF8FAFC),
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topLeft,
            children: [
              ...previousChildren,
              ?currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.04, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: child,
            ),
          );
        },
        child: _viewingDataPoint != null
            ? SizedBox(
                key: const ValueKey('left_data_view'),
                width: double.infinity,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: RouteDataUsageView(
                    point: _viewingDataPoint!,
                    onBack: () => setState(() => _viewingDataPoint = null),
                  ),
                ),
              )
            : SizedBox(
                key: const ValueKey('left_calls_view'),
                width: double.infinity,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionHeading(
                        icon: Icons.fact_check_outlined,
                        title: 'Call Verification & Telemetry',
                      ),
                      const SizedBox(height: 12),

                      // First Call Card
                      RouteCallDetailCard(
                        title: 'First Call (Start)',
                        point: route.first,
                        accentColor: _tealPrimary,
                        imageWidget: _buildRouteImage(route.first.imageUrl),
                        onOpenFullImage: () => _openFullImagePreview(
                          context,
                          route.first.imageUrl,
                          'First Call Image',
                        ),
                        onOpenMaps: () => _openGoogleMaps(
                          context,
                          route.first.lat,
                          route.first.lon,
                        ),
                        onDataTap: () {
                          setState(() => _viewingDataPoint = route.first);
                        },
                        canApproveRetake:
                            canApprove &&
                            route.firstRetakeRequested &&
                            !route.firstRetakeApproved,
                        onApproveRetake: () =>
                            _approveRetake(context, isFirst: true),
                        approveRetakeLabel: 'Approve Retake',
                      ),
                      const SizedBox(height: 14),

                      // Last Call Card or Pending Placeholder
                      if (route.hasLastCall)
                        RouteCallDetailCard(
                          title: 'Last Call (End)',
                          point: route.last,
                          accentColor: const Color(0xFF2563EB),
                          imageWidget: _buildRouteImage(route.last.imageUrl),
                          onOpenFullImage: () => _openFullImagePreview(
                            context,
                            route.last.imageUrl,
                            'Last Call Image',
                          ),
                          onOpenMaps: () => _openGoogleMaps(
                            context,
                            route.last.lat,
                            route.last.lon,
                          ),
                          onDataTap: () {
                            setState(() => _viewingDataPoint = route.last);
                          },
                          canApproveRetake:
                              canApprove &&
                              route.lastRetakeRequested &&
                              !route.lastRetakeApproved,
                          onApproveRetake: () =>
                              _approveRetake(context, isFirst: false),
                          approveRetakeLabel: 'Approve Retake',
                        )
                      else
                        _buildPendingLastCallCard(),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildPendingLastCallCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.hourglass_empty_rounded,
              size: 18,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Last Call (End)',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Last call has not been captured yet.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Pending',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightTransactionsPane(
    BuildContext context,
    List<RouteTransaction> transactions,
  ) {
    return Container(
      color: Colors.white,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _selectedTransaction != null
            ? _buildInlineTransactionInspector(
                context,
                _selectedTransaction!,
                transactions.length,
              )
            : _buildTransactionsListView(context, transactions),
      ),
    );
  }

  Widget _buildTransactionsListView(
    BuildContext context,
    List<RouteTransaction> transactions,
  ) {
    final total = transactions.fold<double>(0.0, (s, t) => s + t.totalAmount);
    final cs = transactions.fold<double>(0.0, (s, t) => s + t.csQty);
    final sc = transactions.fold<double>(0.0, (s, t) => s + t.scQty);
    final pc = transactions.fold<double>(0.0, (s, t) => s + t.pcQty);

    final query = _txSearchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? transactions
        : transactions.where((tx) {
            return tx.customerName.toLowerCase().contains(query) ||
                tx.invoiceCode.toLowerCase().contains(query) ||
                tx.address.toLowerCase().contains(query);
          }).toList();

    return Column(
      key: const ValueKey('tx_list_view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SectionHeading(
                    icon: Icons.receipt_long_rounded,
                    title: 'Captured Transactions',
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${transactions.length} ${transactions.length == 1 ? 'Invoice' : 'Invoices'}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: _tealPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Summary Totals Strip
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.teal.shade50, const Color(0xFFF0FDFA)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.teal.shade200),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'TOTAL CAPTURED SALES',
                            style: TextStyle(
                              fontSize: 10.5,
                              letterSpacing: 0.6,
                              fontWeight: FontWeight.w700,
                              color: Colors.teal.shade800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '₱${_moneyFormat.format(total)}',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Colors.teal.shade900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _UomChip(label: 'CS', value: formatQuantity(cs)),
                        _UomChip(label: 'SC', value: formatQuantity(sc)),
                        _UomChip(label: 'PC', value: formatQuantity(pc)),
                      ],
                    ),
                  ],
                ),
              ),

              // Search bar when 3+ transactions
              if (transactions.length >= 3) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _txSearchController,
                  onChanged: (v) => setState(() => _txSearchQuery = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search customer name or invoice code…',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: _txSearchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 16),
                            onPressed: () {
                              _txSearchController.clear();
                              setState(() => _txSearchQuery = '');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),

        // Transaction List or Empty State
        Expanded(
          child: transactions.isEmpty
              ? _buildEmptyTransactionsState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No Captured Transactions',
                  subtitle:
                      'Invoices exported from SFA during this route will appear here automatically.',
                )
              : filtered.isEmpty
                  ? _buildEmptyTransactionsState(
                      icon: Icons.search_off_rounded,
                      title: 'No matching invoices',
                      subtitle: 'Try a different customer name or invoice code.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final tx = filtered[index];
                        final originalIndex = transactions.indexOf(tx) + 1;
                        return _TransactionListCard(
                          sequenceNumber: originalIndex,
                          transaction: tx,
                          moneyFormat: _moneyFormat,
                          onTap: () {
                            setState(() {
                              _selectedTransaction = tx;
                              _showFullTable = false;
                            });
                          },
                          onOpenMaps: tx.hasValidLocation
                              ? () => _openGoogleMaps(context, tx.lat, tx.lon)
                              : null,
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildEmptyTransactionsState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineTransactionInspector(
    BuildContext context,
    RouteTransaction tx,
    int totalCount,
  ) {
    return Column(
      key: ValueKey('tx_detail_${tx.transactionId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Back & Title Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: const Color(0xFFF0FDFA),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _selectedTransaction = null),
                icon: const Icon(Icons.arrow_back_rounded, size: 17),
                label: Text('Transactions ($totalCount)'),
                style: TextButton.styleFrom(
                  foregroundColor: _tealPrimary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.customerName.isEmpty
                          ? 'Captured Invoice'
                          : tx.customerName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${tx.invoiceCode}  •  ${DateFormat('hh:mm a').format(tx.capturedAt)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.grey.shade700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (tx.hasValidLocation)
                OutlinedButton.icon(
                  onPressed: () => _openGoogleMaps(context, tx.lat, tx.lon),
                  icon: const Icon(Icons.location_on_outlined, size: 15),
                  label: const Text('Map'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _tealPrimary,
                    side: BorderSide(color: Colors.teal.shade300),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),

        // View Mode Toggle Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(
                    value: false,
                    icon: Icon(Icons.description_outlined, size: 15),
                    label: Text('9-Line Invoice'),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    icon: Icon(Icons.table_rows_outlined, size: 15),
                    label: Text('Full Table'),
                  ),
                ],
                selected: {_showFullTable},
                onSelectionChanged: (sel) {
                  setState(() => _showFullTable = sel.first);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Text(
                '₱${_moneyFormat.format(tx.totalAmount)}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: _tealPrimary,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Viewer Body
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _showFullTable
                ? ItemizedInvoiceTable(transaction: tx, columnSpacing: 18)
                : SalesInvoiceViewer(
                    key: ValueKey(tx.transactionId),
                    transaction: tx,
                    showCloseButton: false,
                  ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionHeading({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: const Color(0xFF0F766E)),
        const SizedBox(width: 7),
        Text(
          title,
          style: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }
}

class _HeaderKpiPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bgColor;
  final Color fgColor;
  final Color? borderColor;

  const _HeaderKpiPill({
    required this.icon,
    required this.label,
    required this.bgColor,
    required this.fgColor,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor ?? Colors.transparent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fgColor),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fgColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _UomChip extends StatelessWidget {
  final String label;
  final String value;

  const _UomChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.teal.shade200),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: Colors.teal.shade900,
        ),
      ),
    );
  }
}

class _TransactionListCard extends StatelessWidget {
  final int sequenceNumber;
  final RouteTransaction transaction;
  final NumberFormat moneyFormat;
  final VoidCallback onTap;
  final VoidCallback? onOpenMaps;

  const _TransactionListCard({
    required this.sequenceNumber,
    required this.transaction,
    required this.moneyFormat,
    required this.onTap,
    this.onOpenMaps,
  });

  @override
  Widget build(BuildContext context) {
    final tx = transaction;
    final capturedTime = DateFormat('hh:mm a').format(tx.capturedAt);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        hoverColor: const Color(0xFFF0FDFA),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: #Seq + Customer Name + Grand Total
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F766E),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '#$sequenceNumber',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tx.customerName.isEmpty
                          ? 'Unknown Customer'
                          : tx.customerName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '₱${moneyFormat.format(tx.totalAmount)}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0F766E),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),

              // Row 2: Invoice Code + Time
              Row(
                children: [
                  Icon(
                    Icons.tag_rounded,
                    size: 13,
                    color: Colors.grey.shade500,
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(
                      tx.invoiceCode,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.schedule_rounded,
                    size: 12.5,
                    color: Colors.grey.shade500,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    capturedTime,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Row 3: Items + UOMs + Map + View CTA
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _MiniTag(
                          text:
                              '${tx.items.length} ${tx.items.length == 1 ? 'item' : 'items'}',
                        ),
                        if (tx.csQty > 0)
                          _MiniTag(
                            text: 'CS: ${formatQuantity(tx.csQty)}',
                            tinted: true,
                          ),
                        if (tx.scQty > 0)
                          _MiniTag(
                            text: 'SC: ${formatQuantity(tx.scQty)}',
                            tinted: true,
                          ),
                        if (tx.pcQty > 0)
                          _MiniTag(
                            text: 'PC: ${formatQuantity(tx.pcQty)}',
                            tinted: true,
                          ),
                      ],
                    ),
                  ),
                  if (onOpenMaps != null)
                    IconButton(
                      onPressed: onOpenMaps,
                      tooltip: 'Open transaction location in Maps',
                      icon: const Icon(Icons.location_on_outlined, size: 17),
                      color: const Color(0xFF0F766E),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'View',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.teal.shade800,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: Colors.teal.shade800,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  final String text;
  final bool tinted;

  const _MiniTag({required this.text, this.tinted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tinted ? Colors.teal.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: tinted ? Colors.teal.shade900 : Colors.grey.shade700,
        ),
      ),
    );
  }
}
