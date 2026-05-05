import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;
import 'package:uuid/uuid.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart'
  show Reference, SettableMetadata;
import 'firebase_service.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();

  factory StorageService() {
    return _instance;
  }

  StorageService._internal();

  final FirebaseService _firebaseService = FirebaseService();
  static const uuid = Uuid();

  Future<String> uploadImage({
    required File file,
    required String folder,
    String? filename,
  }) async {
    try {
      final fileName = _sanitizeFileName(filename ?? uuid.v4());
      final ref = _firebaseService.storage.ref('$folder/$fileName');

      await ref.putFile(file);
      final downloadUrl = await _getDownloadUrlWithRetry(ref);

      return downloadUrl;
    } on FirebaseException catch (e) {
      throw Exception('Upload error [${e.code}]: ${e.message}');
    } catch (e) {
      throw Exception('Upload error: $e');
    }
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
