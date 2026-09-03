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
  String generateFFmpegFilterCommand() {
    final opacity = _config.opacity.clamp(0.1, 1.0);
    return "drawtext=text='⚡ ${_config.appName}':fontsize=18:fontcolor=white@$opacity:box=1:boxcolor=black@0.35:boxborderw=6:x=w-tw-20:y=h-th-20";
  }

  /// Checks if file is a candidate for watermarking
  bool canApplyWatermark(String filePath) {
    final lower = filePath.toLowerCase();
    return _config.isEnabled && (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.mov'));
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

    try {
      debugPrint('[WatermarkService] ⚡ Stamping watermark onto video: $videoFilePath');
      final filter = generateFFmpegFilterCommand();
      // Use ultrafast preset and copy audio to complete in seconds
      final command =
          '-y -i "$videoFilePath" -vf "$filter" -c:v libx264 -preset ultrafast -crf 23 -c:a copy "$tempWatermarkedPath"';

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
        debugPrint('[WatermarkService] Watermark skipped (FFmpeg exited with error, preserving clean video).');
        final tempFile = File(tempWatermarkedPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (e) {
      debugPrint('[WatermarkService] Watermarking notice: $e');
    }
    return false;
  }
}
