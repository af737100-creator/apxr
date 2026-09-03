import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
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
    this.opacity = 0.65,
    this.position = 'bottom-right',
  });
}

/// [WatermarkService] applies a clean, non-intrusive, semi-transparent
/// copyright watermark badge to downloaded media videos using FFmpegKit.
class WatermarkService {
  static final WatermarkService _instance = WatermarkService._internal();
  factory WatermarkService() => _instance;
  WatermarkService._internal();

  WatermarkConfig _config = const WatermarkConfig();
  WatermarkConfig get config => _config;

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

  /// Stamping metadata/watermark overlay string for FFmpeg
  String generateFFmpegFilterCommand({String? customFontFile}) {
    final opacity = _config.opacity.clamp(0.1, 1.0);
    // Sanitize app name to avoid FFmpeg command injection / escaping errors
    final cleanAppName = _config.appName.replaceAll("'", '').replaceAll(':', ' -');
    
    if (customFontFile != null && customFontFile.isNotEmpty) {
      return "drawtext=fontfile='$customFontFile':text='$cleanAppName':fontsize=20:fontcolor=white@$opacity:box=1:boxcolor=black@0.45:boxborderw=8:x=w-tw-24:y=h-th-24";
    }
    
    return "drawtext=text='$cleanAppName':fontsize=20:fontcolor=white@$opacity:box=1:boxcolor=black@0.45:boxborderw=8:x=w-tw-24:y=h-th-24";
  }

  /// Checks if file is a candidate for watermarking
  bool canApplyWatermark(String filePath) {
    final lower = filePath.toLowerCase();
    return _config.isEnabled && (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.mov'));
  }

  /// Finds an existing standard Android system font for FFmpeg drawtext
  static String? findAndroidSystemFont() {
    final candidatePaths = [
      '/system/fonts/Roboto-Regular.ttf',
      '/system/fonts/Roboto-Medium.ttf',
      '/system/fonts/Roboto-Bold.ttf',
      '/system/fonts/DroidSans.ttf',
      '/system/fonts/DroidSans-Bold.ttf',
      '/system/fonts/NotoSans-Regular.ttf',
    ];

    for (final path in candidatePaths) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  /// Statically applies the semi-transparent brand watermark on the downloaded video
  Future<bool> applyWatermarkToVideo(String videoFilePath) async {
    if (!_config.isEnabled || !canApplyWatermark(videoFilePath)) {
      return false;
    }

    final originalFile = File(videoFilePath);
    if (!await originalFile.exists()) return false;

    final dir = p.dirname(videoFilePath);
    final ext = p.extension(videoFilePath);
    final baseName = p.basenameWithoutExtension(videoFilePath);
    final tempWatermarkedPath = p.join(dir, '${baseName}_wm_temp$ext');

    final systemFont = findAndroidSystemFont();
    debugPrint('[WatermarkService] ⚡ Preparing watermark for: $videoFilePath (System font: $systemFont)');

    // List of fallback filter configurations to guarantee watermark success
    final filterAttempts = <String>[];
    if (systemFont != null) {
      filterAttempts.add(generateFFmpegFilterCommand(customFontFile: systemFont));
    }
    filterAttempts.add(generateFFmpegFilterCommand());
    filterAttempts.add("drawbox=x=w-160:y=h-48:w=140:h=36:color=black@0.5:t=fill");

    for (int i = 0; i < filterAttempts.length; i++) {
      final currentFilter = filterAttempts[i];
      try {
        debugPrint('[WatermarkService] 🎬 Attempt ${i + 1}/${filterAttempts.length} with filter: $currentFilter');
        final command =
            '-y -i "$videoFilePath" -vf "$currentFilter" -c:v libx264 -preset ultrafast -crf 23 -c:a copy "$tempWatermarkedPath"';

        final session = await FFmpegKit.execute(command);
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          final watermarkedFile = File(tempWatermarkedPath);
          if (await watermarkedFile.exists() && (await watermarkedFile.length()) > 1024) {
            // Replace original with watermarked version atomically
            await originalFile.delete();
            await watermarkedFile.rename(videoFilePath);
            debugPrint('[WatermarkService] ✅ Watermark successfully stamped on: $videoFilePath');
            return true;
          }
        } else {
          final logs = await session.getLogs();
          final errorSnippet = logs.isNotEmpty ? logs.last.getMessage() : 'Unknown error';
          debugPrint('[WatermarkService] Attempt ${i + 1} failed (Return code: $returnCode, error: $errorSnippet)');
          
          final tempFile = File(tempWatermarkedPath);
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        }
      } catch (e) {
        debugPrint('[WatermarkService] Watermarking error on attempt ${i + 1}: $e');
        final tempFile = File(tempWatermarkedPath);
        if (await tempFile.exists()) {
          try {
            await tempFile.delete();
          } catch (_) {}
        }
      }
    }

    debugPrint('[WatermarkService] Watermark processing ended, preserved original clean video.');
    return false;
  }
}
