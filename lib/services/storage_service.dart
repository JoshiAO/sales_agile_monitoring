import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;
import 'package:uuid/uuid.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart'
  show Reference, SettableMetadata;
import 'package:compact_sales_monitoring/services/firebase_service.dart' as app_firebase;

class StorageService {
  static final StorageService _instance = StorageService._internal();

  factory StorageService() {
    return _instance;
  }

  StorageService._internal();

  final app_firebase.FirebaseService _firebaseService = app_firebase.FirebaseService();
  static const uuid = Uuid();

  Future<String> uploadImage({
    required File file,
    required String folder,
    String? filename,
    Duration timeout = const Duration(seconds: 25),
    int maxAttempts = 2,
  }) async {
    final fileName = _sanitizeFileName(filename ?? uuid.v4());
    final ref = _firebaseService.storage.ref('$folder/$fileName');

    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final uploadTask = ref.putFile(file);
      try {
        await uploadTask.timeout(
          timeout,
          onTimeout: () {
            uploadTask.cancel().catchError((_) => false);
            throw TimeoutException('Storage upload timed out after ${timeout.inSeconds}s');
          },
        );
        final downloadUrl = await _getDownloadUrlWithRetry(ref).timeout(
          const Duration(seconds: 10),
        );
        return downloadUrl;
      } on FirebaseException catch (e) {
        lastError = Exception('Upload error [${e.code}]: ${e.message}');
      } catch (e) {
        lastError = Exception('Upload error: $e');
      }

      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
      }
    }

    throw lastError ?? Exception('Upload failed after $maxAttempts attempts');
  }

  Future<String> uploadImageBytes({
    required Uint8List bytes,
    required String folder,
    String? filename,
    String? contentType,
  }) async {
    try {
      final fileName = _sanitizeFileName(filename ?? uuid.v4());
      final ref = _firebaseService.storage.ref('$folder/$fileName');

      await ref.putData(
        bytes,
        contentType == null
            ? null
            : SettableMetadata(contentType: contentType),
      );
      final downloadUrl = await _getDownloadUrlWithRetry(ref);

      return downloadUrl;
    } on FirebaseException catch (e) {
      throw Exception('Upload error [${e.code}]: ${e.message}');
    } catch (e) {
      throw Exception('Upload error: $e');
    }
  }

  Future<String> uploadProfilePic(File file, String userId) async {
    return uploadImage(
      file: file,
      folder: 'profile_pictures',
      filename: '$userId.jpg',
    );
  }

  Future<String> uploadRouteImage(File file, String salesmanId, String timestamp) async {
    final safeTimestamp = timestamp.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return uploadImage(
      file: file,
      folder: 'route_images/$salesmanId',
      filename: '$safeTimestamp.jpg',
    );
  }

  Future<void> deleteImage(String imageUrl) async {
    try {
      final ref = _firebaseService.storage.refFromURL(imageUrl);
      await ref.delete();
    } catch (e) {
      developer.log('Delete error: $e', name: 'StorageService');
    }
  }

  String _sanitizeFileName(String value) {
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  }

  Future<String> _getDownloadUrlWithRetry(Reference ref) async {
    const maxAttempts = 3;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await ref.getDownloadURL();
      } on FirebaseException catch (e) {
        final isRetriable = e.code == 'object-not-found' && attempt < maxAttempts;
        if (!isRetriable) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }

    throw Exception('Unable to retrieve download URL after retries');
  }
}
