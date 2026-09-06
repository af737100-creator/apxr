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

  static const String _fallbackBadgeBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAPAAAAA0CAYAAAC0LLUwAAABCUlEQVR4nO3dMQqDQBRF'
      'UVeQIlV2le1nBdlGQgpBGNAxxMx/ch6cfprLKBZOk5mZmQXsdZ+ewDEECyciXDiBXfFe'
      'rtcHUEv3zTv6oECr6yYWMNS0GfD8vD36oEBr831YwFCXgCGYgCHYasDLb06jDwq0Vr8L'
      'CxhqEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAE'
      'EzAEEzAEEzAEEzAEEzAEEzAEEzAEEzAEWw148nMzKG01XgFDbQKGYAKGYJsBzxGPPijQ'
      '2oxXwFBXV8CfjT4o0OqKd3kTAzXsilfIUMPX4Qoa/u/nwZqZmdkBewPCHGR8AUVCAAAA'
      'AElFTkSuQmCC';

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
        await badgeFile.writeAsBytes(bytes);
      }
      return badgeFile.path;
    } catch (e) {
      debugPrint('[WatermarkService] Could not write badge PNG: $e');
      return null;
    }
  }

  /// Stamping metadata/watermark filter string for FFmpeg drawtext
  String generateFFmpegFilterCommand({String? customFontFile}) {
    final opacity = _config.opacity.clamp(0.1, 1.0);
    final cleanAppName = _config.appName.replaceAll("'", '').replaceAll(':', ' -');
    
    // Draw text with prominent dark background box, border, and bright white text
    if (customFontFile != null && customFontFile.isNotEmpty) {
      final escapedFont = customFontFile.replaceAll(':', r'\:');
      return "drawtext=fontfile='$escapedFont':text='⚡ $cleanAppName':fontsize=20:fontcolor=white@$opacity:box=1:boxcolor=black@0.65:boxborderw=10:x=w-tw-24:y=h-th-24";
    }
    
    return "drawtext=text='⚡ $cleanAppName':fontsize=20:fontcolor=white@$opacity:box=1:boxcolor=black@0.65:boxborderw=10:x=w-tw-24:y=h-th-24";
  }

  /// Checks if file is a candidate for watermarking
  bool canApplyWatermark(String filePath) {
    final lower = filePath.toLowerCase();
    return _config.isEnabled && (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.mov') || lower.endsWith('.webm'));
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

  /// Applies the brand watermark badge with background box and app name onto the video
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

    final badgePng = await _ensureBadgePng();
    final systemFont = findAndroidSystemFont();
    debugPrint('[WatermarkService] ⚡ Stamping watermark with background & app name for: $videoFilePath');

    // Build ordered list of commands to try
    final commandsToTry = <String>[];

    // Method 1: Overlay badge PNG with background box + drawtext
    if (badgePng != null && File(badgePng).existsSync()) {
      commandsToTry.add(
        '-y -i "$videoFilePath" -i "$badgePng" -filter_complex "[0:v][1:v]overlay=W-w-24:H-h-24,drawtext=text=\'⚡ ${_config.appName}\':fontsize=18:fontcolor=white:x=W-24-w+16:y=H-24-h+14" -c:v libx264 -preset ultrafast -crf 22 -c:a copy "$tempWatermarkedPath"',
      );
      // Simpler overlay without inner drawtext (pure badge)
      commandsToTry.add(
        '-y -i "$videoFilePath" -i "$badgePng" -filter_complex "[0:v][1:v]overlay=W-w-24:H-h-24" -c:v libx264 -preset ultrafast -crf 22 -c:a copy "$tempWatermarkedPath"',
      );
    }

    // Method 2: drawtext with box=1 (black@0.65 background box, 10px border padding, white text)
    if (systemFont != null) {
      final f1 = generateFFmpegFilterCommand(customFontFile: systemFont);
      commandsToTry.add(
        '-y -i "$videoFilePath" -vf "$f1" -c:v libx264 -preset ultrafast -crf 22 -c:a copy "$tempWatermarkedPath"',
      );
    }
    final f2 = generateFFmpegFilterCommand();
    commandsToTry.add(
      '-y -i "$videoFilePath" -vf "$f2" -c:v libx264 -preset ultrafast -crf 22 -c:a copy "$tempWatermarkedPath"',
    );

    // Method 3: drawbox fallback
    commandsToTry.add(
      '-y -i "$videoFilePath" -vf "drawbox=x=w-180:y=h-48:w=160:h=36:color=black@0.65:t=fill" -c:v libx264 -preset ultrafast -crf 22 -c:a copy "$tempWatermarkedPath"',
    );

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
            debugPrint('[WatermarkService] ✅ Watermark successfully stamped on: $videoFilePath');
            return true;
          }
        } else {
          final logs = await session.getLogs();
          final errorSnippet = logs.isNotEmpty ? logs.last.getMessage() : 'Unknown error';
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

    debugPrint('[WatermarkService] Preserved original clean video as safe fallback.');
    return false;
  }
}
