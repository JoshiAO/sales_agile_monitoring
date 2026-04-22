import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:compact_sales_monitoring/models/route_model.dart';
import 'package:compact_sales_monitoring/models/user_model.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/services/firestore_service.dart';
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
      const SnackBar(
        content: Text('Unable to open map for this location.'),
      ),
    );
  }

  void _openFullImagePreview(BuildContext context, String imageUrl, String title) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                child: InteractiveViewer(
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.contain,
                    placeholder: (context, url) =>
                        const Center(child: CircularProgressIndicator()),
                    errorWidget: (context, url, error) => const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('Failed to load image'),
                      ),
                    ),
                  ),
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
    final canApprove = currentUser?.role == UserRole.supervisor ||
        currentUser?.role == UserRole.superuser;

    return Dialog(
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
                        backgroundImage:
                            CachedNetworkImageProvider(salesman.profilePic!),
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
                child: CachedNetworkImage(
                  imageUrl: route.first.imageUrl,
                  width: double.infinity,
                  height: 200,
                  fit: BoxFit.cover,
                  placeholder: (context, url) =>
                      const CircularProgressIndicator(),
                  errorWidget: (context, url, error) =>
                      const Icon(Icons.error),
                ),
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
                      _openGoogleMaps(context, route.first.lat, route.first.lon);
                    },
                    icon: const Icon(Icons.location_on),
                    label: const Text('Maps'),
                  ),
                ],
              ),
              if (canApprove && route.firstRetakeRequested && !route.firstRetakeApproved)
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
                  child: CachedNetworkImage(
                    imageUrl: route.last.imageUrl,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        const CircularProgressIndicator(),
                    errorWidget: (context, url, error) =>
                        const Icon(Icons.error),
                  ),
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
                        _openGoogleMaps(context, route.last.lat, route.last.lon);
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
                if (canApprove && route.lastRetakeRequested && !route.lastRetakeApproved)
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      onPressed: () => _approveRetake(context, isFirst: false),
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
    );
  }
}
