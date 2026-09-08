import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

/// Configuration options for video watermark stamp
class WatermarkConfig {
  final bool isEnabled;
  final String appName;
  final String logoIconText;
  final double opacity;
  final String position; // 'bottom-right', 'bottom-left', 'top-right', 'top-left'

  const WatermarkConfig({
    this.isEnabled = true,
    this.appName = 'HyperPulse Turbo',
    this.logoIconText = '⚡',
    this.opacity = 0.85,
    this.position = 'bottom-right',
  });
}

/// [WatermarkService] applies a clean, stylish, semi-transparent
/// copyright watermark badge with a background and the app name to downloaded media videos.
class WatermarkService {
  static final WatermarkService _instance = WatermarkService._internal();
  factory WatermarkService() => _instance;
  WatermarkService._internal();

  WatermarkConfig _config = const WatermarkConfig();
  WatermarkConfig get config => _config;

  // Track files that have already been watermarked to avoid duplicate processing
  final Set<String> _watermarkedFiles = <String>{};
  bool _isProcessing = false;

  // High-resolution (320x64) RGBA PNG badge: Dark translucent pill + Amber ⚡ + Crisp HYPERPULSE lettering
  static const String _fallbackBadgeBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAUAAAABACAYAAABr564eAAADSUlEQVR4nO3cQY4TOxCA'
      '4dwAiSX3X3EDbsCaCwUhwSgzk4R021Uu21+kbzdxtd1+/wLNm8ul8XP9fvkJMEJrv8QO'
      'WEpq+L58/fYLYITQEIodMJsuIRQ+YGanIyh+wAoOR1D8gJW8HEHxA1b0UgTFD1jV0wCK'
      'H7C6hxEUQGB1dwMofsAuPkVQAIFdCCCwLQEEtiWAwLbeBbBi/K4/LtfRzwCs6y2C1QL4'
      'J34CCEQSQGBbJQP4L34CCEQqF8Db+AkgEGmbAF5vPhnrjJzX8jnzXBmzM2ZUmTfT/Wx9'
      'xqizPbpWiQB+jJ8ACuDs+1v9frY+Y9TZHl1reADvxU8ABXD2/a1+P1ufMepsj64lgIHr'
      'HP1OxozWdXrNW31/q8/Lfn/dz6HCvwE+ip8ACuDs+1t9Xvb7634OowP4LH4CKICz72/1'
      'ednvr/s5CGDuOo++H7Vu2MUpeqGr7W/1ednvr/s5jAzg/+L3iuwXEBWqqHXDLk7RC11t'
      'f6vPy35/3c9hVAB7xE8Ax+2v6oWutr/V52W/v+7nMHMAzx5Ir0+lS5G9J/Pi5mXcqV7z'
      'su9q1IzUAGbHr+eFPvMyMi5h9p7Mi5uXcad6zcu+q1Ezhv8e4NuDB8Sv54U+8zIyLmH2'
      'nsyLm5dxp3rNy76rUTOmCWD0xchap/Jas85znnMEsNL+hv8azKcHEsDha806z3kK4OGf'
      'qxTAyN8JFMAxFzFznvMUwMM/N0sAZ7tgM6+1wrzW56u+v9Z1BPDvz80QwBkv2MxrrTBP'
      'AAVwqgDu8r/CzbDWCvMEUACnD+DMF2zmtY7O6/WJ2t+Z72afZ6+zneH9Rc1omSeAA/7D'
      'qLpWxAV75RO1vzPfzT7PXmc7w/uLmtEyr9zfA4y8VBXWqbxWxAV75RO1vzPfzT7PXmc7'
      'w/uLmtEyr1QARzwDsJ8S/wYofsAIwwMofsAoAghsq0wARx8EsJ8SfxJ/9CEAe3oL4J/P'
      'iL8KPfoAgD29i9+IAAKMIoDAtgQQ2JYAAtv6FEARBHZwN34CCOzgYQBFEFjZ0/jdBlAE'
      'gZXctu1hAEUQWM3L8RNBYCWH4yeCwApOx+9eBIUQmMHHbp2K37MQiiJQwbM2NYfvSAgB'
      'KugePlEEKmrt128/E6E32OAjZQAAAABJRU5ErkJggg==';

  void updateConfig({
    bool? isEnabled,
    String? appName,
    double? opacity,
    String? position,
  }) {
    _config = WatermarkConfig(
      isEnabled: isEnabled ?? _config.isEnabled,
      appName: appName ?? _config.appName,
      opacity: opacity ?? _config.opacity,
      position: position ?? _config.position,
    );
  }

