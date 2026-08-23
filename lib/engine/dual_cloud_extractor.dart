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
  final String? providerUsed; // 'Primary (Railway)', 'Secondary (Cobalt)', 'YT1s Engine', etc.
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

/// Dual Cloud Extractor with Automatic High-Speed Failover
/// 1. Cobalt v10 High-Speed Engine
/// 2. YT1s Multi-Mirror Engine
/// 3. Y2Mate Engine
/// 4. Loader.to Direct Stream Engine
/// 5. Self-hosted Railway yt-dlp backend
class DualCloudExtractor {
  /// Default or custom primary Railway backend URL
  static String primaryRailwayUrl = 'https://hyperpulse-api-production.up.railway.app/extract';

  /// Modern Cobalt v10 API instances
  static final List<String> cobaltInstances = [
    'https://api.cobalt.tools',
    'https://cobalt.api.redteam.tools',
    'https://cobalt-api.kwiatekm.tokyo',
    'https://co.wuk.sh',
  ];

  static const Duration quickTimeout = Duration(milliseconds: 3500);

  /// Main extraction method with multi-layer automatic failover
  static Future<DualExtractionResult> extract(String rawUrl) async {
    final cleanUrl = rawUrl.trim();
    if (cleanUrl.isEmpty) {
      return DualExtractionResult.failed(errorMessage: 'رابط الوسائط فارغ');
    }

    debugPrint('[DualCloudExtractor] 🚀 Starting multi-engine extraction for: $cleanUrl');

    // -------------------------------------------------------------
    // Engine 1: Modern Cobalt v10 Instances (Fastest & direct)
    // -------------------------------------------------------------
    for (final cobaltEndpoint in cobaltInstances) {
      try {
        final res = await _tryCobaltV10Instance(cleanUrl, cobaltEndpoint);
        if (res != null && res.success && res.directUrl != null) {
          debugPrint('[DualCloudExtractor] ✅ Cobalt v10 ($cobaltEndpoint) succeeded!');
          return res;
        }
      } catch (e) {
        debugPrint('[DualCloudExtractor] Cobalt ($cobaltEndpoint) notice: $e');
      }
    }

    // -------------------------------------------------------------
    // Engine 2: YT1s Global Network (Dedicated YouTube & Social)
    // -------------------------------------------------------------
    try {
      final yt1sRes = await _tryYt1s(cleanUrl);
      if (yt1sRes != null && yt1sRes.success && yt1sRes.directUrl != null) {
        debugPrint('[DualCloudExtractor] ✅ YT1s Engine succeeded!');
        return yt1sRes;
      }
    } catch (e) {
      debugPrint('[DualCloudExtractor] YT1s notice: $e');
    }

    // -------------------------------------------------------------
    // Engine 3: Y2Mate Direct API
    // -------------------------------------------------------------
    try {
      final y2mateRes = await _tryY2Mate(cleanUrl);
      if (y2mateRes != null && y2mateRes.success && y2mateRes.directUrl != null) {
        debugPrint('[DualCloudExtractor] ✅ Y2Mate Engine succeeded!');
        return y2mateRes;
      }
    } catch (e) {
      debugPrint('[DualCloudExtractor] Y2Mate notice: $e');
    }

    // -------------------------------------------------------------
    // Engine 4: Loader.to API
    // -------------------------------------------------------------
    try {
      final loaderRes = await _tryLoaderTo(cleanUrl);
      if (loaderRes != null && loaderRes.success && loaderRes.directUrl != null) {
        debugPrint('[DualCloudExtractor] ✅ Loader.to Engine succeeded!');
        return loaderRes;
      }
    } catch (e) {
      debugPrint('[DualCloudExtractor] Loader.to notice: $e');
    }

    // -------------------------------------------------------------
    // Engine 5: Primary Railway Backend (if deployed)
    // -------------------------------------------------------------
    try {
      final primaryResult = await _tryPrimaryRailway(cleanUrl);
      if (primaryResult != null && primaryResult.success && primaryResult.directUrl != null) {
        return primaryResult;
      }
    } catch (_) {}

    debugPrint('[DualCloudExtractor] ❌ All extraction servers failed for: $cleanUrl');
    return DualExtractionResult.failed(
      errorMessage: 'تعذر استخراج الرابط المباشر من السيرفرات السحابية. يرجى استخدام المتصفح المدمج 🌐 لتشغيله وتحميله.',
    );
  }

