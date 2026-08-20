import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// Supported file categories for magic bytes validation
enum MagicFileType {
  apkOrZip,
  mp4Video,
  mkvVideo,
  mp3Audio,
  pngImage,
  jpegImage,
  pdfDocument,
  htmlOrWebpage,
  unknown,
}

/// Result of Zero-Byte & Magic Bytes Inspection
class FileIntegrityResult {
  final bool isValid;
  final int totalBytes;
  final MagicFileType detectedType;
  final String? rejectionReason;
  final Uint8List? headerBytes;

  const FileIntegrityResult({
    required this.isValid,
    required this.totalBytes,
    required this.detectedType,
    this.rejectionReason,
    this.headerBytes,
  });

  bool get isFakeWebpage => detectedType == MagicFileType.htmlOrWebpage;
  bool get isZeroByte => totalBytes == 0;
}

/// [ZeroByteShieldEngine] inspects binary header signatures (Magic Numbers)
/// to detect and eliminate 0-byte corruptions, fake HTML error pages, and deceptive redirects.
class ZeroByteShieldEngine {
  /// Minimum file size threshold (e.g. 512 bytes) below which files are suspicious
  static const int minValidFileSize = 512;

  /// Inspects file on disk and verifies its magic bytes signature
  static Future<FileIntegrityResult> inspectFile({
    required String filePath,
    String? expectedExtension,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return const FileIntegrityResult(
        isValid: false,
        totalBytes: 0,
        detectedType: MagicFileType.unknown,
        rejectionReason: 'الملف غير موجود على القرص (File does not exist).',
      );
    }

    final int size = await file.length();

    // 1. Zero-byte check
    if (size == 0) {
      return const FileIntegrityResult(
        isValid: false,
        totalBytes: 0,
        detectedType: MagicFileType.unknown,
        rejectionReason: 'حجم الملف 0 بايت (Zero-byte file detected).',
      );
    }

    // 2. Read first 32 bytes for Magic Number inspection
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final int bytesToRead = size < 64 ? size : 64;
      final Uint8List header = await raf.read(bytesToRead);

      final detectedType = detectTypeFromBytes(header);

      // 3. Reject HTML/Text error pages posing as binaries
      if (detectedType == MagicFileType.htmlOrWebpage) {
        return FileIntegrityResult(
          isValid: false,
          totalBytes: size,
          detectedType: MagicFileType.htmlOrWebpage,
          headerBytes: header,
          rejectionReason:
              'تم استلام صفحة ويب HTML تالفة بدلاً من الملف الحقيقي (صفحة إعلانات أو خطأ 403/404).',
        );
      }

      // 4. Validate against expected file extension if provided
      if (expectedExtension != null && expectedExtension.isNotEmpty) {
        final ext = expectedExtension.toLowerCase().replaceAll('.', '');

        if (ext == 'apk' || ext == 'zip' || ext == 'xapk' || ext == 'jar') {
          if (detectedType != MagicFileType.apkOrZip && detectedType != MagicFileType.unknown) {
            return FileIntegrityResult(
              isValid: false,
              totalBytes: size,
              detectedType: detectedType,
              headerBytes: header,
              rejectionReason: 'توقيع الملف لا يطابق حزمة APK صالحة (Corrupted APK signature).',
            );
          }
        } else if (ext == 'mp4' || ext == 'm4v') {
          if (detectedType != MagicFileType.mp4Video && detectedType != MagicFileType.unknown) {
            return FileIntegrityResult(
              isValid: false,
              totalBytes: size,
              detectedType: detectedType,
              headerBytes: header,
              rejectionReason: 'توقيع الملف لا يطابق تيار MP4 صالح.',
            );
          }
        }
      }

      return FileIntegrityResult(
        isValid: true,
        totalBytes: size,
        detectedType: detectedType,
        headerBytes: header,
      );
    } catch (e) {
      return FileIntegrityResult(
        isValid: false,
        totalBytes: size,
        detectedType: MagicFileType.unknown,
        rejectionReason: 'خطأ أثناء فحص البايتات: $e',
      );
    } finally {
      await raf?.close();
    }
  }

  /// Evaluates header bytes and returns matching [MagicFileType]
  static MagicFileType detectTypeFromBytes(Uint8List header) {
    if (header.isEmpty) return MagicFileType.unknown;

    // Check for HTML: '<!doc', '<html', '<?xml', '<head', '<body'
    final String asciiPreview = String.fromCharCodes(header.take(32)).toLowerCase();
    if (asciiPreview.contains('<!doctype') ||
        asciiPreview.contains('<html') ||
        asciiPreview.contains('<script') ||
        asciiPreview.contains('<body') ||
        asciiPreview.contains('{"error"') ||
        asciiPreview.contains('<html>') ||
        asciiPreview.contains('<?xml')) {
      return MagicFileType.htmlOrWebpage;
    }

    // APK / ZIP (PK\x03\x04 or PK\x05\x06 or PK\x07\x08)
    if (header.length >= 4 &&
        header[0] == 0x50 &&
        header[1] == 0x4B &&
        (header[2] == 0x03 || header[2] == 0x05 || header[2] == 0x07)) {
      return MagicFileType.apkOrZip;
    }

    // MP4 Video ('ftyp' at offset 4 to 8)
    if (header.length >= 12) {
      if (header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 && header[7] == 0x70) {
        return MagicFileType.mp4Video;
      }
    }

    // MKV / WebM Video (\x1A\x45\xDF\xA3)
    if (header.length >= 4 &&
        header[0] == 0x1A &&
        header[1] == 0x45 &&
        header[2] == 0xDF &&
        header[3] == 0xA3) {
      return MagicFileType.mkvVideo;
    }

    // MP3 (ID3 header: 0x49 0x44 0x33 or Sync word 0xFF 0xFB)
    if (header.length >= 3 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
      return MagicFileType.mp3Audio;
    }
    if (header.length >= 2 && header[0] == 0xFF && (header[1] & 0xE0) == 0xE0) {
      return MagicFileType.mp3Audio;
    }

    // PDF (%PDF)
    if (header.length >= 4 &&
        header[0] == 0x25 &&
        header[1] == 0x50 &&
        header[2] == 0x44 &&
        header[3] == 0x46) {
      return MagicFileType.pdfDocument;
    }

    // PNG (\x89PNG\r\n\x1a\n)
    if (header.length >= 4 &&
        header[0] == 0x89 &&
        header[1] == 0x50 &&
        header[2] == 0x4E &&
        header[3] == 0x47) {
      return MagicFileType.pngImage;
    }

    // JPEG (\xFF\xD8\xFF)
    if (header.length >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF) {
      return MagicFileType.jpegImage;
    }

    return MagicFileType.unknown;
  }
}
