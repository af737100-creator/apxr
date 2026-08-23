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

    // Check for HTML / Error text: '<!doc', '<html', '<?xml', '<head', '<body', '403 Forbidden', 'Access Denied'
    final String asciiPreview = String.fromCharCodes(header.take(64)).toLowerCase();
    if (asciiPreview.contains('<!doctype') ||
        asciiPreview.contains('<html') ||
        asciiPreview.contains('<script') ||
        asciiPreview.contains('<body') ||
        asciiPreview.contains('{"error"') ||
        asciiPreview.contains('<html>') ||
        asciiPreview.contains('<?xml') ||
        asciiPreview.contains('403 forbidden') ||
        asciiPreview.contains('access denied') ||
        asciiPreview.contains('error 404')) {
      return MagicFileType.htmlOrWebpage;
    }

    // APK / ZIP (PK\x03\x04 or PK\x05\x06 or PK\x07\x08)
    if (header.length >= 4 &&
        header[0] == 0x50 &&
        header[1] == 0x4B &&
        (header[2] == 0x03 || header[2] == 0x05 || header[2] == 0x07)) {
      return MagicFileType.apkOrZip;
    }

    // MP4 Video ('ftyp' or 'moov' or 'mdat' or 'free' or 'skip' or 'wide')
    if (header.length >= 8) {
      final boxType = String.fromCharCodes(header.sublist(4, 8)).toLowerCase();
      if (boxType == 'ftyp' ||
          boxType == 'moov' ||
          boxType == 'mdat' ||
          boxType == 'free' ||
          boxType == 'skip' ||
          boxType == 'wide') {
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

    // MPEG-TS Sync byte (0x47)
    if (header.isNotEmpty && header[0] == 0x47) {
      return MagicFileType.mp4Video;
    }

    // FLV Video
    if (header.length >= 3 && header[0] == 0x46 && header[1] == 0x4C && header[2] == 0x56) {
      return MagicFileType.mp4Video;
    }

    // RIFF (AVI or WAV)
    if (header.length >= 12 &&
        header[0] == 0x52 &&
        header[1] == 0x49 &&
        header[2] == 0x46 &&
        header[3] == 0x46) {
      final riffType = String.fromCharCodes(header.sublist(8, 12)).toLowerCase();
      if (riffType == 'avi ') return MagicFileType.mp4Video;
      if (riffType == 'wave') return MagicFileType.mp3Audio;
    }

    // OggS (Ogg / Opus / Vorbis)
    if (header.length >= 4 &&
        header[0] == 0x4F &&
        header[1] == 0x67 &&
        header[2] == 0x67 &&
        header[3] == 0x53) {
      return MagicFileType.mp3Audio;
    }

    // MP3 (ID3 header: 0x49 0x44 0x33 or Sync word 0xFF 0xFB/F3/F2)
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
