import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/providers/version_provider.dart';

class ForceUpdateScreen extends StatefulWidget {
  final String? downloadUrl;

  const ForceUpdateScreen({super.key, this.downloadUrl});

  @override
  State<ForceUpdateScreen> createState() => _ForceUpdateScreenState();
}

class _ForceUpdateScreenState extends State<ForceUpdateScreen> {
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _statusText = 'A new version of the Agile App is available. You must update to continue using the application.';

  Future<void> _downloadAndInstall() async {
    if (widget.downloadUrl == null || widget.downloadUrl!.isEmpty) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _statusText = 'Downloading update...';
    });

    try {
      final dio = Dio();
      final dir = await getTemporaryDirectory();
      final savePath = '${dir.path}/app_update.apk';

      await dio.download(
        widget.downloadUrl!,
        savePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() {
              _downloadProgress = received / total;
            });
          }
        },
      );

      setState(() {
        _statusText = 'Download complete! Launching installer...';
      });

      final result = await OpenFilex.open(savePath);
      
      if (result.type != ResultType.done) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to open installer: ${result.message}')),
          );
          setState(() {
            _isDownloading = false;
            _statusText = 'Failed to install. Please try again.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _statusText = 'Download failed. Please check your connection and try again.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
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
              Consumer<VersionProvider>(
                builder: (context, versionProvider, _) => Text(
                  'Current Version: ${versionProvider.currentVersion ?? "Unknown"} \nLatest Version: ${versionProvider.latestVersion ?? "Unknown"}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Colors.blue, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 32),
              if (_isDownloading)
                Column(
                  children: [
                    LinearProgressIndicator(
                      value: _downloadProgress,
                      minHeight: 12,
                      borderRadius: BorderRadius.circular(6),
                      backgroundColor: Colors.grey[200],
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8F83F0)),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${(_downloadProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                )
              else
                SizedBox(
                  width: 200,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: _downloadAndInstall,
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
