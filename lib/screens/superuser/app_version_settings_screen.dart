import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';

class AppVersionSettingsScreen extends StatefulWidget {
  const AppVersionSettingsScreen({super.key});

  @override
  State<AppVersionSettingsScreen> createState() => _AppVersionSettingsScreenState();
}

class _AppVersionSettingsScreenState extends State<AppVersionSettingsScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final TextEditingController _versionController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await _firestoreService.getAppConfig();
      if (config != null) {
        _versionController.text = (config['latest_version'] as String?) ?? '';
        _urlController.text = (config['download_url'] as String?) ?? '';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load config: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _saveConfig() async {
    final version = _versionController.text.trim();
    final url = _urlController.text.trim();

    if (version.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill out both fields.')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      await _firestoreService.updateAppConfig(version, url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('App configuration updated successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save config: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    _versionController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App Version Settings')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Automated OTA Updates',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'When you release a new version of the Agile App, update the fields below. Salesmen with an older version will be forced to download the new update upon opening the app.',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _versionController,
                      decoration: const InputDecoration(
                        labelText: 'Latest App Version',
                        hintText: 'e.g., 1.2.0',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.info_outline),
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'APK Download URL',
                        hintText: 'e.g., https://github.com/.../app-release.apk',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.link),
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton(
                        onPressed: _isSaving ? null : _saveConfig,
                        child: _isSaving
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Text('Save Configuration'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
