import 'package:flutter/material.dart';

class DateSelectorWidget extends StatefulWidget {
  final DateTime initialDate;
  final Function(DateTime) onDateChanged;

  const DateSelectorWidget({
    super.key,
    required this.initialDate,
    required this.onDateChanged,
  });

  @override
  State<DateSelectorWidget> createState() => _DateSelectorWidgetState();
}

class _DateSelectorWidgetState extends State<DateSelectorWidget> {
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
  }

  Future<void> _selectDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );

    if (pickedDate != null && pickedDate != _selectedDate) {
      setState(() => _selectedDate = pickedDate);
      widget.onDateChanged(_selectedDate);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Date: ${_selectedDate.toString().split(' ')[0]}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          IconButton(
            onPressed: _selectDate,
            icon: const Icon(Icons.calendar_today, size: 20),
          ),
        ],
      ),
    );
  }
}
