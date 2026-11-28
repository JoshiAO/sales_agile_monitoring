import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:compact_sales_monitoring/services/transaction_sync_service.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';

/// Dedicated translucent overlay UI launched directly from `PdfInvoiceOverlayActivity`
/// when SFA exports/opens a Proforma Invoice PDF.
class InvoiceOverlayApp extends StatelessWidget {
  const InvoiceOverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sales Invoice Preview',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A3FB5),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const _InvoiceOverlayScreen(),
    );
  }
}

class _InvoiceOverlayScreen extends StatefulWidget {
  const _InvoiceOverlayScreen();

  @override
  State<_InvoiceOverlayScreen> createState() => _InvoiceOverlayScreenState();
}

class _InvoiceOverlayScreenState extends State<_InvoiceOverlayScreen> {
  static const MethodChannel _overlayChannel = MethodChannel(
    'com.agile.app.jao/invoice_overlay',
  );

  CapturedTransactionResult? _result;
  String? _error;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _overlayChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNewPayload' && call.arguments is Map) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        await _handlePayloadResponse(args);
      }
    });
    _loadAndProcessPayload();
  }

  Future<bool> _hasActiveAuthSession() async {
    if (FirebaseAuth.instance.currentUser != null) return true;
    try {
      final restored = await FirebaseAuth.instance
          .authStateChanges()
          .first
          .timeout(const Duration(seconds: 3));
      return restored != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadAndProcessPayload() async {
    try {
      final rawResponse = await _overlayChannel.invokeMapMethod<String, dynamic>(
        'getPendingPayload',
      );
      await _handlePayloadResponse(rawResponse);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to process invoice PDF: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _handlePayloadResponse(Map<String, dynamic>? rawResponse) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final isAuthed = await _hasActiveAuthSession();
      if (!isAuthed) {
        if (!mounted) return;
        setState(() {
          _error = 'Please sign in to Sales Agile Monitoring before capturing invoices.';
          _isLoading = false;
        });
        return;
      }

      final error = rawResponse?['error'] as String?;
      final payload = rawResponse?['payload'] as String?;

      if (error != null && error.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _error = error;
          _isLoading = false;
        });
        return;
      }

      if (payload == null || payload.trim().isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = 'No invoice content received from PDF.';
          _isLoading = false;
        });
        return;
      }

      final processed = await TransactionSyncService().processRawInvoiceText(
        rawText: payload,
      );

      if (!mounted) return;
      setState(() {
        _result = processed;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to process invoice PDF: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _closeOverlay() async {
    try {
      await _overlayChannel.invokeMethod<bool>('closeOverlay');
    } catch (_) {
      SystemNavigator.pop();
    }
  }

  Future<void> _handleBackNavigation() async {
    if (_result == null || _result!.blockedNoActiveCall) {
      await _closeOverlay();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Done with Preview?'),
        content: const Text(
          'Make sure you have finished copying this Sales Invoice before closing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Yes, Close'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _closeOverlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleBackNavigation();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 0.45),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: _buildBody(),
            ),
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 42),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Parsing SFA Invoice & Capturing Checkpoint...',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 42),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _loadAndProcessPayload,
                    child: const Text('Retry'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _closeOverlay,
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final result = _result!;
    final tx = result.transaction;
    final isBlocked = result.blockedNoActiveCall;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusHeaderBar(result: result),
        const SizedBox(height: 8),
        Flexible(
          child: SalesInvoiceViewer(
            transaction: tx,
            confirmOnClose: !isBlocked,
            showCloseButton: true,
            isPreviewOnly: isBlocked,
            onCloseRequested: _closeOverlay,
            onVoidPageRequested: isBlocked
                ? null
                : (pageNo, reason) async {
                    final voidResult =
                        await TransactionSyncService().voidPageAsSalesman(
                      transaction: tx,
                      pageNo: pageNo,
                      reason: reason,
                    );
                    if (!mounted) return voidResult.updatedTransaction;
                    setState(() {
                      _result = CapturedTransactionResult(
                        transaction: voidResult.updatedTransaction,
                        pages: result.pages,
                        isDuplicate: result.isDuplicate,
                        pdfSaveResult: result.pdfSaveResult,
                        uploadedNow: voidResult.updatedTransaction.isUploaded &&
                            !voidResult.updatedTransaction.needsRemoteUpdate,
                        hasIntegrityWarning: result.hasIntegrityWarning,
                        siExhausted: voidResult.exhausted,
                        hasNoSiBooklets:
                            !voidResult.updatedTransaction.hasAnySiAssigned,
                      );
                    });
                    final newPageSi =
                        voidResult.updatedTransaction.siNumberForPage(pageNo);
                    final msg = newPageSi != null
                        ? 'Voided SI ${voidResult.voidedEntry.siNumber}. Page $pageNo is now SI No. $newPageSi.'
                        : 'Voided SI ${voidResult.voidedEntry.siNumber}. SI booklet exhausted for remaining pages.';
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(msg)),
                    );
                    return voidResult.updatedTransaction;
                  },
          ),
        ),
      ],
    );
  }
}

class _StatusHeaderBar extends StatelessWidget {
  final CapturedTransactionResult result;

  const _StatusHeaderBar({required this.result});

  @override
  Widget build(BuildContext context) {
    final tx = result.transaction;
    final Color bgColor;
    final Color fgColor;
    final IconData icon;
    final String label;

    if (result.blockedNoActiveCall) {
      bgColor = Colors.red.shade50;
      fgColor = Colors.red.shade900;
      icon = Icons.warning_amber_rounded;
      label =
          'No Active Call — Make a First Call first before making a transaction. (Preview only; not saved and no SI number used)';
    } else if (result.isDuplicate) {
      bgColor = Colors.blue.shade50;
      fgColor = Colors.blue.shade800;
      icon = Icons.copy_all_outlined;
      label = 'Already Captured Today (Reprint Preview)';
    } else if (tx.isUploaded) {
      bgColor = Colors.green.shade50;
      fgColor = Colors.green.shade800;
      icon = Icons.cloud_done_outlined;
      label = 'Captured & Uploaded to Route';
    } else {
      bgColor = Colors.orange.shade50;
      fgColor = Colors.orange.shade900;
      icon = Icons.schedule;
      label = 'Captured Locally (Pending Upload)';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fgColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: fgColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: fgColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (result.pdfSaveResult != null)
            Text(
              result.pdfSaveResult!.savedToPublicDocuments
                  ? 'Saved to Documents'
                  : 'PDF Saved Locally',
              style: TextStyle(
                color: fgColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

