import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'smart_url_filter.dart';

/// [CloudExtractedMedia] holds extracted direct stream information
class CloudExtractedMedia {
  final bool success;
  final String originalUrl;
  final String directStreamUrl;
  final String title;
  final String format;
  final String? quality;
  final String? thumbnailUrl;
  final int? estimatedSizeBytes;
  final bool isDirectFallback;
  final String? errorMessage;

  const CloudExtractedMedia({
    required this.success,
    required this.originalUrl,
    required this.directStreamUrl,
    required this.title,
    required this.format,
    this.quality,
    this.thumbnailUrl,
    this.estimatedSizeBytes,
    this.isDirectFallback = false,
    this.errorMessage,
  });

  factory CloudExtractedMedia.directFallback({
    required String originalUrl,
    required String format,
    String? title,
  }) {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(originalUrl);
    String inferredTitle = title ?? cleanUrl.split('/').last.split('?').first;
    inferredTitle = _sanitizeFilename(inferredTitle, format);

    return CloudExtractedMedia(
      success: true,
      originalUrl: originalUrl,
      directStreamUrl: cleanUrl,
      title: inferredTitle,
      format: format,
      quality: 'Source Direct',
      isDirectFallback: true,
    );
  }

  factory CloudExtractedMedia.failure({
    required String originalUrl,
    required String errorMessage,
  }) {
    return CloudExtractedMedia(
      success: false,
      originalUrl: originalUrl,
      directStreamUrl: '',
      title: 'Failed',
      format: 'unknown',
      errorMessage: errorMessage,
    );
  }

  static String _sanitizeFilename(String rawTitle, String format) {
    var clean = rawTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (clean.isEmpty) {
      clean = 'HyperPulse_Media_${DateTime.now().millisecondsSinceEpoch}';
    }
    final ext = format.toLowerCase().replaceAll('.', '');
    if (!clean.toLowerCase().endsWith('.$ext')) {
      clean = '$clean.$ext';
    }
    return clean;
  }
}

/// [CloudExtractorService] connects to cloud resolver APIs to extract direct video/audio
/// streams from complex dynamic platforms (YouTube, TikTok, Instagram, Twitter/X, Facebook, etc.).
class CloudExtractorService {
  final Dio _dio;

  // Primary and secondary cloud resolution endpoints (Cobalt, Wuk, Invidious proxies)
  final List<String> resolverEndpoints = [
    'https://api.cobalt.tools',
    'https://co.wuk.sh',
    'https://cobalt-api.kwiatekm.tokyo',
  ];

  CloudExtractorService({Dio? customDio})
      : _dio = customDio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 20),
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                  'User-Agent': 'HyperPulse-CloudExtractor/3.0 (Android; Low-Level Engine)',
                },
              ),
            );

  /// Checks if a given URL is a recognized social/video streaming platform
  static bool isSocialVideoPlatform(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('tiktok.com') ||
        lower.contains('instagram.com') ||
        lower.contains('twitter.com') ||
        lower.contains('x.com') ||
        lower.contains('facebook.com') ||
        lower.contains('fb.watch') ||
        lower.contains('vimeo.com') ||
        lower.contains('reddit.com') ||
        lower.contains('dailymotion.com') ||
        lower.contains('pinterest.com') ||
        lower.contains('pin.it');
  }

  /// Extracts the direct MP4 stream at highest quality, ensuring a strictly valid .mp4 filename.
  Future<CloudExtractedMedia> extractDirectMedia(String webpageUrl) async {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(webpageUrl.trim());

    // 1. Direct downloadable file bypass
    if (SmartUrlFilter.isDownloadableFileUrl(cleanUrl) && !isSocialVideoPlatform(cleanUrl)) {
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'mp4';
      return CloudExtractedMedia.directFallback(
        originalUrl: cleanUrl,
        format: ext,
      );
    }

    // 2. Query Cloud Extractors
    for (final baseUrl in resolverEndpoints) {
      try {
        final endpoint = '$baseUrl/api/json';
        debugPrint('[CloudExtractorService] Querying cloud resolver: $endpoint');

        final response = await _dio.post(
          endpoint,
          data: {
            'url': cleanUrl,
            'vQuality': 'max', // 1080p/4K
            'vCodec': 'h264',  // Maximum compatibility with Android MP4 hardware decoder
            'filenamePattern': 'classic',
            'isAudioOnly': false,
          },
        );

        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;

          if (data is Map<String, dynamic>) {
            final status = data['status'];
            final streamUrl = data['url'] ??
                (data['picker'] is List && data['picker'].isNotEmpty ? data['picker'][0]['url'] : null);
            var filename = data['filename']?.toString() ??
                'HyperPulse_Video_${DateTime.now().millisecondsSinceEpoch}.mp4';

            // Sanitize filename to avoid illegal characters on Android
            filename = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
            if (!filename.toLowerCase().endsWith('.mp4')) {
              filename = '$filename.mp4';
            }

            if (status == 'stream' || status == 'success' || streamUrl != null) {
              return CloudExtractedMedia(
                success: true,
                originalUrl: cleanUrl,
                directStreamUrl: streamUrl.toString(),
                title: filename,
                format: 'mp4',
                quality: '1080p (HD)',
                isDirectFallback: false,
              );
            }
          }
        }
      } catch (e) {
        debugPrint('[CloudExtractorService] Endpoint $baseUrl notice: $e');
      }
    }

    // 3. Fallback: Direct stream fallback
    if (SmartUrlFilter.isCleanAndSafe(cleanUrl)) {
      debugPrint('[CloudExtractorService] Activating direct fallback for: $cleanUrl');
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'mp4';
      return CloudExtractedMedia.directFallback(
        originalUrl: cleanUrl,
        format: ext,
      );
    }

    return CloudExtractedMedia.failure(
      originalUrl: cleanUrl,
      errorMessage: 'تعذر استخراج رابط الفيديو المباشر من السيرفر السحابي. يرجى التحقق من الرابط.',
    );
  }
}
