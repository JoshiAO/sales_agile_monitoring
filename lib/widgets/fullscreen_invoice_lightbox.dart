import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:compact_sales_monitoring/models/transaction_model.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/invoice_paginator.dart';
import 'package:compact_sales_monitoring/services/virtual_printer/sfa_invoice_parser.dart';
import 'package:compact_sales_monitoring/widgets/sales_invoice_viewer.dart';

/// Displays a formatted 9-line BIR Sales Invoice floating directly over a
/// full-screen dimmed overlay (no outer modal card background), with left/right
/// navigation arrows, semi-transparent pagination dots, and optional encoder
/// Void / Un-Void actions.
Future<void> showFullscreenInvoiceLightbox(
  BuildContext context, {
  required RouteTransaction transaction,
  Future<RouteTransaction?> Function(int pageNo)? onVoidPageRequested,
  Future<RouteTransaction?> Function(String voidedSiNumber)?
      onUnvoidSiRequested,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss Invoice Preview',
    barrierColor: Colors.black.withValues(alpha: 0.74),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return FullscreenInvoiceLightbox(
        transaction: transaction,
        onVoidPageRequested: onVoidPageRequested,
        onUnvoidSiRequested: onUnvoidSiRequested,
      );
    },
    transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

class FullscreenInvoiceLightbox extends StatefulWidget {
  final RouteTransaction transaction;
  final Future<RouteTransaction?> Function(int pageNo)? onVoidPageRequested;
  final Future<RouteTransaction?> Function(String voidedSiNumber)?
      onUnvoidSiRequested;

  const FullscreenInvoiceLightbox({
    super.key,
    required this.transaction,
    this.onVoidPageRequested,
    this.onUnvoidSiRequested,
  });

  @override
  State<FullscreenInvoiceLightbox> createState() =>
      _FullscreenInvoiceLightboxState();
}

class _FullscreenInvoiceLightboxState extends State<FullscreenInvoiceLightbox> {
  late RouteTransaction _transaction;
  late List<InvoicePageData> _pages;
  late final PageController _pageController;
  final FocusNode _focusNode = FocusNode();
  int _currentPage = 0;
  bool _isZoomed = false;
  bool _isMutating = false;

  @override
  void initState() {
    super.initState();
    _transaction = widget.transaction;
    _pages = InvoicePaginator.paginate(_transaction.items);
    _pageController = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  Future<void> _handleVoidCurrentPage() async {
    if (_isMutating || widget.onVoidPageRequested == null) return;
    setState(() => _isMutating = true);
    try {
      final updated = await widget.onVoidPageRequested!(_currentPage + 1);
      if (updated != null && mounted) {
        setState(() {
          _transaction = updated;
          _pages = InvoicePaginator.paginate(_transaction.items);
        });
      }
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }
  }

  Future<void> _handleUnvoidSi(String voidedSi) async {
    if (_isMutating || widget.onUnvoidSiRequested == null) return;
    setState(() => _isMutating = true);
    try {
      final updated = await widget.onUnvoidSiRequested!(voidedSi);
      if (updated != null && mounted) {
        setState(() {
          _transaction = updated;
          _pages = InvoicePaginator.paginate(_transaction.items);
        });
      }
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int index) {
    final target = index.clamp(0, _pages.length - 1);
    if (target == _currentPage) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _goToPage(_currentPage - 1);
    }
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _goToPage(_currentPage + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sheetDate = SfaInvoiceParser.formatSheetDate(
      _transaction.invoiceDate,
      fallback: _transaction.capturedAt,
    );
    final size = MediaQuery.sizeOf(context);
    final isCompact = size.width < 720;
    final sheetMaxWidth = (size.width - (isCompact ? 32 : 168)).clamp(
      280.0,
      780.0,
    );
    final sheetMaxHeight = (size.height - 175).clamp(320.0, 820.0);
    final canGoPrev = _currentPage > 0;
    final canGoNext = _currentPage < _pages.length - 1;
    final currentPageNo = _currentPage + 1;
    final currentPageSi = _transaction.siNumberForPage(currentPageNo);
    final canVoidCurrent =
        widget.onVoidPageRequested != null && currentPageSi != null;
    final voidedEntries = _transaction.voidedSiEntries;

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _previousPage();
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _nextPage();
        } else if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).maybePop();
        }
      },
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Stack(
            children: [
              // Click-outside dimmed backdrop area
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
              // Center invoice sheet + floating left/right arrows
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 44,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (!isCompact)
                              _NavArrowButton(
                                icon: Icons.chevron_left_rounded,
                                tooltip: 'Previous page',
                                enabled: canGoPrev,
                                onPressed: _previousPage,
                              ),
                            if (!isCompact) const SizedBox(width: 14),
                            GestureDetector(
                              // Prevent taps on the invoice itself from closing the lightbox
                              onTap: () {},
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: sheetMaxWidth,
                                  maxHeight: sheetMaxHeight,
                                ),
                                child: PageView.builder(
                                  controller: _pageController,
                                  physics: _isZoomed
                                      ? const NeverScrollableScrollPhysics()
                                      : const BouncingScrollPhysics(),
                                  itemCount: _pages.length,
                                  onPageChanged: (idx) {
                                    setState(() {
                                      _currentPage = idx;
                                      _isZoomed = false;
                                    });
                                  },
                                  itemBuilder: (context, index) {
                                    return SalesInvoicePageCard(
                                      transaction: _transaction,
                                      page: _pages[index],
                                      sheetDate: sheetDate,
                                      onZoomChanged: (zoomed) {
                                        if (zoomed != _isZoomed && mounted) {
                                          setState(() => _isZoomed = zoomed);
                                        }
                                      },
                                    );
                                  },
                                ),
                              ),
                            ),
                            if (!isCompact) const SizedBox(width: 14),
                            if (!isCompact)
                              _NavArrowButton(
                                icon: Icons.chevron_right_rounded,
                                tooltip: 'Next page',
                                enabled: canGoNext,
                                onPressed: _nextPage,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Bottom controls: arrows (on compact) + semi-transparent page dots
                      GestureDetector(
                        onTap: () {},
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isCompact) ...[
                              _NavArrowButton(
                                icon: Icons.chevron_left_rounded,
                                tooltip: 'Previous page',
                                enabled: canGoPrev,
                                compact: true,
                                onPressed: _previousPage,
                              ),
                              const SizedBox(width: 12),
                            ],
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.36),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Wrap(
                                  alignment: WrapAlignment.center,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: List.generate(_pages.length, (i) {
                                    final isActive = i == _currentPage;
                                    return InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: () => _goToPage(i),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        width: isActive ? 22 : 9,
                                        height: 9,
                                        decoration: BoxDecoration(
                                          color: isActive
                                              ? Colors.white.withValues(
                                                  alpha: 0.92,
                                                )
                                              : Colors.white.withValues(
                                                  alpha: 0.38,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            ),
                            if (isCompact) ...[
                              const SizedBox(width: 12),
                              _NavArrowButton(
                                icon: Icons.chevron_right_rounded,
                                tooltip: 'Next page',
                                enabled: canGoNext,
                                compact: true,
                                onPressed: _nextPage,
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (canVoidCurrent || voidedEntries.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        GestureDetector(
                          onTap: () {},
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              if (canVoidCurrent)
                                FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red.shade700,
                                    foregroundColor: Colors.white,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed:
                                      _isMutating ? null : _handleVoidCurrentPage,
                                  icon: _isMutating
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.block, size: 16),
                                  label: Text('Void SI $currentPageSi (Page $currentPageNo)'),
                                ),
                              for (final v in voidedEntries)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.red.shade300.withValues(alpha: 0.7),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.block,
                                        size: 13,
                                        color: Colors.red.shade200,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        'Voided: ${v.siNumber}'
                                        '${v.reason != null && v.reason!.isNotEmpty ? ' (${v.reason})' : ''}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (widget.onUnvoidSiRequested != null) ...[
                                        const SizedBox(width: 6),
                                        InkWell(
                                          onTap: _isMutating
                                              ? null
                                              : () => _handleUnvoidSi(v.siNumber),
                                          borderRadius: BorderRadius.circular(999),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(alpha: 0.18),
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: const Text(
                                              'Un-Void',
                                              style: TextStyle(
                                                color: Colors.amberAccent,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Subtle top-right close button
              Positioned(
                top: 14,
                right: 16,
                child: Tooltip(
                  message: 'Close (Esc)',
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavArrowButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final bool compact;
  final VoidCallback onPressed;

  const _NavArrowButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    this.compact = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: enabled ? 0.48 : 0.2),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: compact ? 40 : 48,
            height: compact ? 40 : 48,
            child: Icon(
              icon,
              size: compact ? 26 : 32,
              color: Colors.white.withValues(alpha: enabled ? 0.95 : 0.32),
            ),
          ),
        ),
      ),
    );
  }
}

