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
    final inferredTitle = title ?? cleanUrl.split('/').last.split('?').first;
    return CloudExtractedMedia(
      success: true,
      originalUrl: originalUrl,
      directStreamUrl: cleanUrl,
      title: inferredTitle.isNotEmpty ? inferredTitle : 'HyperPulse_Download.$format',
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
}

/// [CloudExtractorService] connects to cloud resolver APIs to extract direct video/audio
/// streams from complex dynamic platforms (YouTube, TikTok, Instagram, Twitter/X, etc.).
class CloudExtractorService {
  final Dio _dio;

  // Primary and secondary cloud resolution endpoints (Cobalt, Invidious, yt-dlp proxies)
  final List<String> resolverEndpoints = [
    'https://api.cobalt.tools/api/json',
    'https://co.wuk.sh/api/json',
    'https://api.invidious.io/api/v1/videos',
  ];

  CloudExtractorService({Dio? customDio})
      : _dio = customDio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                  'User-Agent': 'HyperPulse-CloudExtractor/2.0 (Android; Low-Level Engine)',
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
        lower.contains('dailymotion.com');
  }

  /// Extracts the direct MP4 stream at the highest available quality with automatic fallback.
  Future<CloudExtractedMedia> extractDirectMedia(String webpageUrl) async {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(webpageUrl.trim());

    // 1. If the URL is already a direct file or not a social media link, bypass cloud extraction
    if (SmartUrlFilter.isDownloadableFileUrl(cleanUrl) && !isSocialVideoPlatform(cleanUrl)) {
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'mp4';
      return CloudExtractedMedia.directFallback(
        originalUrl: cleanUrl,
        format: ext,
      );
    }

    // 2. Query Cloud Extractors
    for (final endpoint in resolverEndpoints) {
      try {
        debugPrint('[CloudExtractorService] Querying cloud resolver: $endpoint');

        final response = await _dio.post(
          endpoint,
          data: {
            'url': cleanUrl,
            'vQuality': 'max', // Highest available video quality (1080p/4K)
            'vCodec': 'h264',  // Maximum compatibility with Android MP4 players
            'filenamePattern': 'classic',
            'isAudioOnly': false,
          },
        );

        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;

          // Check Cobalt-style response schema
          if (data is Map<String, dynamic>) {
            final status = data['status'];
            final streamUrl = data['url'] ?? (data['picker'] is List && data['picker'].isNotEmpty ? data['picker'][0]['url'] : null);
            final filename = data['filename'] ?? 'HyperPulse_Video_${DateTime.now().millisecondsSinceEpoch}.mp4';

            if (status == 'stream' || status == 'success' || streamUrl != null) {
              return CloudExtractedMedia(
                success: true,
                originalUrl: cleanUrl,
                directStreamUrl: streamUrl.toString(),
                title: filename.toString(),
                format: 'mp4',
                quality: '1080p (Max)',
                isDirectFallback: false,
              );
            }
          }
        }
      } catch (e) {
        debugPrint('[CloudExtractorService] Endpoint $endpoint failed: $e');
        // Continue to next backup resolver endpoint
      }
    }

    // 3. Fallback: If cloud resolvers are down, check if the direct URL can still be fetched
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
      errorMessage: 'تعذر استخراج رابط الفيديو المباشر من الخادم، يرجى التأكد من الرابط.',
    );
  }
}
