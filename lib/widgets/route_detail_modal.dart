import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
import 'package:compact_sales_monitoring/widgets/web_storage_image.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class RouteDetailModal extends StatelessWidget {
  final SalesRoute route;
  final AppUser salesman;
  final Future<void> Function()? onRouteChanged;

  const RouteDetailModal({
    super.key,
    required this.route,
    required this.salesman,
    this.onRouteChanged,
  });

  String _normalizeImageUrl(String imageUrl) {
    final value = imageUrl.trim();
    if (value.isEmpty) {
      return value;
    }

    if (value.startsWith('gs://')) {
      return value;
    }

    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme) {
      // Web blocks mixed-content images on HTTP pages.
      if (parsed.scheme == 'http') {
        return parsed.replace(scheme: 'https').toString();
      }
      return parsed.toString();
    }

    return Uri.encodeFull(value);
  }

  Future<String?> _resolveImageUrl(String imageUrl) async {
    final normalized = _normalizeImageUrl(imageUrl);
    if (normalized.isEmpty) {
      return null;
    }

    if (normalized.startsWith('gs://')) {
      try {
        return await FirebaseStorage.instance
            .refFromURL(normalized)
            .getDownloadURL();
      } catch (_) {
        return null;
      }
    }

    final parsed = Uri.tryParse(normalized);
    if (parsed != null && parsed.hasScheme) {
      if (parsed.host.contains('firebasestorage.googleapis.com')) {
        final objectPath = _extractStorageObjectPath(parsed);
        if (objectPath != null) {
          try {
            return await FirebaseStorage.instance
                .ref(objectPath)
                .getDownloadURL();
          } catch (_) {
            // If refreshing fails, still try using the original URL.
          }
        }
      }
      return parsed.toString();
    }

    // Fallback for records that store raw object paths like
    // "route_images/<salesman>/<timestamp>.jpg".
    final normalizedPath = normalized.replaceAll('\\', '/').trim();
    final objectPath = normalizedPath.replaceFirst(RegExp(r'^/+'), '');
    if (objectPath.isNotEmpty) {
      try {
        return await FirebaseStorage.instance.ref(objectPath).getDownloadURL();
      } catch (_) {
        return null;
      }
    }

    return normalized;
  }

  String? _extractStorageObjectPath(Uri uri) {
    final segments = uri.pathSegments;
    final objectIndex = segments.indexOf('o');
    if (objectIndex < 0 || objectIndex + 1 >= segments.length) {
      return null;
    }

    final encodedPath = segments[objectIndex + 1];
    if (encodedPath.isEmpty) {
      return null;
    }

    return Uri.decodeComponent(encodedPath);
  }

  Widget _buildImageError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined),
            const SizedBox(height: 8),
            Text(message),
          ],
        ),
      ),
    );
  }

  Widget _buildAdaptiveImage({
    required String imageUrl,
    required BoxFit fit,
    double? width,
    double? height,
  }) {
    if (kIsWeb) {
      return WebStorageImage(
        imageUrl: imageUrl,
        fit: fit,
        width: width,
        height: height,
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: fit,
      width: width,
      height: height,
      placeholder: (context, url) =>
          const Center(child: CircularProgressIndicator()),
      errorWidget: (context, url, error) {
        return _buildImageError('Failed to load image');
      },
    );
  }

  Widget _buildRouteImage(String imageUrl) {
    return FutureBuilder<String?>(
      future: _resolveImageUrl(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: double.infinity,
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final resolvedImageUrl = snapshot.data;
        if (resolvedImageUrl == null || resolvedImageUrl.isEmpty) {
          return const SizedBox(
            width: double.infinity,
            height: 200,
            child: Center(child: Icon(Icons.error_outline)),
          );
        }

        return _buildAdaptiveImage(
          imageUrl: resolvedImageUrl,
          width: double.infinity,
          height: 200,
          fit: BoxFit.cover,
        );
      },
    );
  }

  Future<void> _openGoogleMaps(
    BuildContext context,
    double lat,
    double lon,
  ) async {
    final googleMapsUri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
    );
    final geoUri = Uri.parse('geo:$lat,$lon?q=$lat,$lon(Call Location)');

    try {
      final openedGoogleMaps = await launchUrl(
        googleMapsUri,
        mode: LaunchMode.externalApplication,
      );
      if (openedGoogleMaps) return;

      final openedGeo = await launchUrl(
        geoUri,
        mode: LaunchMode.externalApplication,
      );
      if (openedGeo) return;

      final openedInBrowser = await launchUrl(
        googleMapsUri,
        mode: LaunchMode.platformDefault,
      );
      if (openedInBrowser) return;
    } catch (_) {
      // Fall through to show message below.
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Unable to open map for this location.')),
    );
  }

  void _openFullImagePreview(
    BuildContext context,
    String imageUrl,
    String title,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: FutureBuilder<String?>(
                  future: _resolveImageUrl(imageUrl),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final resolvedImageUrl = snapshot.data;
                    if (resolvedImageUrl == null || resolvedImageUrl.isEmpty) {
                      return _buildImageError('Failed to load image');
                    }

                    return InteractiveViewer(
                      child: _buildAdaptiveImage(
                        imageUrl: resolvedImageUrl,
                        fit: BoxFit.contain,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _approveRetake(
    BuildContext context, {
    required bool isFirst,
  }) async {
    final authProvider = context.read<AuthProvider>();
    final approver = authProvider.currentUser;
    if (approver == null) return;

    await FirestoreService().approveCallRetake(
      routeId: route.routeId,
      isFirst: isFirst,
      approvedBy: approver.uid,
    );

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${isFirst ? 'First' : 'Last'} call retake approved.'),
      ),
    );

    if (onRouteChanged != null) {
      await onRouteChanged!();
    }

    if (!context.mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = context.watch<AuthProvider>().currentUser;
    final canApprove =
        currentUser?.role == UserRole.supervisor ||
        currentUser?.role == UserRole.superuser;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWideWeb = kIsWeb && screenWidth >= 900;
    final dialogWidth = isWideWeb
        ? (screenWidth * 0.35).clamp(460.0, 760.0)
        : (screenWidth - 32).clamp(320.0, 720.0);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: dialogWidth),
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Route Details',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      if (salesman.profilePic != null)
                        CircleAvatar(
                          radius: 30,
                          backgroundImage: CachedNetworkImageProvider(
                            salesman.profilePic!,
                          ),
                        )
                      else
                        const CircleAvatar(
                          radius: 30,
                          child: Icon(Icons.person),
                        ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            salesman.email,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Salesman',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'First Call (Start)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _buildRouteImage(route.first.imageUrl),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      _openFullImagePreview(
                        context,
                        route.first.imageUrl,
                        'First Call Image',
                      );
                    },
                    icon: const Icon(Icons.open_in_full),
                    label: const Text('Open Full Image'),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Location',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            '${route.first.lat.toStringAsFixed(4)}, ${route.first.lon.toStringAsFixed(4)}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        _openGoogleMaps(
                          context,
                          route.first.lat,
                          route.first.lon,
                        );
                      },
                      icon: const Icon(Icons.location_on),
                      label: const Text('Maps'),
                    ),
                  ],
                ),
                if (canApprove &&
                    route.firstRetakeRequested &&
                    !route.firstRetakeApproved)
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      onPressed: () => _approveRetake(context, isFirst: true),
                      icon: const Icon(Icons.check),
                      label: const Text('Approve First Call Retake'),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Time',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          route.first.timestamp.toString().split('.').first,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (route.hasLastCall) ...[
                  const Divider(),
                  const SizedBox(height: 20),
                  Text(
                    'Last Call (End)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _buildRouteImage(route.last.imageUrl),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _openFullImagePreview(
                          context,
                          route.last.imageUrl,
                          'Last Call Image',
                        );
                      },
                      icon: const Icon(Icons.open_in_full),
                      label: const Text('Open Full Image'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Location',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              '${route.last.lat.toStringAsFixed(4)}, ${route.last.lon.toStringAsFixed(4)}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: () {
                          _openGoogleMaps(
                            context,
                            route.last.lat,
                            route.last.lon,
                          );
                        },
                        icon: const Icon(Icons.location_on),
                        label: const Text('Maps'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Time',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            route.last.timestamp.toString().split('.').first,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (canApprove &&
                      route.lastRetakeRequested &&
                      !route.lastRetakeApproved)
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        onPressed: () =>
                            _approveRetake(context, isFirst: false),
                        icon: const Icon(Icons.check),
                        label: const Text('Approve Last Call Retake'),
                      ),
                    ),
                ] else ...[
                  const Divider(),
                  const SizedBox(height: 20),
                  Text(
                    'Last Call (End)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Last call has not been captured yet.',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      'Estimated Distance: ${route.estimatedDistanceKm.toStringAsFixed(2)} km',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (route.distance != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        'Recorded Distance: ${route.distance!.toStringAsFixed(2)} km',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
