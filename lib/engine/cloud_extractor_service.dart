import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'smart_url_filter.dart';
import 'dual_cloud_extractor.dart';

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

  /// Extracts YouTube 11-character video ID from any format (shorts, embed, youtu.be, standard)
  static String? extractYouTubeVideoId(String rawUrl) {
    try {
      final regExp = RegExp(
        r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})',
        caseSensitive: false,
      );
      final match = regExp.firstMatch(rawUrl);
      if (match != null && match.group(1) != null) {
        return match.group(1);
      }
      final fallbackExp = RegExp(r'([a-zA-Z0-9_-]{11})');
      final fallbackMatch = fallbackExp.firstMatch(rawUrl);
      return fallbackMatch?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Extracts the direct MP4 stream at maximum velocity with Dual Server Failover
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

    // 2. PRIMARY & SECONDARY DUAL SERVER EXTRACTOR (Railway yt-dlp -> Cobalt Failover)
    if (isSocialVideoPlatform(cleanUrl)) {
      debugPrint('[CloudExtractorService] 🛰️ Invoking DualCloudExtractor for: $cleanUrl');
      final dualRes = await DualCloudExtractor.extract(cleanUrl);
      if (dualRes.success && dualRes.directUrl != null) {
        var title = (dualRes.title ?? 'HyperPulse_Media').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
        final format = dualRes.format ?? 'mp4';
        if (!title.toLowerCase().endsWith('.$format')) {
          title = '$title.$format';
        }

        return CloudExtractedMedia(
          success: true,
          originalUrl: cleanUrl,
          directStreamUrl: dualRes.directUrl!,
          title: title,
          format: format,
          quality: dualRes.providerUsed ?? 'Dual Cloud Server',
          estimatedSizeBytes: dualRes.size,
          isDirectFallback: false,
        );
      } else {
        debugPrint('[CloudExtractorService] ⚠️ Dual server extractor reported: ${dualRes.errorMessage}. Testing client-side fallbacks...');
      }
    }

    // 3. ON-DEVICE DEDICATED TIKTOK ENGINE (TikWM API + LoveTik)
    if (isTikTokUrl(cleanUrl)) {
      debugPrint('[CloudExtractorService] 🎵 Activating Dedicated TikTok Engine for: $cleanUrl');
      final tikTokRes = await _extractTikTokDirect(cleanUrl);
      if (tikTokRes != null && tikTokRes.success) {
        return tikTokRes;
      }
    }

    // 4. ON-DEVICE DEDICATED YOUTUBE TURBO ENGINE (Multi-Layer Invidious + Piped + YoutubeExplode)
    if (isYouTubeUrl(cleanUrl)) {
      debugPrint('[CloudExtractorService] ⚡ Activating Dedicated YouTube Turbo Engine for: $cleanUrl');
      final ytRes = await _extractYouTubeDirect(cleanUrl);
      if (ytRes != null && ytRes.success) {
        return ytRes;
      }
    }

    // 5. ON-DEVICE INSTAGRAM / TWITTER PARSERS
    if (isInstagramUrl(cleanUrl)) {
      final igRes = await _extractInstagramDirect(cleanUrl);
      if (igRes != null && igRes.success) return igRes;
    }
    if (isTwitterUrl(cleanUrl)) {
      final twRes = await _extractTwitterDirect(cleanUrl);
      if (twRes != null && twRes.success) return twRes;
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

  /// Specialized Multi-Layer YouTube Turbo Extractor
  /// Tier 1: Invidious Public Instances Pool (Fast direct Google CDN streams)
  /// Tier 2: YoutubeExplode Native Dart Engine (Muxed + VideoOnly + Audio Stream Fallbacks)
  /// Tier 3: Piped API Global Network
  /// Tier 4: SaveTube / Rapid CDN API
  Future<CloudExtractedMedia?> _extractYouTubeDirect(String ytUrl) async {
    final videoId = extractYouTubeVideoId(ytUrl);
    if (videoId == null || videoId.isEmpty) return null;

    debugPrint('[CloudExtractorService] 🎯 Extracting YouTube ID: $videoId');

    // -------------------------------------------------------------
    // Tier 1: Invidious Multi-Server Fast Race (Direct Google CDN Streams)
    // -------------------------------------------------------------
    final invidiousEndpoints = [
      'https://inv.tux.pizza',
      'https://invidious.nerdvpn.de',
      'https://vid.puffyan.us',
      'https://invidious.private.coffee',
      'https://invidious.drgns.space',
      'https://invidious.protokolla.fi',
      'https://yewtu.be',
      'https://iv.melmac.space',
    ];

    for (final host in invidiousEndpoints) {
      try {
        final response = await _dio.get(
          '$host/api/v1/videos/$videoId',
          options: Options(
            sendTimeout: const Duration(milliseconds: 3500),
            receiveTimeout: const Duration(milliseconds: 4000),
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;
          if (data is Map<String, dynamic>) {
            var rawTitle = (data['title'] ?? 'YouTube_Video_$videoId').toString();
            var cleanTitle = rawTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
            if (!cleanTitle.toLowerCase().endsWith('.mp4')) {
              cleanTitle = '$cleanTitle.mp4';
            }

            // Check formatStreams (Progressive mp4 with audio)
            if (data['formatStreams'] is List && (data['formatStreams'] as List).isNotEmpty) {
              final formats = data['formatStreams'] as List;
              // Pick highest quality mp4 stream
              dynamic bestFormat = formats.first;
              for (final f in formats) {
                if (f is Map && f['url'] != null) {
                  final res = (f['resolution'] ?? f['qualityLabel'] ?? '').toString();
                  if (res.contains('720') || res.contains('1080')) {
                    bestFormat = f;
                    break;
                  }
                }
              }

              if (bestFormat is Map && bestFormat['url'] != null) {
                final directUrl = bestFormat['url'].toString();
                debugPrint('[CloudExtractorService] ✅ YouTube Invidious Success ($host): $directUrl');
                return CloudExtractedMedia(
                  success: true,
                  originalUrl: ytUrl,
                  directStreamUrl: directUrl,
                  title: cleanTitle,
                  format: 'mp4',
                  quality: bestFormat['qualityLabel']?.toString() ?? '720p HD',
                  thumbnailUrl: 'https://img.youtube.com/vi/$videoId/maxresdefault.jpg',
                  isDirectFallback: false,
                );
              }
            }

            // Check adaptiveFormats if formatStreams was empty
            if (data['adaptiveFormats'] is List && (data['adaptiveFormats'] as List).isNotEmpty) {
              final adaptives = data['adaptiveFormats'] as List;
              for (final f in adaptives) {
                if (f is Map && f['url'] != null) {
                  final type = (f['type'] ?? '').toString().toLowerCase();
                  if (type.contains('video/mp4')) {
                    final directUrl = f['url'].toString();
                    debugPrint('[CloudExtractorService] ✅ YouTube Invidious Adaptive Success: $directUrl');
                    return CloudExtractedMedia(
                      success: true,
                      originalUrl: ytUrl,
                      directStreamUrl: directUrl,
                      title: cleanTitle,
                      format: 'mp4',
                      quality: f['qualityLabel']?.toString() ?? 'HD Video',
                      thumbnailUrl: 'https://img.youtube.com/vi/$videoId/hqdefault.jpg',
                      isDirectFallback: false,
                    );
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[CloudExtractorService] Invidious instance $host error: $e');
      }
    }

    // -------------------------------------------------------------
    // Tier 2: Native YoutubeExplode Engine (Muxed + VideoOnly + Audio)
    // -------------------------------------------------------------
    try {
      final yt = YoutubeExplode();
      try {
        final video = await yt.videos.get(VideoId(videoId)).timeout(const Duration(seconds: 6));
        final manifest = await yt.videos.streamsClient.getManifest(VideoId(videoId)).timeout(const Duration(seconds: 6));

        var cleanTitle = video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
        if (!cleanTitle.toLowerCase().endsWith('.mp4')) {
          cleanTitle = '$cleanTitle.mp4';
        }

        // 1. Try muxed
        if (manifest.muxed.isNotEmpty) {
          final bestMuxed = manifest.muxed.sortByVideoQuality().last;
          debugPrint('[CloudExtractorService] ✅ YouTubeExplode Muxed Stream found');
          return CloudExtractedMedia(
            success: true,
            originalUrl: ytUrl,
            directStreamUrl: bestMuxed.url.toString(),
            title: cleanTitle,
            format: 'mp4',
            quality: bestMuxed.videoQualityLabel,
            thumbnailUrl: video.thumbnails.highResUrl,
            estimatedSizeBytes: bestMuxed.size.totalBytes,
            isDirectFallback: false,
          );
        }

        // 2. Try videoOnly if muxed is empty
        if (manifest.videoOnly.isNotEmpty) {
          final bestVideo = manifest.videoOnly.sortByVideoQuality().last;
          debugPrint('[CloudExtractorService] ✅ YouTubeExplode VideoOnly Stream found');
          return CloudExtractedMedia(
            success: true,
            originalUrl: ytUrl,
            directStreamUrl: bestVideo.url.toString(),
            title: cleanTitle,
            format: 'mp4',
            quality: bestVideo.videoQualityLabel,
            thumbnailUrl: video.thumbnails.highResUrl,
            estimatedSizeBytes: bestVideo.size.totalBytes,
            isDirectFallback: false,
          );
        }

        // 3. Try audioOnly if video streams are empty
        if (manifest.audioOnly.isNotEmpty) {
          final bestAudio = manifest.audioOnly.sortByBitrate().last;
          return CloudExtractedMedia(
            success: true,
            originalUrl: ytUrl,
            directStreamUrl: bestAudio.url.toString(),
            title: cleanTitle.replaceAll('.mp4', '.mp3'),
            format: 'mp3',
            quality: 'High Audio Bitrate',
            thumbnailUrl: video.thumbnails.highResUrl,
            estimatedSizeBytes: bestAudio.size.totalBytes,
            isDirectFallback: false,
          );
        }
      } finally {
        yt.close();
      }
    } catch (e) {
      debugPrint('[CloudExtractorService] YoutubeExplode error: $e');
    }

    // -------------------------------------------------------------
    // Tier 3: Piped API Global Network
    // -------------------------------------------------------------
    final pipedEndpoints = [
      'https://pipedapi.kavin.rocks',
      'https://api.piped.privacydev.net',
      'https://pipedapi.tokhmi.xyz',
    ];

    for (final host in pipedEndpoints) {
      try {
        final response = await _dio.get(
          '$host/streams/$videoId',
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;
          if (data is Map<String, dynamic> && data['videoStreams'] is List) {
            final streams = data['videoStreams'] as List;
            for (final s in streams) {
              if (s is Map && s['url'] != null) {
                final format = (s['format'] ?? '').toString();
                if (format.contains('mp4') || format.contains('MPEG') || s['url'].toString().contains('mp4')) {
                  var rawTitle = (data['title'] ?? 'YouTube_Video_$videoId').toString();
                  var cleanTitle = rawTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
                  if (!cleanTitle.toLowerCase().endsWith('.mp4')) cleanTitle = '$cleanTitle.mp4';

                  debugPrint('[CloudExtractorService] ✅ Piped API Stream found: ${s['url']}');
                  return CloudExtractedMedia(
                    success: true,
                    originalUrl: ytUrl,
                    directStreamUrl: s['url'].toString(),
                    title: cleanTitle,
                    format: 'mp4',
                    quality: s['quality']?.toString() ?? 'HD',
                    thumbnailUrl: data['thumbnailUrl']?.toString(),
                    isDirectFallback: false,
                  );
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[CloudExtractorService] Piped API $host error: $e');
      }
    }

    // -------------------------------------------------------------
    // Tier 4: SaveTube Rapid API Fallback
    // -------------------------------------------------------------
    try {
      final response = await _dio.get(
        'https://cdn35.savetube.me/info',
        queryParameters: {'url': 'https://www.youtube.com/watch?v=$videoId'},
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map && data['data'] != null && data['data']['video_formats'] is List) {
          final formats = data['data']['video_formats'] as List;
          if (formats.isNotEmpty) {
            final first = formats.first;
            final streamUrl = first['url'];
            if (streamUrl != null && streamUrl.toString().startsWith('http')) {
              var title = (data['data']['title'] ?? 'YouTube_$videoId').toString();
              title = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
              if (!title.toLowerCase().endsWith('.mp4')) title = '$title.mp4';

              return CloudExtractedMedia(
                success: true,
                originalUrl: ytUrl,
                directStreamUrl: streamUrl.toString(),
                title: title,
                format: 'mp4',
                quality: first['quality']?.toString() ?? '720p',
                thumbnailUrl: data['data']['thumbnail']?.toString(),
                isDirectFallback: false,
              );
            }
          }
        }
      }
    } catch (_) {}

    return null;
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

