import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'smart_url_filter.dart';
import 'headless_media_sniffer.dart';

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
  final String? serverUsed;

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
    this.serverUsed,
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
      clean = 'PulseSphere_Media_${DateTime.now().millisecondsSinceEpoch}';
    }
    final ext = format.toLowerCase().replaceAll('.', '');
    if (!clean.toLowerCase().endsWith('.$ext')) {
      clean = '$clean.$ext';
    }
    return clean;
  }
}

/// [CloudExtractorService] handles multi-server failover extraction:
/// 1. Primary (Priority 1): Wispbyte Server (http://78.154.103.45:9864/extract?url=)
/// 2. Backup 2: https://api.cobalt.tools/api/json
/// 3. Backup 3: https://co.wuk.sh/api/json
/// 4. Backup 4: https://cobalt.stream/api/json
class CloudExtractorService {
  final Dio _dio;
  final String primaryWispbyteUrl;

  // Server List Configuration
  static const String defaultWispbyteEndpoint = 'http://78.154.103.45:9864/extract?url=';
  static const List<String> cobaltBackupServers = [
    'https://api.cobalt.tools/api/json',
    'https://co.wuk.sh/api/json',
    'https://cobalt.stream/api/json',
  ];

  CloudExtractorService({
    Dio? customDio,
    String? wispbyteServerUrl,
  })  : primaryWispbyteUrl = wispbyteServerUrl ?? defaultWispbyteEndpoint,
        _dio = customDio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10),
                headers: {
                  'Accept': 'application/json, text/plain, */*',
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                },
              ),
            );

  /// Candidate backend server endpoints for local and cloud environments
  List<String> get _candidateServerEndpoints {
    final list = <String>[];

    // 1. Primary Live Cloud Run Servers
    list.add('https://ais-dev-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app/api/extract');
    list.add('https://ais-pre-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app/api/extract');

    if (primaryWispbyteUrl.isNotEmpty && primaryWispbyteUrl != defaultWispbyteEndpoint) {
      list.add(primaryWispbyteUrl);
    }
    // Localhost / Emulator mapping for development
    list.add('http://10.0.2.2:3000/api/extract');
    list.add('http://localhost:3000/api/extract');
    list.add(defaultWispbyteEndpoint);
    return list;
  }

  /// Resolves shortened URLs (vt.tiktok.com, vm.tiktok.com, youtu.be, fb.watch, etc.) to canonical full URLs
  Future<String> resolveCanonicalUrl(String rawUrl) async {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(rawUrl.trim());
    final lower = cleanUrl.toLowerCase();

    if (lower.contains('vt.tiktok.com') ||
        lower.contains('vm.tiktok.com') ||
        lower.contains('tiktok.com/t/') ||
        lower.contains('youtu.be/') ||
        lower.contains('fb.watch') ||
        lower.contains('instagr.am') ||
        lower.contains('bit.ly') ||
        lower.contains('t.co')) {
      try {
        final isTikTok = lower.contains('tiktok.com');
        final redirectDio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
            followRedirects: true,
            maxRedirects: 10,
            headers: {
              'User-Agent': isTikTok
                  ? 'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36'
                  : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          ),
        );
        final res = await redirectDio.get(cleanUrl);
        final realUrl = res.realUri.toString();
        if (realUrl.isNotEmpty && realUrl.startsWith('http')) {
          debugPrint('✅ [CloudExtractorService] Unshortened $cleanUrl -> $realUrl');
          return realUrl;
        }
      } catch (e) {
        debugPrint('[CloudExtractorService] Notice unshortening $cleanUrl: $e');
      }
    }
    return cleanUrl;
  }

  /// High-reliability TikTok / Douyin direct extractor via TikWM Engine (No Watermark)
  Future<CloudExtractedMedia?> _extractTikTokViaTikWM(String cleanUrl) async {
    try {
      debugPrint('[CloudExtractorService] 🎵 جاري استخراج تيك توك عبر محرك TikWM الفائق...');
      
      // Attempt 1: POST request
      final postResponse = await _dio.post(
        'https://www.tikwm.com/api/',
        data: FormData.fromMap({'url': cleanUrl, 'hd': '1'}),
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
            'Referer': 'https://www.tikwm.com/',
          },
        ),
      );

      Map<String, dynamic>? data;
      if (postResponse.statusCode == 200 && postResponse.data != null) {
        final raw = postResponse.data;
        data = raw is Map<String, dynamic> ? raw : (raw is String ? jsonDecode(raw) : null);
      }

      // Attempt 2: GET fallback if POST returned no data
      if (data == null || data['code'] != 0) {
        final getResponse = await _dio.get(
          'https://www.tikwm.com/api/',
          queryParameters: {'url': cleanUrl, 'hd': '1'},
          options: Options(
            sendTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
          ),
        );
        if (getResponse.statusCode == 200 && getResponse.data != null) {
          final raw = getResponse.data;
          data = raw is Map<String, dynamic> ? raw : (raw is String ? jsonDecode(raw) : null);
        }
      }

      if (data != null && data['code'] == 0 && data['data'] is Map) {
        final d = data['data'] as Map;
        var playUrl = (d['play'] ?? d['hdplay'] ?? d['wmplay'])?.toString();
        if (playUrl != null && playUrl.isNotEmpty) {
          if (playUrl.startsWith('/')) {
            playUrl = 'https://www.tikwm.com$playUrl';
          }
          final title = (d['title']?.toString() ?? 'TikTok_Video_${DateTime.now().millisecondsSinceEpoch}')
              .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
              .trim();
          final format = 'mp4';
          final thumb = d['cover']?.toString();
          final size = d['size'] is int ? d['size'] as int : null;

          debugPrint('✅ [TikWM] نجح استخراج تيك توك بدون علامة مائية!');
          return CloudExtractedMedia(
            success: true,
            originalUrl: cleanUrl,
            directStreamUrl: playUrl,
            title: CloudExtractedMedia.sanitizeFilename(title, format),
            format: format,
            quality: 'TikWM HD (بدون علامة مائية) ⚡',
            thumbnailUrl: thumb,
            estimatedSizeBytes: size,
            serverUsed: 'TikWM Native Engine',
            isDirectFallback: false,
          );
        }
      }
    } catch (e) {
      debugPrint('[CloudExtractorService] تنبيه استخراج تيك توك عبر TikWM: $e');
    }
    return null;
  }

  /// Extraction via candidate backend API servers (Node/yt-dlp)
  Future<CloudExtractedMedia?> _extractViaBackendServers(String cleanUrl) async {
    for (final baseEndpoint in _candidateServerEndpoints) {
      try {
        final targetReq = baseEndpoint.endsWith('=')
            ? '$baseEndpoint${Uri.encodeComponent(cleanUrl)}'
            : '$baseEndpoint?url=${Uri.encodeComponent(cleanUrl)}';

        final response = await _dio.get(
          targetReq,
          options: Options(
            sendTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final dynamic raw = response.data;
          final Map<String, dynamic> data = raw is Map<String, dynamic>
              ? raw
              : (raw is String ? jsonDecode(raw) : {});

          if (data['success'] == true && data['direct_url'] != null) {
            final directUrl = data['direct_url'].toString();
            if (directUrl.isNotEmpty) {
              final title = data['title']?.toString() ?? 'Media_${DateTime.now().millisecondsSinceEpoch}';
              final format = data['format']?.toString() ?? 'mp4';
              final thumb = data['thumbnail']?.toString();
              final rawSize = data['size'];
              final int? size = rawSize is int ? rawSize : int.tryParse(rawSize?.toString() ?? '');

              debugPrint('✅ [Backend Extractor] نجح الاستخراج عبر ($baseEndpoint)');
              return CloudExtractedMedia(
                success: true,
                originalUrl: cleanUrl,
                directStreamUrl: directUrl,
                title: CloudExtractedMedia.sanitizeFilename(title, format),
                format: format,
                quality: data['provider']?.toString() ?? 'HyperPulse SpeedCore ⚡',
                thumbnailUrl: thumb,
                estimatedSizeBytes: size,
                serverUsed: baseEndpoint,
                isDirectFallback: false,
              );
            }
          }
        }
      } catch (_) {
        // Continue trying next candidate server
      }
    }
    return null;
  }

  /// Primary Failover Media Extraction
  Future<CloudExtractedMedia> extractDirectMedia(String webpageUrl) async {
    final rawCleanUrl = SmartUrlFilter.extractRealTargetUrl(webpageUrl.trim());
    final cleanUrl = await resolveCanonicalUrl(rawCleanUrl);

    // 0. Direct downloadable file bypass (APK, ZIP, ISO, direct mp4, etc.)
    if (SmartUrlFilter.isDownloadableFileUrl(cleanUrl) && !isSocialVideoPlatform(cleanUrl)) {
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'mp4';
      return CloudExtractedMedia.directFallback(
        originalUrl: cleanUrl,
        format: ext,
      );
    }

    // =========================================================================
    // 1. TIKTOK SPECIALIZED EXTRACTION (Priority 1 for TikTok / Douyin)
    // =========================================================================
    if (isTikTokUrl(cleanUrl)) {
      final tikTokResult = await _extractTikTokViaTikWM(cleanUrl);
      if (tikTokResult != null && tikTokResult.success) {
        return tikTokResult;
      }
    }

    // =========================================================================
    // 2. BACKEND SERVERS EXTRACTION (yt-dlp Native SpeedCore ⚡)
    // =========================================================================
    final backendResult = await _extractViaBackendServers(cleanUrl);
    if (backendResult != null && backendResult.success) {
      return backendResult;
    }

    // Secondary TikTok check if not tried earlier
    if (isTikTokUrl(cleanUrl)) {
      final ttRetry = await _extractTikTokViaTikWM(cleanUrl);
      if (ttRetry != null && ttRetry.success) return ttRetry;
    }

    // =========================================================================
    // 3. BACKUP COBALT SERVERS FAILOVER (Backup 2, 3, 4 - Timeout 8s each)
    // =========================================================================
    for (int i = 0; i < cobaltBackupServers.length; i++) {
      final cobaltEndpoint = cobaltBackupServers[i];
      final serverIndex = i + 2;

      try {
        final response = await _dio.post(
          cobaltEndpoint,
          data: {
            'url': cleanUrl,
            'vQuality': '1080',
            'filenamePattern': 'classic',
          },
          options: Options(
            sendTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final dynamic rawData = response.data;
          final Map<String, dynamic> data = rawData is Map<String, dynamic>
              ? rawData
              : (rawData is String ? jsonDecode(rawData) : {});

          String? directUrl;
          if (data['url'] != null && data['url'].toString().isNotEmpty) {
            directUrl = data['url'].toString();
          } else if (data['picker'] is List && (data['picker'] as List).isNotEmpty) {
            final firstItem = (data['picker'] as List).first;
            if (firstItem is Map && firstItem['url'] != null) {
              directUrl = firstItem['url'].toString();
            }
          }

          if (directUrl != null && directUrl.isNotEmpty) {
            debugPrint('✅ Cobalt ($cobaltEndpoint): نجح الاستخراج');

            final title = data['filename']?.toString() ?? 'Video_${DateTime.now().millisecondsSinceEpoch}';
            final format = 'mp4';

            return CloudExtractedMedia(
              success: true,
              originalUrl: cleanUrl,
              directStreamUrl: directUrl,
              title: CloudExtractedMedia.sanitizeFilename(title, format),
              format: format,
              quality: 'Cobalt Failover Backup #$serverIndex',
              serverUsed: cobaltEndpoint,
              isDirectFallback: false,
            );
          }
        }
      } catch (_) {}
    }

    // =========================================================================
    // 4. VIDMATE ARCHITECTURAL TIER: HEADLESS WEBVIEW MEDIA SNIFFER ⚡
    // =========================================================================
    try {
      debugPrint('[CloudExtractorService] 🕵️ Trying Headless Media Sniffer (VidMate Engine)...');
      final sniffedResult = await HeadlessMediaSniffer.sniffMediaUrl(cleanUrl);
      if (sniffedResult != null && sniffedResult.success) {
        debugPrint('✅ [CloudExtractorService] Sniffer successfully captured stream: ${sniffedResult.directStreamUrl}');
        return sniffedResult;
      }
    } catch (e) {
      debugPrint('[CloudExtractorService] Sniffer notice: $e');
    }

    // =========================================================================
    // 5. ALL EXTRACTION ENGINES EXHAUSTED
    // =========================================================================
    const finalErrorMessage = 'تعذر استخراج الرابط المباشر من السيرفرات السحابية. يرجى استخدام المتصفح المدمج 🌐 لتشغيله وتحميله.';
    debugPrint('❌ $finalErrorMessage');

    return CloudExtractedMedia.failure(
      originalUrl: cleanUrl,
      errorMessage: finalErrorMessage,
    );
  }

  /// Alias for extractDirectMedia
  Future<CloudExtractedMedia> extractMedia(String webpageUrl) => extractDirectMedia(webpageUrl);

  // Platform detection helpers
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

  static bool isTikTokUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('tiktok.com') || lower.contains('douyin.com');
  }

  static bool isYouTubeUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('youtube.com') || lower.contains('youtu.be');
  }

  static bool isInstagramUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('instagram.com');
  }

  static bool isFacebookUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('facebook.com') || lower.contains('fb.watch') || lower.contains('fb.com');
  }

  static bool isTwitterUrl(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    return lower.contains('twitter.com') || lower.contains('x.com');
  }

  static String? extractYouTubeVideoId(String rawUrl) {
    try {
      final clean = rawUrl.trim();
      final regExp = RegExp(
        r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})',
        caseSensitive: false,
      );
      final match = regExp.firstMatch(clean);
      if (match != null && match.group(1) != null) {
        return match.group(1);
      }
      final uri = Uri.tryParse(clean);
      if (uri != null) {
        return uri.queryParameters['v'];
      }
    } catch (_) {}
    return null;
  }

  /// Real-time YouTube title resolution via official YouTube oEmbed API with fallbacks
  static Future<String?> fetchYouTubeRealTitle(String rawUrl) async {
    try {
      final cleanUrl = SmartUrlFilter.extractRealTargetUrl(rawUrl.trim());
      final oembedUri = Uri.parse('https://www.youtube.com/oembed').replace(
        queryParameters: {
          'url': cleanUrl,
          'format': 'json',
        },
      );

      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );

      final response = await dio.get(oembedUri.toString());
      if (response.statusCode == 200 && response.data != null) {
        final dynamic rawData = response.data;
        final Map<String, dynamic> data = rawData is Map<String, dynamic>
            ? rawData
            : (rawData is String ? jsonDecode(rawData) : {});
        final title = data['title']?.toString();
        if (title != null && title.trim().isNotEmpty) {
          final sanitized = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
          debugPrint('✅ [CloudExtractorService] استرجاع عنوان يوتيوب الأصلي: $sanitized');
          return sanitized;
        }
      }
    } catch (e) {
      debugPrint('[CloudExtractorService] تنبيه استرجاع عنوان يوتيوب: $e');
    }
    return null;
  }
}
