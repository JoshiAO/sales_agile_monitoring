import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/constants/app_constants.dart';
import 'package:compact_sales_monitoring/models/si_booklet_model.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/daily_invoice_pdf_service.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/services/transaction_storage_service.dart';
import 'package:compact_sales_monitoring/services/transaction_sync_service.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';
import 'package:compact_sales_monitoring/widgets/device_activation_banner.dart';

class SalesmanTransactionsScreen extends StatefulWidget {
  final int refreshTrigger;
  final VoidCallback? onPendingCountChanged;

  const SalesmanTransactionsScreen({
    super.key,
    this.refreshTrigger = 0,
    this.onPendingCountChanged,
  });

  @override
  State<SalesmanTransactionsScreen> createState() =>
      _SalesmanTransactionsScreenState();
}

class _SalesmanTransactionsScreenState extends State<SalesmanTransactionsScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _pdfChannel = MethodChannel(
    'com.agile.app.jao/pdf_storage',
  );
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  final TransactionStorageService _storage = TransactionStorageService();
  final TransactionSyncService _syncService = TransactionSyncService();
  final FirestoreService _firestore = FirestoreService();

  List<RouteTransaction> _transactions = const [];
  SalesmanSiBookletState? _bookletState;
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isOpeningPdf = false;
  bool _isDefaultPdfReader = false;
  int _loadGeneration = 0;

  DateTime get _today => DateTime.now();
  String get _todayDateStr => DateFormat('yyyy-MM-dd').format(_today);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (AppConstants.enableTransactionsFeature) {
      _loadData();
    } else {
      _isLoading = false;
    }
  }

  @override
  void didUpdateWidget(covariant SalesmanTransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTrigger != widget.refreshTrigger) {
      _loadData();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadData();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final gen = ++_loadGeneration;
    final user = context.read<AuthProvider>().currentUser;
    setState(() => _isLoading = true);

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final isDef = await _pdfChannel.invokeMethod<bool>(
          'isDefaultPdfHandler',
        );
        _isDefaultPdfReader = isDef ?? false;
      } catch (_) {}
    }

    final todayStr = _todayDateStr;
    final localBefore = await _storage.getTransactionsForDate(todayStr);
    var merged = localBefore;

    SalesmanSiBookletState? refreshedBooklets;
    if (user != null) {
      refreshedBooklets = await _syncService.refreshBookletsFromFirestore(
        user.uid,
        companyId: user.companyId,
      );
      try {
        final routes = await _firestore
            .getRoutesBySalesman(user.uid, todayStr)
            .timeout(const Duration(seconds: 8));
        if (routes.isNotEmpty) {
          final remoteTxs = routes.expand((r) => r.sortedTransactions).toList();
          merged = await _storage.mergeWithRemote(todayStr, remoteTxs);
        }
      } catch (_) {
        // Offline or unreachable — keep local transactions cleanly
      }
    }

    // Keep today's progressive daily PDF up to date if transactions exist
    // and either new remote transactions were merged or the PDF isn't on disk yet.
    if (!kIsWeb && merged.isNotEmpty) {
      final repCode = merged.first.salesRepCode.isNotEmpty
          ? merged.first.salesRepCode
          : (user?.fsName ?? user?.name ?? user?.uid ?? 'REP');
      try {
        final existingPath = await DailyInvoicePdfService.findExistingPrivatePdfPath(
          routeDate: todayStr,
          salesmanCode: repCode,
        );
        if (existingPath == null || merged.length > localBefore.length) {
          await DailyInvoicePdfService.rebuildAndSaveDailyPdf(
            routeDate: todayStr,
            salesmanCode: repCode,
            transactions: merged,
          );
        }
      } catch (e) {
        debugPrint('[SalesmanTransactionsScreen] Progressive PDF check failed: $e');
      }
    }

    if (!mounted || gen != _loadGeneration) return;
    setState(() {
      _transactions = merged;
      _bookletState = refreshedBooklets ?? _bookletState;
      _isLoading = false;
    });
    widget.onPendingCountChanged?.call();
  }

  Future<void> _syncPending() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    try {
      final uploaded = await _syncService.flushPendingTransactions();
      await _loadData();
      if (!mounted) return;
      final msg = uploaded.isEmpty
          ? 'No pending transactions uploaded. Make sure First Call is done and internet is active.'
          : 'Uploaded ${uploaded.length} pending transaction(s) to your route.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _openDailyPdf() async {
    if (_isOpeningPdf) return;
    if (_transactions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No transactions to export for today.')),
      );
      return;
    }

    _isOpeningPdf = true;
    try {
      final todayStr = _todayDateStr;
      final user = context.read<AuthProvider>().currentUser;
      final repCode = _transactions.first.salesRepCode.isNotEmpty
          ? _transactions.first.salesRepCode
          : (user?.fsName ?? user?.name ?? user?.uid ?? 'REP');

      // Always rebuild today's progressive PDF from the latest transaction list
      // so both private and public Documents copies reflect all captured invoices.
      final saved = await DailyInvoicePdfService.rebuildAndSaveDailyPdf(
        routeDate: todayStr,
        salesmanCode: repCode,
        transactions: _transactions,
      );
      final path = saved?.privateFilePath;

      if (path == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to generate PDF on this platform.')),
        );
        return;
      }

      final openedExternally = await DailyInvoicePdfService.openPdfExternally(path);
      if (!openedExternally) {
        final result = await OpenFilex.open(path);
        if (result.type != ResultType.done && mounted) {
          final meta = DailyInvoicePdfService.buildOutputMetadata(
            routeDate: todayStr,
            salesmanCode: repCode,
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('PDF saved at Documents/${meta.relativePath}'),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to generate or open PDF: $e')),
      );
    } finally {
      _isOpeningPdf = false;
    }
  }

  Future<void> _importPdfManually() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final user = context.read<AuthProvider>().currentUser;
    try {
      final res = await _pdfChannel.invokeMapMethod<String, dynamic>(
        'pickAndExtractPdf',
      );
      if (res == null) return;
      final isSfa = res['isSfaInvoice'] as bool? ?? false;
      final text = res['text'] as String? ?? '';
      final err = res['error'] as String?;

      if (err != null && err.isNotEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to read PDF: $err')),
        );
        return;
      }

      if (!isSfa || text.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Selected PDF is not a recognized SFA Proforma Invoice.'),
          ),
        );
        return;
      }

      final processed = await _syncService.processRawInvoiceText(
        rawText: text,
        fallbackSalesmanCode: user?.fsName ?? user?.name,
      );

      await _loadData();
      if (!mounted) return;
      await _openInvoiceModal(processed.transaction);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  Future<void> _injectSampleInvoice() async {
    final user = context.read<AuthProvider>().currentUser;
    final todayInvoiceDate = DateFormat('dd-MMM-yyyy hh:mm:ss a', 'en_US')
        .format(DateTime.now());
    final repCode = (user?.fsName?.trim().isNotEmpty == true)
        ? user!.fsName!.trim()
        : 'kne0024';
    final repName = (user?.name?.trim().isNotEmpty == true)
        ? user!.name!.trim()
        : 'SAMPLE SALESMAN';
    final uniqueCode = 'CBINVTEST${DateTime.now().millisecondsSinceEpoch}';

    final sampleText = '''
PROFORMA INVOICE
KNE
SalesRep Name:$repName
SalesRep Code:$repCode
Customer Name:CAREN STORE (SAMPLE)
Customer Code:B3103B0321
Address:SAN JOSEF PENARANDA NUEVA ECIJA
Invoice Code:$uniqueCode
Invoiced Date:$todayInvoiceDate
[PDF_TABLE_ROW]\t7524\tCream-O Choco Fudge 10s R. Pack 30g x 10 x 20\t2\tSub Case\t70.60\t141.20
[PDF_TABLE_ROW]\t7506\tCream-O Original Vanilla 10s R. Pack 30g x 10 x 20\t1\tSub Case\t70.60\t70.60
[PDF_TABLE_ROW]\t62727\tJnJ Pretzels Berry Knots 25 g\t5\tPiece\t7.71\t38.53
[PDF_TABLE_ROW]\t62728\tJnJ Pretzels Milky Knots 25g\t5\tPiece\t7.71\t38.53
[PDF_TABLE_ROW]\t7636\tPRESTO CREAMS CHOCOLATE 30g x 10 x 20\t1\tCase\t612.90\t612.90
[PDF_TABLE_ROW]\t7637\tPRESTO CREAMS PEANUT BUTTER 30g x 10x20\t1\tPiece\t6.13\t6.13
[PDF_TABLE_ROW]\t8404\tWAFRETS CHEESE BAR 24g x 10 x 24\t1\tPiece\t6.31\t6.31
[PDF_TABLE_ROW]\t8406\tWAFRETS CHOCO BAR 24g x 10 x 24\t1\tPiece\t6.31\t6.31
[PDF_TABLE_ROW]\t64480\tPIATTOS CHEESE 40g x 80\t5\tPiece\t15.98\t79.91
[PDF_TABLE_ROW]\t56280\tPayless XTRA BIG Chilimansi (128g)\t6\tPiece\t17.84\t107.05
Grand total = 1107.47
''';

    final processed = await _syncService.processRawInvoiceText(
      rawText: sampleText,
      fallbackSalesmanCode: repCode,
    );
    await _loadData();
    if (!mounted) return;
    await _openInvoiceModal(processed.transaction);
  }

  Future<void> _showSetupGuide() async {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Set as Default PDF Reader'),
        content: const Text(
          'To automatically pop up the 9-line Sales Invoice modal whenever you tap "Export PDF" in the SFA app:\n\n'
          '1. In SFA, export any invoice PDF.\n'
          '2. When Android asks "Open with", choose Sales Agile Monitoring and tap "Always".\n\n'
          'Non-invoice PDFs opened on your tablet will automatically be passed through to your normal PDF viewer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Close'),
          ),
          if (!kIsWeb && Platform.isAndroid)
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogCtx);
                try {
                  await _pdfChannel.invokeMethod<bool>('openDefaultAppsSettings');
                } catch (_) {}
              },
              child: const Text('Open Default Apps'),
            ),
        ],
      ),
    );
  }

  Future<void> _openInvoiceModal(RouteTransaction tx) async {
    final user = context.read<AuthProvider>().currentUser;
    var currentTx = tx;
    var didMutate = false;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SalesInvoiceViewer(
                transaction: currentTx,
                confirmOnClose: false,
                showCloseButton: true,
                onCloseRequested: () => Navigator.pop(dialogCtx),
                onVoidPageRequested: (pageNo, reason) async {
                  final voidResult = await _syncService.voidPageAsSalesman(
                    transaction: currentTx,
                    pageNo: pageNo,
                    reason: reason,
                    salesmanName: user?.name ?? user?.email,
                    fallbackSalesmanCode: user?.fsName ?? user?.name,
                  );
                  didMutate = true;
                  setDialogState(() {
                    currentTx = voidResult.updatedTransaction;
                  });
                  if (mounted) {
                    final nextSi =
                        voidResult.updatedTransaction.siNumberForPage(pageNo);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          nextSi != null
                              ? 'Voided SI ${voidResult.voidedEntry.siNumber}. Page $pageNo is now SI No. $nextSi.'
                              : 'Voided SI ${voidResult.voidedEntry.siNumber}. Booklet exhausted.',
                        ),
                      ),
                    );
                  }
                  return voidResult.updatedTransaction;
                },
              ),
            ),
          ),
        ),
      ),
    );
    if (didMutate && mounted) {
      await _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConstants.enableTransactionsFeature) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transactions')),
        body: DeviceActivationBannerWrapper(
          child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.amber.shade50,
                  child: Icon(
                    Icons.construction_rounded,
                    size: 32,
                    color: Colors.amber.shade800,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Under Development',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'The Transactions module is currently under development and will be enabled in an upcoming release.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ),
        ),
      );
    }

    final pendingCount = _transactions.where((t) => !t.isUploaded).length;
    final totalAmount = _transactions.fold<double>(
      0.0,
      (sum, t) => sum + t.totalAmount,
    );
    final totalCs = _transactions.fold<double>(0.0, (sum, t) => sum + t.csQty);
    final totalSc = _transactions.fold<double>(0.0, (sum, t) => sum + t.scQty);
    final totalPc = _transactions.fold<double>(0.0, (sum, t) => sum + t.pcQty);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'import') {
                _importPdfManually();
              } else if (kDebugMode && value == 'sample') {
                _injectSampleInvoice();
              } else if (value == 'guide') {
                _showSetupGuide();
              }
            },
            itemBuilder: (context) => [
              if (!kIsWeb && Platform.isAndroid)
                const PopupMenuItem(
                  value: 'import',
                  child: ListTile(
                    leading: Icon(Icons.upload_file),
                    title: Text('Import SFA PDF'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              const PopupMenuItem(
                value: 'guide',
                child: ListTile(
                  leading: Icon(Icons.picture_as_pdf_outlined),
                  title: Text('Default PDF Setup Guide'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (kDebugMode)
                const PopupMenuItem(
                  value: 'sample',
                  child: ListTile(
                    leading: Icon(Icons.science_outlined),
                    title: Text('Test Sample Invoice'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const DeviceActivationBanner(),
          if (!kIsWeb && Platform.isAndroid) _buildStatusBar(pendingCount),
          _buildTodayHeaderStrip(),
          _buildDailySummaryStrip(
            count: _transactions.length,
            cs: totalCs,
            sc: totalSc,
            pc: totalPc,
            total: totalAmount,
          ),
          const Divider(height: 1),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _transactions.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _loadData,
                        child: ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: _transactions.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            return _TransactionCard(
                              transaction: _transactions[index],
                              moneyFormat: _moneyFormat,
                              onTap: () =>
                                  _openInvoiceModal(_transactions[index]),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(int pendingCount) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F0FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDCD6FA)),
      ),
      child: Row(
        children: [
          Icon(
            _isDefaultPdfReader ? Icons.check_circle : Icons.picture_as_pdf,
            size: 18,
            color: _isDefaultPdfReader
                ? Colors.green.shade700
                : const Color(0xFF4A3FB5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: _showSetupGuide,
              child: Text(
                _isDefaultPdfReader
                    ? 'PDF Interceptor: Default Reader Active'
                    : 'PDF Interceptor: Tap to Set Default',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2F2A57),
                ),
              ),
            ),
          ),
          if (pendingCount > 0) ...[
            FilledButton.tonalIcon(
              onPressed: _isSyncing ? null : _syncPending,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: Colors.orange.shade100,
                foregroundColor: Colors.orange.shade900,
              ),
              icon: _isSyncing
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 15),
              label: Text(
                'Sync ($pendingCount)',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),
          ],
          OutlinedButton.icon(
            onPressed: _openDailyPdf,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text(
              'PDF',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodayHeaderStrip() {
    final todayLabel = DateFormat('EEE, MMM d, yyyy').format(_today);
    final booklet = _bookletState;
    final nextSi = booklet?.nextAvailableFormatted;
    final remaining = booklet?.totalRemainingPages ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.today_rounded,
                size: 16,
                color: Colors.deepPurple.shade700,
              ),
              const SizedBox(width: 6),
              Text(
                'Today  •  $todayLabel',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade800,
                ),
              ),
            ],
          ),
          if (booklet != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: nextSi != null
                    ? Colors.teal.shade50
                    : Colors.amber.shade50,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: nextSi != null
                      ? Colors.teal.shade200
                      : Colors.amber.shade300,
                ),
              ),
              child: Text(
                nextSi != null
                    ? 'Next SI: $nextSi ($remaining left)'
                    : (booklet.hasBooklets
                        ? 'SI Booklet Exhausted'
                        : 'No SI Booklet Assigned'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: nextSi != null
                      ? Colors.teal.shade900
                      : Colors.amber.shade900,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDailySummaryStrip({
    required int count,
    required double cs,
    required double sc,
    required double pc,
    required double total,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '$count Invoice${count == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'CS:${formatQuantity(cs)}  SC:${formatQuantity(sc)}  PC:${formatQuantity(pc)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _moneyFormat.format(total),
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2F2A57),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 54,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            const Text(
              'No captured transactions for today',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Export an invoice PDF from SFA (with Sales Agile Monitoring set as your PDF viewer) or import one manually.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
            ),
            if (!kIsWeb && Platform.isAndroid) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _importPdfManually,
                icon: const Icon(Icons.upload_file),
                label: const Text('Import SFA PDF'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TransactionCard extends StatelessWidget {
  final RouteTransaction transaction;
  final NumberFormat moneyFormat;
  final VoidCallback onTap;

  const _TransactionCard({
    required this.transaction,
    required this.moneyFormat,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isUploaded = transaction.isUploaded;
    final badgeBg = isUploaded ? Colors.green.shade50 : Colors.orange.shade50;
    final badgeFg = isUploaded ? Colors.green.shade800 : Colors.orange.shade900;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      transaction.customerName.isEmpty
                          ? 'Unknown Customer'
                          : transaction.customerName,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        transaction.invoiceCode,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF3D356B),
                        ),
                      ),
                      if (transaction.formattedSiSeriesSummary.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'SI: ${transaction.formattedSiSeriesSummary}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: Colors.red.shade800,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeBg,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          isUploaded
                              ? (transaction.needsRemoteUpdate
                                  ? 'Sync Pending'
                                  : 'Uploaded')
                              : 'Pending',
                          style: TextStyle(
                            color: badgeFg,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    transaction.customerCode,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    transaction.invoiceDate,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                transaction.address,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'CS:${formatQuantity(transaction.csQty)}  '
                      'SC:${formatQuantity(transaction.scQty)}  '
                      'PC:${formatQuantity(transaction.pcQty)}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    moneyFormat.format(transaction.totalAmount),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1E1B3A),
                    ),
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

