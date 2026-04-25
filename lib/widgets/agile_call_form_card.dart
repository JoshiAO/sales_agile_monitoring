import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/models/agile_model.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class AgileCallFormCard extends StatefulWidget {
  const AgileCallFormCard({super.key});

  @override
  State<AgileCallFormCard> createState() => _AgileCallFormCardState();
}

class _AgileCallFormCardState extends State<AgileCallFormCard> {
  final FirestoreService _firestoreService = FirestoreService();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  static const int _minCounterValue = 0;
  static const int _maxCounterValue = 100;

  int _totalCalls = 0;
  int _productiveCalls = 0;
  final TextEditingController _sttController = TextEditingController();
  late final String _date;

  bool _isLastCallCompleted = false;
  bool _isSubmitted = false;
  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _date = DateFormat('yyyy-MM-dd').format(DateTime.now());
    _loadAgileState();
  }

  @override
  void dispose() {
    _sttController.dispose();
    super.dispose();
  }

  Future<void> _loadAgileState() async {
    final currentUser = context.read<AuthProvider>().currentUser;
    if (currentUser == null) {
      setState(() {
        _isLoading = false;
        _loadError = 'Unable to identify logged-in salesman.';
      });
      return;
    }

    try {
      final results = await Future.wait([
        _firestoreService.getRoutesBySalesman(currentUser.uid, _date),
        _firestoreService.getAgileSubmissionForSalesmanByDate(
          salesmanId: currentUser.uid,
          date: _date,
        ),
      ]);

      final routes = results[0] as List<SalesRoute>;
      final submission = results[1] as AgileSubmission?;

      final lastCallCompleted = routes.any((route) => route.hasLastCall == true);

      if (!mounted) return;
      setState(() {
        _isLastCallCompleted = lastCallCompleted;

        if (submission != null) {
          _totalCalls = submission.totalCalls;
          _productiveCalls = submission.productiveCalls;
          _sttController.text = submission.sttActual.toStringAsFixed(2);
          _isSubmitted = submission.submitted;
        }

        _loadError = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = '$error';
      });
    }
  }

  void _incrementCounter(ValueSetter<int> setter, int currentValue) {
    if (currentValue >= _maxCounterValue) return;
    setState(() => setter(currentValue + 1));
  }

  void _decrementCounter(ValueSetter<int> setter, int currentValue) {
    if (currentValue <= _minCounterValue) return;
    setState(() => setter(currentValue - 1));
  }

  bool get _isSubmitEnabled {
    return _isLastCallCompleted && !_isSubmitted && !_isSubmitting;
  }

  Future<void> _showMessageDialog({
    required String title,
    required String message,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _showSubmissionConfirmation() async {
    final stt = double.tryParse(_sttController.text.trim()) ?? 0.0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Agile Submission'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total Calls: $_totalCalls'),
            Text('Productive Calls: $_productiveCalls'),
            Text('STT for today: ${stt.toStringAsFixed(2)}'),
            const SizedBox(height: 12),
            const Text(
              'No revisions can be made after submission.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Confirm Submit'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  Future<void> _submit() async {
    if (!_isLastCallCompleted) {
      await _showMessageDialog(
        title: 'Last Call Required',
        message: 'Please complete the Calls (Last Call) before submission.',
      );
      return;
    }

    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      await _showMessageDialog(
        title: 'Incomplete Inputs',
        message: 'Please complete all input fields correctly before submitting.',
      );
      return;
    }

      // Require Total Calls and Productive Calls to be > 0
      if (_totalCalls <= 0) {
        await _showMessageDialog(
          title: 'Total Calls Required',
          message: 'Total Calls must be greater than zero.',
        );
        return;
      }
      if (_productiveCalls <= 0) {
        await _showMessageDialog(
          title: 'Productive Calls Required',
          message: 'Productive Calls must be greater than zero.',
        );
        return;
      }

    final currentUser = context.read<AuthProvider>().currentUser;
    if (currentUser == null) {
      await _showMessageDialog(
        title: 'Authentication Required',
        message: 'Unable to identify logged-in salesman.',
      );
      return;
    }

    final supervisorId = currentUser.supervisorId;
    if (supervisorId == null || supervisorId.isEmpty) {
      await _showMessageDialog(
        title: 'Supervisor Missing',
        message: 'Salesman has no assigned supervisor. Submission cannot continue.',
      );
      return;
    }

    final confirmed = await _showSubmissionConfirmation();
    if (!confirmed) return;

    setState(() => _isSubmitting = true);
    try {
      final sttValue = double.parse(_sttController.text.trim());
      await _firestoreService.submitAgileSubmission(
        supervisorId: supervisorId,
        salesmanId: currentUser.uid,
        date: _date,
        totalCalls: _totalCalls,
        productiveCalls: _productiveCalls,
        sttActual: sttValue,
        lastCallCompleted: _isLastCallCompleted,
      );

      if (!mounted) return;

      setState(() {
        _isSubmitted = true;
      });

      await _showMessageDialog(
        title: 'Submission Complete',
        message: 'Agile data has been submitted successfully.',
      );
    } catch (error) {
      if (!mounted) return;
      await _showMessageDialog(
        title: 'Submission Failed',
        message: '$error',
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Unable to load salesman agile data.',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _loadError!,
                style: TextStyle(color: Colors.grey.shade700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _loadError = null;
                  });
                  _loadAgileState();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final sttFieldWidth = width >= 900 ? 320.0 : (width >= 600 ? 280.0 : 240.0);
    final readOnly = _isSubmitted;

    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _CounterField(
                                    label: 'Total Calls',
                                    hint: '0 to 100',
                                    value: _totalCalls,
                                    isReadOnly: readOnly,
                                    onDecrement: () => _decrementCounter(
                                      (value) => _totalCalls = value,
                                      _totalCalls,
                                    ),
                                    onIncrement: () => _incrementCounter(
                                      (value) => _totalCalls = value,
                                      _totalCalls,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _CounterField(
                                    label: 'Productive Calls',
                                    hint: '0 to 100',
                                    value: _productiveCalls,
                                    isReadOnly: readOnly,
                                    onDecrement: () => _decrementCounter(
                                      (value) => _productiveCalls = value,
                                      _productiveCalls,
                                    ),
                                    onIncrement: () => _incrementCounter(
                                      (value) => _productiveCalls = value,
                                      _productiveCalls,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: sttFieldWidth),
                                child: TextFormField(
                                  controller: _sttController,
                                  readOnly: readOnly,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  textAlign: TextAlign.center,
                                  onEditingComplete: () {
                                    FocusScope.of(context).unfocus();
                                  },
                                  decoration: const InputDecoration(
                                    labelText: 'STT for today',
                                    hintText: 'e.g. 12.50',
                                    border: OutlineInputBorder(),
                                  ),
                                  validator: (value) {
                                    final text = (value ?? '').trim();
                                    if (text.isEmpty) {
                                      return 'STT for today is required';
                                    }
                                    if (double.tryParse(text) == null) {
                                      return 'Please enter a valid number';
                                    }
                                    if (_productiveCalls > _totalCalls) {
                                      return 'Productive Calls cannot exceed Total Calls';
                                    }
                                    return null;
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _isLastCallCompleted
                                        ? 'Last Call status: Completed/Uploaded'
                                        : 'Last Call status: Pending',
                                    style: TextStyle(
                                      color: _isLastCallCompleted
                                          ? Colors.green.shade700
                                          : Colors.orange.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Refresh last call status',
                                  onPressed: _isSubmitting ? null : _loadAgileState,
                                  icon: const Icon(Icons.refresh),
                                ),
                              ],
                            ),
                            if (_isSubmitted)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text(
                                  'Submission finalized. Editing is disabled.',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: constraints.maxHeight * 0.1),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: constraints.maxWidth * 0.1,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.45,
                            minWidth: 140,
                          ),
                          child: FilledButton(
                            onPressed: _isSubmitEnabled ? _submit : null,
                            child: _isSubmitting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('Submit'),
                          ),
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
  }
}

class _CounterField extends StatelessWidget {
  final String label;
  final String hint;
  final int value;
  final bool isReadOnly;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  const _CounterField({
    required this.label,
    required this.hint,
    required this.value,
    required this.isReadOnly,
    required this.onDecrement,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          hint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey.shade600,
              ),
        ),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: 'Decrease $label',
                onPressed: isReadOnly ? null : onDecrement,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text(
                '$value',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              IconButton(
                tooltip: 'Increase $label',
                onPressed: isReadOnly ? null : onIncrement,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

