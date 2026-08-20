import 'package:flutter/material.dart';

class TroubleshootingScreen extends StatelessWidget {
  const TroubleshootingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Troubleshooting'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
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
        ],
      ),
    );
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
