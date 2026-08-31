import 'dart:io';
import 'package:flutter/foundation.dart';

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
/// copyright watermark badge to downloaded media videos.
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

  /// Stamping metadata/watermark overlay string for FFmpeg or native video player overlays
  String generateFFmpegFilterCommand({
    required int videoWidth,
    required int videoHeight,
  }) {
    // Elegant, small, translucent text watermark at bottom-right corner
    final opacityHex = (_config.opacity * 255).round().toRadixString(16).padLeft(2, '0');
    final fontColor = '0xFFFFFF$opacityHex';
    final boxColor = '0x000000${(0.35 * 255).round().toRadixString(16).padLeft(2, '0')}';

    return "drawtext=text='⚡ ${_config.appName}':fontsize=18:fontcolor=$fontColor:box=1:boxcolor=$boxColor:boxborderw=6:x=w-tw-18:y=h-th-18";
  }

  /// Checks if file is a candidate for watermarking
  bool canApplyWatermark(String filePath) {
    final lower = filePath.toLowerCase();
    return _config.isEnabled && (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.mov'));
  }
}
