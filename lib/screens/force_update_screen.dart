import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class ForceUpdateScreen extends StatelessWidget {
  final String? downloadUrl;

  const ForceUpdateScreen({super.key, this.downloadUrl});

  Future<void> _launchUrl(BuildContext context) async {
    if (downloadUrl == null || downloadUrl!.isEmpty) return;
    
    try {
      if (await canLaunchUrlString(downloadUrl!)) {
        await launchUrlString(downloadUrl!, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open the download link.')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening link: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.system_update, size: 80, color: Color(0xFF8F83F0)),
              const SizedBox(height: 24),
              const Text(
                'Update Required',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'A new version of the Agile App is available. You must update to continue using the application.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: 200,
                height: 50,
                child: FilledButton.icon(
                  onPressed: () => _launchUrl(context),
                  icon: const Icon(Icons.download),
                  label: const Text('Download Update'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