  /// Modern Cobalt v10 Endpoint Handler
  static Future<DualExtractionResult?> _tryCobaltV10Instance(String videoUrl, String endpoint) async {
    final client = http.Client();
    try {
      final uri = Uri.parse(endpoint.endsWith('/') ? endpoint : '$endpoint/');
      final response = await client.post(
        uri,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        },
        body: jsonEncode({
          'url': videoUrl,
          'videoQuality': '720',
          'filenameStyle': 'basic',
          'downloadMode': 'auto',
        }),
      ).timeout(quickTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data is Map<String, dynamic>) {
          String? directUrl;
          if (data['url'] != null && data['url'].toString().startsWith('http')) {
            directUrl = data['url'].toString();
          } else if (data['audio'] != null && data['audio'].toString().startsWith('http')) {
            directUrl = data['audio'].toString();
          } else if (data['picker'] is List && (data['picker'] as List).isNotEmpty) {
            final first = data['picker'][0];
            if (first is Map && first['url'] != null) {
              directUrl = first['url'].toString();
            }
          }

          if (directUrl != null && directUrl.isNotEmpty) {
            var title = (data['filename'] ?? 'HyperPulse_Video').toString();
            title = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
            return DualExtractionResult.successful(
              directUrl: directUrl,
              title: title,
              format: 'mp4',
              size: 0,
              providerUsed: 'محرك Cobalt السريع ⚡',
            );
          }
        }
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// YT1s API Handler (Extracts YouTube direct streams)
  static Future<DualExtractionResult?> _tryYt1s(String videoUrl) async {
    final client = http.Client();
    try {
      final searchRes = await client.post(
        Uri.parse('https://yt1s.com/api/ajaxSearch/index'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: 'q=${Uri.encodeQueryComponent(videoUrl)}&vt=home',
      ).timeout(quickTimeout);

      if (searchRes.statusCode == 200) {
        final searchData = jsonDecode(searchRes.body);
        if (searchData is Map && searchData['status'] == 'ok' && searchData['links'] is Map) {
          final vid = searchData['vid']?.toString() ?? '';
          final title = (searchData['title'] ?? 'YouTube_Video').toString();
          final links = searchData['links'] as Map;

          // Find mp4 key
          String? kToken;
          if (links['mp4'] is Map) {
            final mp4Map = links['mp4'] as Map;
            // Pick 720p or 480p or 360p or first available
            for (final key in ['136', '18', '22', 'auto']) {
              if (mp4Map[key] is Map && mp4Map[key]['k'] != null) {
                kToken = mp4Map[key]['k'].toString();
                break;
              }
            }
            if (kToken == null && mp4Map.isNotEmpty) {
              final first = mp4Map.values.first;
              if (first is Map && first['k'] != null) {
                kToken = first['k'].toString();
              }
            }
          }

          if (kToken != null && vid.isNotEmpty) {
            // Convert to download link
            final convertRes = await client.post(
              Uri.parse('https://yt1s.com/api/ajaxConvert/index'),
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'X-Requested-With': 'XMLHttpRequest',
              },
              body: 'vid=${Uri.encodeQueryComponent(vid)}&k=${Uri.encodeQueryComponent(kToken)}',
            ).timeout(quickTimeout);

            if (convertRes.statusCode == 200) {
              final convData = jsonDecode(convertRes.body);
              if (convData is Map && convData['status'] == 'ok' && convData['dlink'] != null) {
                final dlink = convData['dlink'].toString();
                if (dlink.startsWith('http')) {
                  return DualExtractionResult.successful(
                    directUrl: dlink,
                    title: title,
                    format: 'mp4',
                    providerUsed: 'محرك YT1s Turbo ⚡',
                  );
                }
              }
            }
          }
        }
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// Y2Mate Handler
  static Future<DualExtractionResult?> _tryY2Mate(String videoUrl) async {
    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://api.y2mate.is/v1/analyze'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
        body: jsonEncode({'url': videoUrl}),
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['formats'] is Map) {
          final formats = data['formats'] as Map;
          if (formats['video'] is List && (formats['video'] as List).isNotEmpty) {
            for (final f in formats['video']) {
              if (f is Map && f['downloadUrl'] != null && f['downloadUrl'].toString().startsWith('http')) {
                return DualExtractionResult.successful(
                  directUrl: f['downloadUrl'].toString(),
                  title: data['title']?.toString() ?? 'Y2Mate_Video',
                  format: 'mp4',
                  providerUsed: 'محرك Y2Mate السحابي ⚡',
                );
              }
            }
          }
        }
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// Loader.to Handler
  static Future<DualExtractionResult?> _tryLoaderTo(String videoUrl) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://loader.to/ajax/download.php?button=1&start=1&end=1&format=720&url=${Uri.encodeComponent(videoUrl)}');
      final res = await client.get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['success'] == true && data['id'] != null) {
          final id = data['id'].toString();
          // Poll progress once or twice
          for (int i = 0; i < 3; i++) {
            await Future.delayed(const Duration(milliseconds: 1000));
            final progressRes = await client.get(
              Uri.parse('https://loader.to/ajax/progress.php?id=$id'),
              headers: {'User-Agent': 'Mozilla/5.0'},
            ).timeout(const Duration(seconds: 2));

            if (progressRes.statusCode == 200) {
              final progData = jsonDecode(progressRes.body);
              if (progData is Map && progData['download_url'] != null && progData['download_url'].toString().startsWith('http')) {
                return DualExtractionResult.successful(
                  directUrl: progData['download_url'].toString(),
                  title: data['title']?.toString() ?? 'Loader_Video',
                  format: 'mp4',
                  providerUsed: 'سيرفر Loader.to ⚡',
                );
              }
            }
          }
        }
      }
      return null;
    } finally {
      client.close();
    }
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
      ).timeout(const Duration(milliseconds: 2000));

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
      }
      return null;
    } finally {
      client.close();
    }
  }
}

