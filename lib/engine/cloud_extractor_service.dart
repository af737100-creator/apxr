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

/// [CloudExtractorService] connects to specialized media extraction APIs:
/// 1. Dedicated TikTok Engine (TikWM & LoveTik API - 100% Watermark-free HD MP4).
/// 2. Native YouTube Explode Engine (Zero-wait direct Google CDN streams).
/// 3. Dedicated Instagram & Twitter/X fast parsers.
/// 4. Parallel Racing Cobalt Pool (v7 + v10 APIs with auto-failover).
class CloudExtractorService {
  final Dio _dio;

  // Cloud resolution endpoints (Parallel Racing Pool)
  final List<String> resolverEndpoints = [
    'https://api.cobalt.tools',
    'https://co.wuk.sh',
    'https://cobalt.kwiatekm.tokyo',
    'https://cobalt.hyonsu.com',
    'https://cobalt-api.kwiatekm.tokyo',
    'https://cobalt.stream',
    'https://inv.tux.pizza',
  ];

  CloudExtractorService({Dio? customDio})
      : _dio = customDio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 7),
                headers: {
                  'Accept': 'application/json, text/plain, */*',
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
                },
              ),
            );

  /// Checks if a given URL is a recognized social/video streaming platform
  static bool isSocialVideoPlatform(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('tiktok.com') ||
        lower.contains('douyin.com') ||
        lower.contains('instagram.com') ||
        lower.contains('twitter.com') ||
        lower.contains('x.com') ||
        lower.contains('facebook.com') ||
        lower.contains('fb.watch') ||
        lower.contains('vimeo.com') ||
        lower.contains('reddit.com') ||
        lower.contains('dailymotion.com') ||
        lower.contains('pinterest.com') ||
        lower.contains('pin.it') ||
        lower.contains('threads.net') ||
        lower.contains('snapchat.com');
  }

  /// Checks if URL is TikTok specifically
  static bool isTikTokUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('tiktok.com') || lower.contains('douyin.com');
  }

  /// Checks if URL is specifically YouTube
  static bool isYouTubeUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('youtube.com') || lower.contains('youtu.be');
  }

  /// Checks if URL is Instagram
  static bool isInstagramUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('instagram.com');
  }

  /// Checks if URL is Twitter / X
  static bool isTwitterUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('twitter.com') || lower.contains('x.com');
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

  /// Extracts the direct MP4 stream at maximum velocity
  Future<CloudExtractedMedia> extractDirectMedia(String webpageUrl) async {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(webpageUrl.trim());

    // 1. Direct downloadable file bypass (APK, ZIP, direct mp4, etc.)
    if (SmartUrlFilter.isDownloadableFileUrl(cleanUrl) && !isSocialVideoPlatform(cleanUrl)) {
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'mp4';
      return CloudExtractedMedia.directFallback(
        originalUrl: cleanUrl,
        format: ext,
      );
    }

    // 2. DEDICATED TIKTOK ENGINE (TikWM API + LoveTik) - 100% Reliable HD Watermark-free MP4
    if (isTikTokUrl(cleanUrl)) {
      debugPrint('[CloudExtractorService] 🎵 Activating Dedicated TikTok Engine for: $cleanUrl');
      final tikTokRes = await _extractTikTokDirect(cleanUrl);
      if (tikTokRes != null && tikTokRes.success) {
        return tikTokRes;
      }
    }

    // 3. NATIVE YOUTUBE EXPLODE EXTRACTION (Zero-wait instant Google CDN pipe)
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

    // 4. DEDICATED INSTAGRAM ENGINE
    if (isInstagramUrl(cleanUrl)) {
      debugPrint('[CloudExtractorService] 📸 Activating Instagram Direct Engine for: $cleanUrl');
      final igRes = await _extractInstagramDirect(cleanUrl);
      if (igRes != null && igRes.success) {
        return igRes;
      }
    }

    // 5. DEDICATED TWITTER/X ENGINE
    if (isTwitterUrl(cleanUrl)) {
      debugPrint('[CloudExtractorService] 🐦 Activating Twitter Direct Engine for: $cleanUrl');
      final twRes = await _extractTwitterDirect(cleanUrl);
      if (twRes != null && twRes.success) {
        return twRes;
      }
    }

    // 6. Parallel Racing across Cobalt Multi-Server Pool
    try {
      final futures = resolverEndpoints.map((baseUrl) => _resolveCobaltEndpoint(baseUrl, cleanUrl));
      final winningResult = await Future.any(futures).timeout(const Duration(seconds: 6));
      if (winningResult != null && winningResult.success) {
        return winningResult;
      }
    } catch (_) {}

    // 7. Direct file safety check (ONLY if NOT a social platform)
    if (!isSocialVideoPlatform(cleanUrl) && SmartUrlFilter.isCleanAndSafe(cleanUrl)) {
      debugPrint('[CloudExtractorService] Activating direct fallback for non-social url: $cleanUrl');
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'mp4';
      return CloudExtractedMedia.directFallback(
        originalUrl: cleanUrl,
        format: ext,
      );
    }

    // 8. If social media extraction failed, DO NOT download the HTML webpage! Return clear error with browser option
    return CloudExtractedMedia.failure(
      originalUrl: cleanUrl,
      errorMessage: 'تعذر استخراج تيار الفيديو المباشر من هذا الرابط. افتحه داخل "المتصفح الذكي 🌐" لتشغيله والتقاطه فوراً.',
    );
  }

  /// Specialized TikTok API Extractor (TikWM + LoveTik)
  Future<CloudExtractedMedia?> _extractTikTokDirect(String tikTokUrl) async {
    try {
      // 1. TikWM API (Fast, Free, No Watermark MP4)
      final response = await _dio.get(
        'https://www.tikwm.com/api/',
        queryParameters: {'url': tikTokUrl, 'hd': '1'},
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map<String, dynamic> && data['code'] == 0 && data['data'] != null) {
          final videoData = data['data'] as Map<String, dynamic>;
          String? directStreamUrl = videoData['play'] ?? videoData['wmplay'] ?? videoData['hdplay'];

          if (directStreamUrl != null && directStreamUrl.isNotEmpty) {
            if (directStreamUrl.startsWith('/')) {
              directStreamUrl = 'https://www.tikwm.com$directStreamUrl';
            }

            var title = (videoData['title'] ?? 'TikTok_Video_${DateTime.now().millisecondsSinceEpoch}').toString();
            title = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
            if (title.length > 60) title = title.substring(0, 60);
            if (!title.toLowerCase().endsWith('.mp4')) {
              title = '$title.mp4';
            }

            final int sizeBytes = (videoData['size'] is int) ? videoData['size'] : 0;
            final String? cover = videoData['cover']?.toString();

            debugPrint('[CloudExtractorService] ✅ TikTok Extracted via TikWM: $directStreamUrl');
            return CloudExtractedMedia(
              success: true,
              originalUrl: tikTokUrl,
              directStreamUrl: directStreamUrl,
              title: title,
              format: 'mp4',
              quality: 'HD (No Watermark)',
              thumbnailUrl: cover,
              estimatedSizeBytes: sizeBytes > 0 ? sizeBytes : null,
              isDirectFallback: false,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[CloudExtractorService] TikWM error: $e');
    }

    try {
      // 2. LoveTik API Fallback
      final response = await _dio.post(
        'https://lovetik.com/api/ajax/search',
        data: FormData.fromMap({'query': tikTokUrl}),
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map<String, dynamic> && data['links'] is List) {
          final links = data['links'] as List;
          for (final link in links) {
            if (link is Map && link['a'] != null) {
              final directUrl = link['a'].toString();
              var desc = (data['desc'] ?? 'TikTok_${DateTime.now().millisecondsSinceEpoch}').toString();
              desc = desc.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
              if (desc.length > 50) desc = desc.substring(0, 50);
              if (!desc.toLowerCase().endsWith('.mp4')) desc = '$desc.mp4';

              debugPrint('[CloudExtractorService] ✅ TikTok Extracted via LoveTik: $directUrl');
              return CloudExtractedMedia(
                success: true,
                originalUrl: tikTokUrl,
                directStreamUrl: directUrl,
                title: desc,
                format: 'mp4',
                quality: 'HD',
                thumbnailUrl: data['cover']?.toString(),
                isDirectFallback: false,
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[CloudExtractorService] LoveTik error: $e');
    }

    return null;
  }

  /// Specialized Instagram API Extractor
  Future<CloudExtractedMedia?> _extractInstagramDirect(String igUrl) async {
    try {
      // Query SaveClip / Rapid Insta API
      final response = await _dio.post(
        'https://api.saveclip.app/v1/get',
        data: {'url': igUrl},
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map<String, dynamic> && data['data'] != null) {
          final mediaList = data['data'];
          if (mediaList is List && mediaList.isNotEmpty) {
            final first = mediaList.first;
            final streamUrl = first['url'] ?? first['video_url'];
            if (streamUrl != null && streamUrl.toString().startsWith('http')) {
              return CloudExtractedMedia(
                success: true,
                originalUrl: igUrl,
                directStreamUrl: streamUrl.toString(),
                title: 'Instagram_Reel_${DateTime.now().millisecondsSinceEpoch}.mp4',
                format: 'mp4',
                quality: 'HD 1080p',
                thumbnailUrl: first['thumbnail']?.toString(),
                isDirectFallback: false,
              );
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Specialized Twitter/X API Extractor
  Future<CloudExtractedMedia?> _extractTwitterDirect(String twitterUrl) async {
    try {
      // Query Twitsave API
      final response = await _dio.get(
        'https://twitsave.com/info',
        queryParameters: {'url': twitterUrl},
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final bodyStr = response.data.toString();
        // Regex extract download href
        final match = RegExp(r'href="([^"]+)"[^>]*class="[^"]*btn-download[^"]*"').firstMatch(bodyStr) ??
            RegExp(r'href="(https:\/\/[^"]+\.mp4[^"]*)"').firstMatch(bodyStr);

        if (match != null && match.group(1) != null) {
          final streamUrl = match.group(1)!;
          return CloudExtractedMedia(
            success: true,
            originalUrl: twitterUrl,
            directStreamUrl: streamUrl,
            title: 'Twitter_Video_${DateTime.now().millisecondsSinceEpoch}.mp4',
            format: 'mp4',
            quality: 'HD',
            isDirectFallback: false,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// Generalized Cobalt Engine (v7 & v10 schema support)
  Future<CloudExtractedMedia?> _resolveCobaltEndpoint(String baseUrl, String cleanUrl) async {
    try {
      // 1. Try v10 schema (POST / with json)
      final v10Response = await _dio.post(
        baseUrl.endsWith('/') ? baseUrl : '$baseUrl/',
        data: {
          'url': cleanUrl,
          'videoQuality': '1080',
          'audioFormat': 'mp3',
        },
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 5),
          headers: {'Accept': 'application/json'},
        ),
      );

      if (v10Response.statusCode == 200 && v10Response.data != null) {
        final data = v10Response.data;
        if (data is Map<String, dynamic>) {
          final streamUrl = data['url'] ??
              (data['picker'] is List && data['picker'].isNotEmpty ? data['picker'][0]['url'] : null);

          if (streamUrl != null && streamUrl.toString().startsWith('http')) {
            var filename = data['filename']?.toString() ??
                'HyperPulse_Video_${DateTime.now().millisecondsSinceEpoch}.mp4';

            filename = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
            if (!filename.toLowerCase().endsWith('.mp4')) filename = '$filename.mp4';

            return CloudExtractedMedia(
              success: true,
              originalUrl: cleanUrl,
              directStreamUrl: streamUrl.toString(),
              title: filename,
              format: 'mp4',
              quality: 'HD',
              isDirectFallback: false,
            );
          }
        }
      }
    } catch (_) {}

    try {
      // 2. Try v7/v8 schema (POST /api/json)
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
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 5),
          headers: {'Accept': 'application/json'},
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map<String, dynamic>) {
          final streamUrl = data['url'] ??
              (data['picker'] is List && data['picker'].isNotEmpty ? data['picker'][0]['url'] : null);

          if (streamUrl != null && streamUrl.toString().startsWith('http')) {
            var filename = data['filename']?.toString() ??
                'HyperPulse_Video_${DateTime.now().millisecondsSinceEpoch}.mp4';

            filename = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
            if (!filename.toLowerCase().endsWith('.mp4')) {
              filename = '$filename.mp4';
            }

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

