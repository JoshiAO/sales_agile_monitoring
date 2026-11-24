import 'dart:typed_data';

/// Strips ESC/POS control sequences and normalizes full-width characters/line endings.
class EscPosSanitizer {
  /// Sanitizes raw ESC/POS bytes into clean UTF-8/ASCII text preserving line layout.
  static String sanitizeBytes(Uint8List bytes) {
    final buffer = StringBuffer();
    var i = 0;

    while (i < bytes.length) {
      final b = bytes[i];

      // ESC (0x1B) sequences
      if (b == 0x1B && i + 1 < bytes.length) {
        final cmd = bytes[i + 1];
        if (cmd == 0x40) {
          // ESC @ (Initialize printer)
          i += 2;
          continue;
        }
        // 3-byte ESC commands: ESC ! n, ESC a n, ESC E n, ESC M n, ESC - n, ESC 3 n, ESC d n, ESC t n, ESC R n, ESC { n
        if (const {0x21, 0x2D, 0x33, 0x45, 0x47, 0x4D, 0x52, 0x61, 0x64, 0x74, 0x7B}
            .contains(cmd)) {
          i += 3;
          continue;
        }
        // ESC * m nL nH d1..dk (bit image)
        if (cmd == 0x2A && i + 4 < bytes.length) {
          final nL = bytes[i + 3];
          final nH = bytes[i + 4];
          final k = (nH << 8) | nL;
          i += 5 + k;
          continue;
        }
        // ESC $ nL nH / ESC \ nL nH
        if ((cmd == 0x24 || cmd == 0x5C) && i + 3 < bytes.length) {
          i += 4;
          continue;
        }
        i += 2;
        continue;
      }

      // GS (0x1D) sequences
      if (b == 0x1D && i + 1 < bytes.length) {
        final cmd = bytes[i + 1];
        // GS V m [n] (cut paper)
        if (cmd == 0x56) {
          if (i + 2 < bytes.length && (bytes[i + 2] == 65 || bytes[i + 2] == 66)) {
            i += 4;
          } else {
            i += 3;
          }
          continue;
        }
        // GS v 0 m xL xH yL yH d... (raster bit image)
        if (cmd == 0x76 && i + 7 < bytes.length && bytes[i + 2] == 0x30) {
          final xBytes = bytes[i + 4] | (bytes[i + 5] << 8);
          final yDots = bytes[i + 6] | (bytes[i + 7] << 8);
          i += 8 + (xBytes * yDots);
          continue;
        }
        // 3-byte GS commands: GS ! n, GS B n, GS H n, GS L nL nH, GS h n, GS w n
        if (const {0x21, 0x42, 0x48, 0x66, 0x68, 0x77}.contains(cmd)) {
          i += 3;
          continue;
        }
        if (cmd == 0x4C || cmd == 0x57) {
          i += 4;
          continue;
        }
        i += 2;
        continue;
      }

      // DLE (0x10) real-time status commands
      if (b == 0x10 && i + 2 < bytes.length) {
        i += 3;
        continue;
      }

      // Line breaks & tabs
      if (b == 0x0A) {
        buffer.write('\n');
        i++;
        continue;
      }
      if (b == 0x0D) {
        if (i + 1 < bytes.length && bytes[i + 1] == 0x0A) {
          i++;
        }
        buffer.write('\n');
        i++;
        continue;
      }
      if (b == 0x09) {
        buffer.write('  ');
        i++;
        continue;
      }

      // Printable ASCII
      if (b >= 0x20 && b <= 0x7E) {
        buffer.writeCharCode(b);
      } else if (b >= 0xC0) {
        // Basic UTF-8 pass-through via replacement or char
        buffer.writeCharCode(b);
      }
      i++;
    }

    return normalizeText(buffer.toString());
  }

  /// Normalizes line endings, non-breaking spaces, and full-width ASCII characters.
  static String normalizeText(String input) {
    final normalizedEndings = input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u00A0', ' ');

    final out = StringBuffer();
    for (final rune in normalizedEndings.runes) {
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        out.writeCharCode(rune - 0xFEE0);
      } else if (rune == 0x3000) {
        out.write(' ');
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }
}

