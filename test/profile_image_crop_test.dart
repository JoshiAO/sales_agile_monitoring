import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:compact_sales_monitoring/widgets/profile_image_crop_dialog.dart';

void main() {
  test('cropAndCompressProfileImage produces square 512x512 JPEG <= 150KB', () {
    // Create a large 1600x900 synthetic source image.
    final source = img.Image(width: 1600, height: 900);
    for (int y = 0; y < source.height; y += 4) {
      for (int x = 0; x < source.width; x += 4) {
        source.setPixelRgb(x, y, (x * 255) ~/ 1600, (y * 255) ~/ 900, 128);
      }
    }
    final pngBytes = Uint8List.fromList(img.encodePng(source));

    final result = cropAndCompressProfileImage(
      sourceBytes: pngBytes,
      cropXFraction: 0.2,
      cropYFraction: 0.0,
      cropWidthFraction: 0.5625,
      cropHeightFraction: 1.0,
    );

    expect(result.width, 512);
    expect(result.height, 512);
    expect(result.bytes.length, lessThanOrEqualTo(150 * 1024));

    final decodedOutput = img.decodeJpg(result.bytes);
    expect(decodedOutput, isNotNull);
    expect(decodedOutput!.width, 512);
    expect(decodedOutput.height, 512);
  });
}

