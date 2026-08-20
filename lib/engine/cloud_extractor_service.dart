import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
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
    inferredTitle = sanitizeFilename(inferredTitle, format);

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

  static String sanitizeFilename(String rawTitle, String format) {
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

/// [CloudExtractorService] connects to cloud resolver APIs & native YouTube engines
/// with parallel racing resolvers (Fastest server wins with sub-second response).
class CloudExtractorService {
  final Dio _dio;

  // Cloud resolution endpoints (Parallel Racing Pool)
  final List<String> resolverEndpoints = [
    'https://api.cobalt.tools',
    'https://co.wuk.sh',
    'https://cobalt-api.kwiatekm.tokyo',
    'https://api.piped.video',
    'https://inv.tux.pizza',
  ];

  CloudExtractorService({Dio? customDio})
      : _dio = customDio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 5),
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                  'User-Agent': 'Mozilla/5.0 (Linux; Android 14) HyperPulse/3.5',
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

  /// Checks if URL is specifically YouTube
  static bool isYouTubeUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('youtube.com') || lower.contains('youtu.be');
  }

  /// Extracts YouTube 11-character video ID from any format
  static String? extractYouTubeVideoId(String rawUrl) {
    try {
      final regExp = RegExp(
        r'(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?\/\s]{11})',
        caseSensitive: false,
      );
      final match = regExp.firstMatch(rawUrl);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Extracts the direct MP4 stream at maximum velocity with 0-wait Instant YouTube Engine
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

    // 2. NATIVE YOUTUBE EXPLODE EXTRACTION (Zero-wait instant Google CDN pipe)
    if (isYouTubeUrl(cleanUrl)) {
      final videoIdStr = extractYouTubeVideoId(cleanUrl);
      if (videoIdStr != null && videoIdStr.isNotEmpty) {
        try {
          debugPrint('[CloudExtractorService] ⚡ Zero-Wait YouTube Native Extraction for ID: $videoIdStr');
          final yt = YoutubeExplode();
          try {
            final video = await yt.videos.get(VideoId(videoIdStr)).timeout(
                  const Duration(seconds: 4),
                );
            final manifest = await yt.videos.streamsClient.getManifest(VideoId(videoIdStr)).timeout(
                  const Duration(seconds: 4),
                );

            final muxedStreams = manifest.muxed.sortByVideoQuality();
            if (muxedStreams.isNotEmpty) {
              final bestMuxed = muxedStreams.last;
              var title = video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
              if (!title.toLowerCase().endsWith('.mp4')) {
                title = '$title.mp4';
              }

              debugPrint('[CloudExtractorService] ⚡ Instant YouTube Direct Stream Ready: ${bestMuxed.videoQualityLabel}');
              return CloudExtractedMedia(
                success: true,
                originalUrl: cleanUrl,
                directStreamUrl: bestMuxed.url.toString(),
                title: title,
                format: 'mp4',
                quality: bestMuxed.videoQualityLabel,
                thumbnailUrl: video.thumbnails.highResUrl,
                estimatedSizeBytes: bestMuxed.size.totalBytes,
                isDirectFallback: false,
              );
            }

            final videoStreams = manifest.videoOnly.sortByVideoQuality();
            if (videoStreams.isNotEmpty) {
              final bestVideo = videoStreams.last;
              var title = video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
              if (!title.toLowerCase().endsWith('.mp4')) {
                title = '$title.mp4';
              }

              return CloudExtractedMedia(
                success: true,
                originalUrl: cleanUrl,
                directStreamUrl: bestVideo.url.toString(),
                title: title,
                format: 'mp4',
                quality: bestVideo.videoQualityLabel,
                thumbnailUrl: video.thumbnails.highResUrl,
                estimatedSizeBytes: bestVideo.size.totalBytes,
                isDirectFallback: false,
              );
            }
          } finally {
            yt.close();
          }
        } catch (e) {
          debugPrint('[CloudExtractorService] YoutubeExplode fast notice: $e (racing fallback)');
        }
      }
    }

    // 3. Parallel Racing across Cloud Resolver Pool (Fastest response wins immediately)
    try {
      final futures = resolverEndpoints.map((baseUrl) => _resolveSingleEndpoint(baseUrl, cleanUrl));
      final winningResult = await Future.any(futures).timeout(const Duration(seconds: 5));
      if (winningResult != null && winningResult.success) {
        return winningResult;
      }
    } catch (_) {}

    // 4. Fallback: Direct stream fallback
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
      errorMessage: 'تعذر استخراج رابط الفيديو المباشر تلقائياً. يمكنك فتحه وتحميله عبر المتصفح المدمج.',
    );
  }

  Future<CloudExtractedMedia?> _resolveSingleEndpoint(String baseUrl, String cleanUrl) async {
    try {
      final endpoint = '$baseUrl/api/json';
      final response = await _dio.post(
        endpoint,
        data: {
          'url': cleanUrl,
          'vQuality': 'max',
          'vCodec': 'h264',
          'filenamePattern': 'classic',
          'isAudioOnly': false,
        },
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map<String, dynamic>) {
          final status = data['status'];
          final streamUrl = data['url'] ??
              (data['picker'] is List && data['picker'].isNotEmpty ? data['picker'][0]['url'] : null);
          var filename = data['filename']?.toString() ??
              'HyperPulse_Video_${DateTime.now().millisecondsSinceEpoch}.mp4';

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
    } catch (_) {}
    return null;
  }
}