  /// Ensures a badge PNG with dark background and border exists in temporary storage
  Future<String?> _ensureBadgePng() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final badgeFile = File(p.join(tempDir.path, 'hyperpulse_watermark_badge.png'));
      if (!await badgeFile.exists() || (await badgeFile.length()) < 50) {
        final bytes = base64Decode(_fallbackBadgeBase64);
        await badgeFile.writeAsBytes(bytes, flush: true);
      }
      return badgeFile.path;
    } catch (e) {
      debugPrint('[WatermarkService] Could not write badge PNG: $e');
      return null;
    }
  }

  /// Checks if file is a candidate for watermarking
  bool canApplyWatermark(String filePath) {
    final lower = filePath.toLowerCase();
    return _config.isEnabled &&
        (lower.endsWith('.mp4') ||
            lower.endsWith('.mkv') ||
            lower.endsWith('.mov') ||
            lower.endsWith('.webm'));
  }

  /// Applies the brand watermark badge onto the downloaded video.
  /// Uses Android MediaCodec hardware acceleration and universal MPEG-4 fallbacks.
  Future<bool> applyWatermarkToVideo(String videoFilePath) async {
    if (!_config.isEnabled || !canApplyWatermark(videoFilePath)) {
      return false;
    }

    if (_watermarkedFiles.contains(videoFilePath)) {
      debugPrint('[WatermarkService] File already watermarked: $videoFilePath');
      return true;
    }

    if (_isProcessing) {
      debugPrint('[WatermarkService] Another watermark operation is already running, skipping concurrent call.');
      return false;
    }

    final originalFile = File(videoFilePath);
    if (!await originalFile.exists()) return false;

    _isProcessing = true;

    final dir = p.dirname(videoFilePath);
    final ext = p.extension(videoFilePath);
    final baseName = p.basenameWithoutExtension(videoFilePath);
    final tempWatermarkedPath = p.join(dir, '${baseName}_wm_temp$ext');

    try {
      final badgePng = await _ensureBadgePng();
      if (badgePng == null || !File(badgePng).existsSync()) {
        debugPrint('[WatermarkService] Badge asset could not be created.');
        return false;
      }

      debugPrint('[WatermarkService] ⚡ Stamping brand watermark badge for: $videoFilePath');

      // Build safe commands list:
      // 1. Android MediaCodec Hardware Acceleration (Fast, zero CPU heat, native GPU chip)
      // 2. Built-in universal MPEG-4 encoder (Universally present in all FFmpeg builds without GPL)
      // 3. Software libx264 ultrafast (if available)
      final commandsToTry = <String>[
        // Attempt 1: Android MediaCodec Hardware Encoder
        '-y -i "$videoFilePath" -i "$badgePng" -filter_complex "[0:v][1:v]overlay=W-w-20:H-h-20" -c:v h264_mediacodec -b:v 2500k -c:a copy "$tempWatermarkedPath"',
        // Attempt 2: Universal MPEG-4 encoder
        '-y -i "$videoFilePath" -i "$badgePng" -filter_complex "[0:v][1:v]overlay=W-w-20:H-h-20" -c:v mpeg4 -q:v 3 -c:a copy "$tempWatermarkedPath"',
        // Attempt 3: libx264 software ultrafast fallback
        '-y -i "$videoFilePath" -i "$badgePng" -filter_complex "[0:v][1:v]overlay=W-w-20:H-h-20" -c:v libx264 -preset ultrafast -crf 23 -c:a copy "$tempWatermarkedPath"',
      ];

      for (int i = 0; i < commandsToTry.length; i++) {
        final cmd = commandsToTry[i];
        try {
          debugPrint('[WatermarkService] 🎬 Attempt ${i + 1}/${commandsToTry.length}');
          final session = await FFmpegKit.execute(cmd);
          final returnCode = await session.getReturnCode();

          if (ReturnCode.isSuccess(returnCode)) {
            final watermarkedFile = File(tempWatermarkedPath);
            if (await watermarkedFile.exists() && (await watermarkedFile.length()) > 1024) {
              // Replace original with watermarked version atomically
              await originalFile.delete();
              await watermarkedFile.rename(videoFilePath);
              _watermarkedFiles.add(videoFilePath);
              debugPrint('[WatermarkService] ✅ Watermark successfully stamped on: $videoFilePath');
              return true;
            }
          } else {
            final logs = await session.getLogs();
            final errorSnippet = logs.isNotEmpty ? logs.last.getMessage() : 'Return code: $returnCode';
            debugPrint('[WatermarkService] Attempt ${i + 1} code: $returnCode, error: $errorSnippet');

            final tempFile = File(tempWatermarkedPath);
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          }
        } catch (e) {
          debugPrint('[WatermarkService] Watermark error attempt ${i + 1}: $e');
          final tempFile = File(tempWatermarkedPath);
          if (await tempFile.exists()) {
            try {
              await tempFile.delete();
            } catch (_) {}
          }
        }
      }

      debugPrint('[WatermarkService] Preserved original clean video safely.');
      return false;
    } finally {
      _isProcessing = false;
      // Clean up any remaining temp file
      final tempFile = File(tempWatermarkedPath);
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }
}

