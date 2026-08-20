import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Standardized extraction response from Dual Cloud Extractor
class DualExtractionResult {
  final bool success;
  final String? directUrl;
  final String? title;
  final String? format;
  final int? size;
  final String? providerUsed; // 'Primary (Railway)', 'Secondary (Cobalt)', etc.
  final String? errorMessage;

  const DualExtractionResult({
    required this.success,
    this.directUrl,
    this.title,
    this.format,
    this.size,
    this.providerUsed,
    this.errorMessage,
  });

  factory DualExtractionResult.successful({
    required String directUrl,
    String? title,
    String? format,
    int? size,
    required String providerUsed,
  }) {
    return DualExtractionResult(
      success: true,
      directUrl: directUrl,
      title: title ?? 'HyperPulse_Media',
      format: format ?? 'mp4',
      size: size ?? 0,
      providerUsed: providerUsed,
    );
  }

  factory DualExtractionResult.failed({required String errorMessage}) {
    return DualExtractionResult(
      success: false,
      errorMessage: errorMessage,
    );
  }
}

/// Dual Cloud Extractor with Automatic Failover
/// 1. Primary: Self-hosted Railway yt-dlp backend
/// 2. Secondary: Multi-instance Cobalt API fallback
class DualCloudExtractor {
  /// Default or custom primary Railway backend URL
  static String primaryRailwayUrl = 'https://hyperpulse-api-production.up.railway.app/extract';

  /// Cobalt API instances for secondary fallback
  static final List<String> cobaltInstances = [
    'https://co.wuk.sh/api/json',
    'https://api.cobalt.tools/api/json',
    'https://cobalt-api.kwiatekm.tokyo/api/json',
  ];

  /// Configurable primary timeout in seconds (Default: 8s)
  static const Duration primaryTimeout = Duration(seconds: 8);
  static const Duration secondaryTimeout = Duration(seconds: 8);

  /// Main extraction method with automatic failover
  static Future<DualExtractionResult> extract(String rawUrl) async {
    final cleanUrl = rawUrl.trim();
    if (cleanUrl.isEmpty) {
      return DualExtractionResult.failed(errorMessage: 'رابط الوسائط فارغ');
    }

    debugPrint('[DualCloudExtractor] 🚀 Starting dual extraction for: $cleanUrl');

    // -------------------------------------------------------------
    // Step 1: Attempt Primary Server (Railway yt-dlp Engine)
    // -------------------------------------------------------------
    try {
      debugPrint('[DualCloudExtractor] 📡 Trying Primary Server (Railway): $primaryRailwayUrl');
      final primaryResult = await _tryPrimaryRailway(cleanUrl);
      if (primaryResult != null && primaryResult.success && primaryResult.directUrl != null) {
        debugPrint('[DualCloudExtractor] ✅ Primary Server succeeded!');
        return primaryResult;
      } else {
        debugPrint('[DualCloudExtractor] ⚠️ Primary Server returned unsuccessful response: ${primaryResult?.errorMessage}');
      }
    } catch (e) {
      debugPrint('[DualCloudExtractor] ⚠️ Primary Server failed or timed out ($e). Switching to Secondary...');
    }

    // -------------------------------------------------------------
    // Step 2: Failover to Secondary Server (Cobalt API)
    // -------------------------------------------------------------
    debugPrint('[DualCloudExtractor] 🔄 Failover activated: Trying Secondary Server (Cobalt API)...');
    for (final cobaltEndpoint in cobaltInstances) {
      try {
        final secondaryResult = await _tryCobaltInstance(cleanUrl, cobaltEndpoint);
        if (secondaryResult != null && secondaryResult.success && secondaryResult.directUrl != null) {
          debugPrint('[DualCloudExtractor] ✅ Secondary Server ($cobaltEndpoint) succeeded!');
          return secondaryResult;
        }
      } catch (e) {
        debugPrint('[DualCloudExtractor] ⚠️ Cobalt instance ($cobaltEndpoint) failed: $e');
      }
    }

    // -------------------------------------------------------------
    // Step 3: Both servers failed
    // -------------------------------------------------------------
    debugPrint('[DualCloudExtractor] ❌ All extraction servers failed.');
    return DualExtractionResult.failed(
      errorMessage: 'تعذر الاتصال بأي سيرفر (فشل السيرفر الأساسي والاحتياطي)',
    );
  }

  /// Helper to call Primary Railway Flask Server
  static Future<DualExtractionResult?> _tryPrimaryRailway(String videoUrl) async {
    final uri = Uri.parse(primaryRailwayUrl).replace(queryParameters: {'url': videoUrl});

    final client = http.Client();
    try {
      final response = await client.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'HyperPulse-Rocket-Engine/3.0',
        },
      ).timeout(primaryTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data is Map<String, dynamic> && data['success'] == true) {
          final directUrl = data['direct_url']?.toString();
          if (directUrl != null && directUrl.isNotEmpty) {
            return DualExtractionResult.successful(
              directUrl: directUrl,
              title: data['title']?.toString(),
              format: data['format']?.toString() ?? 'mp4',
              size: (data['size'] is num) ? (data['size'] as num).toInt() : 0,
              providerUsed: 'السيرفر الأساسي (Railway yt-dlp)',
            );
          }
        }
        final err = (data is Map<String, dynamic>) ? data['error'] : 'خطأ غير معروف في الاستجابة';
        return DualExtractionResult.failed(errorMessage: err.toString());
      } else {
        return DualExtractionResult.failed(
          errorMessage: 'كود الاستجابة: ${response.statusCode}',
        );
      }
    } finally {
      client.close();
    }
  }

  /// Helper to call Cobalt API Instances
  static Future<DualExtractionResult?> _tryCobaltInstance(String videoUrl, String endpoint) async {
    final client = http.Client();
    try {
      final response = await client.post(
        Uri.parse(endpoint),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'User-Agent': 'HyperPulse-Rocket-Engine/3.0',
        },
        body: jsonEncode({
          'url': videoUrl,
          'vQuality': 'max',
          'filenameStyle': 'basic',
          'downloadMode': 'auto',
        }),
      ).timeout(secondaryTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data is Map<String, dynamic>) {
          String? directUrl;
          if (data['url'] != null) {
            directUrl = data['url'].toString();
          } else if (data['audio'] != null) {
            directUrl = data['audio'].toString();
          } else if (data['picker'] is List && (data['picker'] as List).isNotEmpty) {
            directUrl = data['picker'][0]['url']?.toString();
          }

          if (directUrl != null && directUrl.isNotEmpty) {
            return DualExtractionResult.successful(
              directUrl: directUrl,
              title: data['filename']?.toString() ?? 'Social_Video',
              format: 'mp4',
              size: 0,
              providerUsed: 'السيرفر الاحتياطي (Cobalt API)',
            );
          }
        }
      }
      return null;
    } finally {
      client.close();
    }
  }
}
