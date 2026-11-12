import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/background_location_service.dart';

class TroubleshootingScreen extends StatefulWidget {
  const TroubleshootingScreen({super.key});

  @override
  State<TroubleshootingScreen> createState() => _TroubleshootingScreenState();
}

class _TroubleshootingScreenState extends State<TroubleshootingScreen> {
  bool _isRepairing = false;
  int _refreshTick = 0;

  Future<void> _handleRepairAndSync() async {
    if (_isRepairing) return;
    setState(() => _isRepairing = true);
    try {
      final result = await BackgroundLocationService.repairAndSyncAppState();
      if (!mounted) return;
      final online = result['online'] == true;
      final remaining = result['remainingCheckpoints'] as int? ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            online
                ? (remaining == 0
                    ? 'App state repaired & all pending data synced! Login and activation were preserved.'
                    : 'App state repaired. $remaining checkpoint(s) remain queued and will sync automatically.')
                : 'Offline: local tracking state repaired. Pending data was preserved and will upload when online.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      setState(() => _refreshTick++);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Repair failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isRepairing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Troubleshooting'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            elevation: 0,
            color: const Color(0xFF6750A4).withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: const Color(0xFF6750A4).withValues(alpha: 0.25),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.build_circle_outlined, color: Color(0xFF6750A4)),
                      SizedBox(width: 8),
                      Text(
                        'Self-Service App Repair',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF381E72),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'If the app feels stuck from a previous day or your calls/checkpoints have not synced yet, tap below to upload pending data and reset local tracking cache. Your account login and company activation are preserved.',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isRepairing ? null : _handleRepairAndSync,
                      icon: _isRepairing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.sync_rounded),
                      label: Text(
                        _isRepairing
                            ? 'Syncing & Repairing...'
                            : 'Repair & Sync App State',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Keep Route Tracking Active',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Some phone manufacturers aggressively kill background apps to save battery. If your route is drawing a straight line or not tracking properly, please check your battery settings.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),
          const Text(
            'Samsung Devices (Galaxy A9, etc.)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
          const SizedBox(height: 16),
          _buildStep(
            'Step 1: Go to Settings > Apps and find "Sales Agile Monitoring".',
            'assets/images/troubleshooting/step1.jpg',
          ),
          const SizedBox(height: 24),
          _buildStep(
            'Step 2: Tap on "Battery" in the App info screen.',
            'assets/images/troubleshooting/step2.jpg',
          ),
          const SizedBox(height: 24),
          _buildStep(
            'Step 3: Select "Unrestricted" so the app can track your route without interruptions.',
            'assets/images/troubleshooting/step3.jpg',
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          const Text(
            'Other Devices (Xiaomi, Oppo, Vivo)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
          const SizedBox(height: 8),
          const Text(
            'Please look for "Battery Optimization", "App Power Management", or "Auto-start" in your settings and allow "Sales Agile Monitoring" to run without restrictions.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          Text(
            'Diagnostics',
            key: ValueKey(_refreshTick),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
          const SizedBox(height: 8),
          FutureBuilder<int>(
            future: _getCheckpointCount(),
            builder: (context, snapshot) {
              return Text('Total Checkpoints Captured: ${snapshot.data ?? 0}');
            },
          ),
          FutureBuilder<int>(
            future: _getPendingBatchCount(),
            builder: (context, snapshot) {
              return Text('Pending Offline Checkpoints: ${snapshot.data ?? 0}');
            },
          ),
          FutureBuilder<String>(
            future: _getLastFlushTime(),
            builder: (context, snapshot) {
              return Text('Last Batch Upload: ${snapshot.data ?? 'Never'}');
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<int> _getCheckpointCount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt('checkpoint_count') ?? 0;
  }

  Future<int> _getPendingBatchCount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt('batch_pending_count') ?? 0;
  }

  Future<String> _getLastFlushTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString('last_flush_time') ?? 'Never';
  }

  Widget _buildStep(String instruction, String imagePath) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          instruction,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              imagePath,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ],
    );
  }
}
