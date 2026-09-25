import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'smart_url_filter.dart';
import 'headless_media_sniffer.dart';
import 'innertube_extractor.dart';
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
  static const String defaultWispbyteEndpoint = '';
  static const List<String> cobaltBackupServers = [];

  // Shared HttpClient connection pool for keep-alive sockets
  static final HttpClient _sharedHttpClient = HttpClient()
    ..maxConnectionsPerHost = 20
    ..idleTimeout = const Duration(minutes: 5)
    ..connectionTimeout = const Duration(seconds: 10)
    ..autoUncompress = false;

  CloudExtractorService({
    Dio? customDio,
    String? wispbyteServerUrl,
  })  : primaryWispbyteUrl = wispbyteServerUrl ?? defaultWispbyteEndpoint,
        _dio = customDio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(milliseconds: 3500),
                receiveTimeout: const Duration(milliseconds: 3500),
                sendTimeout: const Duration(milliseconds: 3500),
                headers: {
                  'Accept': 'application/json, text/plain, */*',
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                },
              ),
            ) {
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => _sharedHttpClient,
    );
  }

  /// Candidate backend server endpoints for custom self-hosted extractors
  List<String> get _candidateServerEndpoints {
    final list = <String>[];

    if (primaryWispbyteUrl.isNotEmpty &&
        primaryWispbyteUrl != defaultWispbyteEndpoint &&
        !primaryWispbyteUrl.contains('78.154.103.45')) {
      list.add(primaryWispbyteUrl);
    }
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
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
            followRedirects: false, // Don't download entire HTML landing page; grab 301/302 Location header instantly
            validateStatus: (status) => status != null && status < 400,
            headers: {
              'User-Agent': isTikTok
                  ? 'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36'
                  : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          ),
        );
        final res = await redirectDio.get(cleanUrl);
        final location = res.headers.value('location');
        if (location != null && location.isNotEmpty && location.startsWith('http')) {
          debugPrint('✅ [CloudExtractorService] Fast Unshortened (302) $cleanUrl -> $location');
          return location;
        }
      } catch (e) {
        if (e is DioException && e.response?.headers.value('location') != null) {
          final loc = e.response!.headers.value('location')!;
          if (loc.isNotEmpty && loc.startsWith('http')) {
            return loc;
          }
        }
        debugPrint('[CloudExtractorService] Notice unshortening $cleanUrl: $e');
      }
    }
    return cleanUrl;
  }

  /// High-reliability TikTok / Douyin direct extractor via TikWM Engine (No Watermark)
  Future<CloudExtractedMedia?> _extractTikTokViaTikWM(String cleanUrl, {String? originalUrl}) async {
    final urlsToTry = <String>[cleanUrl];
    if (originalUrl != null && originalUrl.isNotEmpty && originalUrl != cleanUrl) {
      urlsToTry.add(originalUrl);
    }

    for (final targetUrl in urlsToTry) {
      try {
        debugPrint('[CloudExtractorService] 🎵 جاري استخراج تيك توك عبر محرك TikWM الفائق لـ $targetUrl...');

        Map<String, dynamic>? data;

        // Attempt 1: Standard POST with application/x-www-form-urlencoded
        try {
          final postResponse = await _dio.post(
            'https://www.tikwm.com/api/',
            data: {'url': targetUrl, 'hd': '1'},
            options: Options(
              contentType: Headers.formUrlEncodedContentType,
              sendTimeout: const Duration(seconds: 4),
              receiveTimeout: const Duration(seconds: 4),
              headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                'Referer': 'https://www.tikwm.com/',
                'Accept': 'application/json, text/javascript, */*; q=0.01',
              },
            ),
          );
          if (postResponse.statusCode == 200 && postResponse.data != null) {
            final raw = postResponse.data;
            data = raw is Map<String, dynamic> ? raw : (raw is String ? jsonDecode(raw) : null);
          }
        } catch (_) {}

        // Attempt 2: GET fallback if POST returned no data
        if (data == null || data['code'] != 0) {
          try {
            final getResponse = await _dio.get(
              'https://www.tikwm.com/api/',
              queryParameters: {'url': targetUrl, 'hd': '1'},
              options: Options(
                sendTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 4),
                headers: {
                  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                  'Referer': 'https://www.tikwm.com/',
                },
              ),
            );
            if (getResponse.statusCode == 200 && getResponse.data != null) {
              final raw = getResponse.data;
              data = raw is Map<String, dynamic> ? raw : (raw is String ? jsonDecode(raw) : null);
            }
          } catch (_) {}
        }

        // Attempt 3: Direct mirror endpoint fallback (without www)
        if (data == null || data['code'] != 0) {
          try {
            final mirrorResponse = await _dio.get(
              'https://tikwm.com/api/',
              queryParameters: {'url': targetUrl, 'hd': '1'},
              options: Options(
                sendTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 4),
              ),
            );
            if (mirrorResponse.statusCode == 200 && mirrorResponse.data != null) {
              final raw = mirrorResponse.data;
              data = raw is Map<String, dynamic> ? raw : (raw is String ? jsonDecode(raw) : null);
            }
          } catch (_) {}
        }

        if (data != null && data['code'] == 0 && data['data'] is Map) {
          final d = data['data'] as Map;
          var playUrl = (d['play'] ?? d['hdplay'] ?? d['wmplay'] ?? d['music'])?.toString();
          if (playUrl != null && playUrl.isNotEmpty) {
            if (playUrl.startsWith('/')) {
              playUrl = 'https://www.tikwm.com$playUrl';
            }
            final title = (d['title']?.toString() ?? 'TikTok_Video_${DateTime.now().millisecondsSinceEpoch}')
                .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
                .trim();
            final format = playUrl.contains('.mp3') ? 'mp3' : 'mp4';
            final thumb = d['cover']?.toString();
            final size = d['size'] is int ? d['size'] as int : null;

            debugPrint('✅ [TikWM] نجح استخراج تيك توك بدون علامة مائية!');
            return CloudExtractedMedia(
              success: true,
              originalUrl: targetUrl,
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
    }
    return null;
  }

  /// Extraction via candidate backend API servers with Parallel Racing ⚡
  Future<CloudExtractedMedia?> _extractViaBackendServers(String cleanUrl) async {
    final endpoints = _candidateServerEndpoints;
    if (endpoints.isEmpty) return null;

    final completer = Completer<CloudExtractedMedia?>();
    int pending = endpoints.length;

    for (final baseEndpoint in endpoints) {
      () async {
        try {
          final targetReq = baseEndpoint.endsWith('=')
              ? '$baseEndpoint${Uri.encodeComponent(cleanUrl)}'
              : '$baseEndpoint?url=${Uri.encodeComponent(cleanUrl)}';

          final response = await _dio.get(
            targetReq,
            options: Options(
              sendTimeout: const Duration(milliseconds: 3500),
              receiveTimeout: const Duration(milliseconds: 3500),
            ),
          );

          if (response.statusCode == 200 && response.data != null && !completer.isCompleted) {
            final dynamic raw = response.data;
            final Map<String, dynamic> data = raw is Map<String, dynamic>
                ? raw
                : (raw is String ? jsonDecode(raw) : {});

            if (data['success'] == true && data['direct_url'] != null) {
              final directUrl = data['direct_url'].toString();
              if (directUrl.isNotEmpty && !completer.isCompleted) {
                final title = data['title']?.toString() ?? 'Media_${DateTime.now().millisecondsSinceEpoch}';
                final format = data['format']?.toString() ?? 'mp4';
                final thumb = data['thumbnail']?.toString();
                final rawSize = data['size'];
                final int? size = rawSize is int ? rawSize : int.tryParse(rawSize?.toString() ?? '');

                debugPrint('✅ [Backend Extractor ⚡ Race Winner] ($baseEndpoint)');
                completer.complete(CloudExtractedMedia(
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
                ));
                return;
              }
            }
          }
        } catch (_) {
        } finally {
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }();
    }

    try {
      return await completer.future.timeout(const Duration(milliseconds: 3800));
    } catch (_) {
      return null;
    }
  }

  /// Primary Failover Media Extraction
  Future<CloudExtractedMedia> extractDirectMedia(String webpageUrl) async {
    final rawCleanUrl = SmartUrlFilter.extractRealTargetUrl(webpageUrl.trim());

    // ⚡ Consult High-Speed URL Cache first (instant 0.01s hit!)
    final cached = UrlCache.get(rawCleanUrl);
    if (cached != null) {
      debugPrint('[CloudExtractorService] ⚡ Cache Hit! (0.01s): $rawCleanUrl');
      return cached;
    }

    final cleanUrl = await resolveCanonicalUrl(rawCleanUrl);

    // Cache helper for successful outcomes
    CloudExtractedMedia deliver(CloudExtractedMedia media) {
      if (media.success && media.directStreamUrl.isNotEmpty) {
        UrlCache.put(rawCleanUrl, media);
        if (cleanUrl != rawCleanUrl) {
          UrlCache.put(cleanUrl, media);
        }
      }
      return media;
    }

    // 0. Direct downloadable file bypass (APK, ZIP, ISO, direct mp4, etc.)
    if (SmartUrlFilter.isDownloadableFileUrl(cleanUrl) && !isSocialVideoPlatform(cleanUrl)) {
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'mp4';
      return deliver(CloudExtractedMedia.directFallback(
        originalUrl: cleanUrl,
        format: ext,
      ));
    }

    // =========================================================================
    // 1. YOUTUBE SPECIALIZED EXTRACTION (Innertube VR Oculus Engine ⚡ - 200ms)
    // =========================================================================
    if (isYouTubeUrl(cleanUrl) || isYouTubeUrl(rawCleanUrl)) {
      final ytId = extractYouTubeVideoId(cleanUrl) ?? extractYouTubeVideoId(rawCleanUrl);
      if (ytId != null && ytId.isNotEmpty) {
        try {
          debugPrint('[CloudExtractorService] ⚡ Running Lightning YouTube Innertube extraction for: $ytId');
          final innertube = InnertubeExtractor();
          final innerRes = await innertube.extract(ytId);
          if (innerRes.success && innerRes.hasStreams) {
            final best = innerRes.bestProgressive ?? innerRes.bestVideoOnly;
            if (best != null && best.url.isNotEmpty) {
              final title = innerRes.title.isNotEmpty ? innerRes.title : 'YouTube_$ytId';
              debugPrint('✅ [CloudExtractorService] 🏆 Innertube succeeded instantly in ${innerRes.elapsed.inMilliseconds}ms!');
              return deliver(CloudExtractedMedia(
                success: true,
                originalUrl: cleanUrl,
                directStreamUrl: best.url,
                title: CloudExtractedMedia.sanitizeFilename(title, 'mp4'),
                format: 'mp4',
                quality: best.qualityLabel ?? '720p HD (Innertube ⚡)',
                thumbnailUrl: innerRes.thumbnail ?? 'https://img.youtube.com/vi/$ytId/hqdefault.jpg',
                estimatedSizeBytes: best.contentLength,
                serverUsed: 'YouTube Innertube Oculus VR Engine ⚡',
                isDirectFallback: false,
              ));
            }
          }
        } catch (e) {
          debugPrint('[CloudExtractorService] Innertube notice: $e. Falling back to DualCloudExtractor...');
        }
      }
    }

    // =========================================================================
    // 2. TIKTOK SPECIALIZED EXTRACTION (Priority 1 for TikTok / Douyin)
    // =========================================================================
    if (isTikTokUrl(cleanUrl) || isTikTokUrl(rawCleanUrl)) {
      final tikTokResult = await _extractTikTokViaTikWM(cleanUrl, originalUrl: rawCleanUrl);
      if (tikTokResult != null && tikTokResult.success) {
        return deliver(tikTokResult);
      }
    }

    // =========================================================================
    // 3. DUAL CLOUD EXTRACTOR (10+ Scrapers: Instagram, Facebook, Twitter, TikTok)
    // =========================================================================
    try {
      debugPrint('[CloudExtractorService] 🚀 Running DualCloudExtractor for: $cleanUrl');
      final dualRes = await DualCloudExtractor.extract(cleanUrl);
      if (dualRes.success && dualRes.directUrl != null && dualRes.directUrl!.isNotEmpty) {
        debugPrint('✅ [CloudExtractorService] DualCloudExtractor succeeded via: ${dualRes.providerUsed}');
        final fmt = dualRes.format ?? 'mp4';
        return deliver(CloudExtractedMedia(
          success: true,
          originalUrl: cleanUrl,
          directStreamUrl: dualRes.directUrl!,
          title: CloudExtractedMedia.sanitizeFilename(dualRes.title ?? 'Media_${DateTime.now().millisecondsSinceEpoch}', fmt),
          format: fmt,
          quality: dualRes.providerUsed ?? 'Dual Cloud Turbo ⚡',
          estimatedSizeBytes: dualRes.size,
          serverUsed: dualRes.providerUsed,
          isDirectFallback: false,
        ));
      }
    } catch (dualErr) {
      debugPrint('[CloudExtractorService] DualCloudExtractor notice: $dualErr');
    }

    // =========================================================================
    // 4. CUSTOM BACKEND SERVERS (if user configured a custom endpoint)
    // =========================================================================
    if (_candidateServerEndpoints.isNotEmpty) {
      final backendResult = await _extractViaBackendServers(cleanUrl);
      if (backendResult != null && backendResult.success) {
        return deliver(backendResult);
      }
    }

    // =========================================================================
    // 5. VIDMATE ARCHITECTURAL TIER: HEADLESS WEBVIEW MEDIA SNIFFER ⚡
    // (Bypassed for YouTube because YouTube blocks headless autoplay and triggers low-memory warnings)
    // =========================================================================
    if (!isYouTubeUrl(cleanUrl) && !isYouTubeUrl(rawCleanUrl)) {
      try {
        debugPrint('[CloudExtractorService] 🕵️ Trying Headless Media Sniffer (VidMate Engine)...');
        final sniffedResult = await HeadlessMediaSniffer.sniffMediaUrl(cleanUrl);
        if (sniffedResult != null && sniffedResult.success) {
          debugPrint('✅ [CloudExtractorService] Sniffer successfully captured stream: ${sniffedResult.directStreamUrl}');
          return deliver(sniffedResult);
        }
      } catch (e) {
        debugPrint('[CloudExtractorService] Sniffer notice: $e');
      }
    }

    // =========================================================================
    // 6. ALL EXTRACTION ENGINES EXHAUSTED
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

/// [UrlCache] caches extracted media streaming links to avoid repeated roundtrips (0.01s instant hits)
class UrlCache {
  static final Map<String, _CachedResult> _cache = {};
  static const Duration _ttl = Duration(hours: 2);

  static void put(String url, CloudExtractedMedia result) {
    if (!result.success || result.directStreamUrl.isEmpty) return;
    final key = _normalize(url);
    _cache[key] = _CachedResult(result, DateTime.now());
    debugPrint('[UrlCache] ✅ محفوظ في الذاكرة المؤقتة: $key (إجمالي: ${_cache.length})');
  }

  static CloudExtractedMedia? get(String url) {
    final key = _normalize(url);
    final entry = _cache[key];
    if (entry == null) return null;

    if (DateTime.now().difference(entry.time) > _ttl) {
      _cache.remove(key);
      debugPrint('[UrlCache] ⏰ انتهت صلاحية الرابط: $key');
      return null;
    }

    debugPrint('[UrlCache] ⚡ استرجاع فوري من الذاكرة المؤقتة (0.01s): $key');
    return entry.result;
  }

  static void clear() => _cache.clear();

  static String _normalize(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return url.trim();
    // CRITICAL: For YouTube URLs, we MUST preserve the 'v' query parameter
    // otherwise all YouTube videos would map to the same cached key!
    if ((uri.host.contains('youtube.com') || uri.host.contains('youtu.be')) && uri.queryParameters.containsKey('v')) {
      final v = uri.queryParameters['v'];
      return '${uri.scheme}://${uri.host}${uri.path}?v=$v';
    }
    return '${uri.scheme}://${uri.host}${uri.path}';
  }
}

class _CachedResult {
  final CloudExtractedMedia result;
  final DateTime time;
  _CachedResult(this.result, this.time);
}

