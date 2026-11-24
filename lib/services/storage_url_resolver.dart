import 'package:firebase_storage/firebase_storage.dart';

/// Shared helper to normalize and resolve Firebase Storage URLs (`gs://`, HTTPS
/// download URLs, or raw storage object paths) across Web and Mobile.
class StorageUrlResolver {
  const StorageUrlResolver._();

  static String? normalizeUrl(String? rawValue) {
    final value = rawValue?.trim() ?? '';
    if (value.isEmpty) return null;
    if (value.startsWith('gs://')) return value;

    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme) {
      // Web blocks mixed-content images on HTTPS pages.
      if (parsed.scheme == 'http') {
        return parsed.replace(scheme: 'https').toString();
      }
      return parsed.toString();
    }

    return Uri.encodeFull(value);
  }

  static String? extractStorageObjectPath(Uri uri) {
    final segments = uri.pathSegments;
    final objectIndex = segments.indexOf('o');
    if (objectIndex < 0 || objectIndex + 1 >= segments.length) {
      return null;
    }

    final encodedPath = segments[objectIndex + 1];
    if (encodedPath.isEmpty) return null;
    return Uri.decodeComponent(encodedPath);
  }

  static Future<String?> resolveUrl(String? rawValue) async {
    final normalized = normalizeUrl(rawValue);
    if (normalized == null || normalized.isEmpty) return null;

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
        final objectPath = extractStorageObjectPath(parsed);
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

    // Fallback for records storing raw object paths like "route_images/.../ts.jpg".
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
}

