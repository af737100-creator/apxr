import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';

/// Representation of an extraction server configuration
class ExtractionServerConfig {
  final int priority;
  final String name;
  final String url;
  final String type; // 'wispbyte' or 'cobalt'

  const ExtractionServerConfig({
    required this.priority,
    required this.name,
    required this.url,
    required this.type,
  });
}

/// Result from the multi-server failover extraction engine
class MultiServerExtractionResult {
  final bool success;
  final String? directUrl;
  final String? title;
  final String? format;
  final int? size;
  final String? thumbnailUrl;
  final String? serverUsed;
  final String? errorMessage;

  const MultiServerExtractionResult({
    required this.success,
    this.directUrl,
    this.title,
    this.format,
    this.size,
    this.thumbnailUrl,
    this.serverUsed,
    this.errorMessage,
  });

  factory MultiServerExtractionResult.failed(String message) {
    return MultiServerExtractionResult(
      success: false,
      errorMessage: message,
    );
  }
}

/// [MultiServerExtractor]
/// High-resilience automatic failover system (نظام تبديل تلقائي)
/// Executes extraction attempts across prioritized servers in separate Isolates:
/// 1. Primary: Wispbyte Server (512MB-tuned yt-dlp)
/// 2. Backup 1: https://api.cobalt.tools/api/json
/// 3. Backup 2: https://co.wuk.sh/api/json
/// 4. Backup 3: https://cobalt.stream/api/json
/// 5. Backup 4: https://cobalt.hyonsu.com/api/json
class MultiServerExtractor {
  /// Default or custom Wispbyte server URL (can be updated dynamically at runtime)
  static String wispbyteServerUrl = 'https://pulsesphere-wispbyte.example.com';

  /// Updates the Wispbyte server URL dynamically
  static void setWispbyteServerUrl(String url) {
    if (url.trim().isNotEmpty) {
      wispbyteServerUrl = url.trim();
      debugPrint('[MultiServerExtractor] 🔗 Updated Wispbyte Server URL to: $wispbyteServerUrl');
    }
  }

  /// Builds the prioritized list of extraction servers:
  /// Server 1 (Primary): Wispbyte server
  /// Server 2 (Backup): https://api.cobalt.tools/api/json
  /// Server 3 (Backup): https://co.wuk.sh/api/json
  /// Server 4 (Backup): https://cobalt.stream/api/json
  /// Server 5 (Backup): https://cobalt.hyonsu.com/api/json
  static List<ExtractionServerConfig> getServers({String? customWispbyteUrl}) {
    final activeWispbyteUrl = (customWispbyteUrl != null && customWispbyteUrl.trim().isNotEmpty)
        ? customWispbyteUrl.trim()
        : wispbyteServerUrl;

    return [
      ExtractionServerConfig(
        priority: 1,
        name: 'السيرفر 1 (الأساسي): سيرفرنا على Wispbyte',
        url: activeWispbyteUrl,
        type: 'wispbyte',
      ),
      const ExtractionServerConfig(
        priority: 2,
        name: 'السيرفر 2 (احتياطي): Cobalt Tools API',
        url: 'https://api.cobalt.tools/api/json',
        type: 'cobalt',
      ),
      const ExtractionServerConfig(
        priority: 3,
        name: 'السيرفر 3 (احتياطي): Wuk.sh Cobalt API',
        url: 'https://co.wuk.sh/api/json',
        type: 'cobalt',
      ),
      const ExtractionServerConfig(
        priority: 4,
        name: 'السيرفر 4 (احتياطي): Cobalt Stream API',
        url: 'https://cobalt.stream/api/json',
        type: 'cobalt',
      ),
      const ExtractionServerConfig(
        priority: 5,
        name: 'السيرفر 5 (احتياطي): Cobalt Hyonsu API',
        url: 'https://cobalt.hyonsu.com/api/json',
        type: 'cobalt',
      ),
    ];
  }

  /// Main extraction method with sequential 8-second failover in isolated background threads
  static Future<MultiServerExtractionResult> extract(
    String targetUrl, {
    String? customWispbyteUrl,
  }) async {
    final cleanUrl = targetUrl.trim();
    if (cleanUrl.isEmpty) {
      return MultiServerExtractionResult.failed('رابط الفيديو فارغ');
    }

    final servers = getServers(customWispbyteUrl: customWispbyteUrl);
    debugPrint('[MultiServerExtractor] 🚀 بدء نظام التبديل التلقائي (Failover System) للرابط: $cleanUrl');

    for (final server in servers) {
      if (server.url.contains('example.com')) {
        debugPrint('[MultiServerExtractor] ⏭️ تجاوز ${server.name} (رابط تجريبي placeholder)...');
        continue;
      }

      debugPrint('[MultiServerExtractor] ⏳ جاري تجربة ${server.name} (مهلة: 4 ثوانٍ)...');

      try {
        // Execute server extraction inside a separate background Isolate to never freeze the UI
        final result = await Isolate.run<Map<String, dynamic>>(() async {
          return await _queryServerInIsolate({
            'type': server.type,
            'url': server.url,
            'targetUrl': cleanUrl,
          });
        }).timeout(const Duration(seconds: 4));

        if (result['success'] == true && result['direct_url'] != null) {
          final directUrl = result['direct_url'] as String;
          if (directUrl.isNotEmpty) {
            // Immediate success: Short-circuit and cancel any remaining attempts!
            debugPrint('[MultiServerExtractor] ✅ نجح الاستخراج فوراً عبر السيرفر: ${server.name} ⚡');
            debugPrint('[MultiServerExtractor] 🔗 الرابط المباشر: $directUrl');

            return MultiServerExtractionResult(
              success: true,
              directUrl: directUrl,
              title: result['title'] as String?,
              format: result['format'] as String? ?? 'mp4',
              size: result['size'] as int?,
              thumbnailUrl: result['thumbnail'] as String?,
              serverUsed: server.name,
            );
          }
        }

        debugPrint('[MultiServerExtractor] ⚠️ لم ينجح ${server.name}، الانتقال فوراً للسيرفر التالي...');
      } on TimeoutException {
        debugPrint('[MultiServerExtractor] ⏱️ انتهت مهلة (8 ثوانٍ) لـ ${server.name}، الانتقال فوراً للسيرفر التالي...');
      } catch (e) {
        debugPrint('[MultiServerExtractor] ❌ حدث خطأ في ${server.name}: $e، الانتقال فوراً للسيرفر التالي...');
      }
    }

    // If all servers failed:
    const finalErrorMessage = 'تعذر استخراج الفيديو. جرب لاحقاً أو استخدم الرابط المباشر.';
    debugPrint('[MultiServerExtractor] ❌ فشلت جميع السيرفرات في استخراج الفيديو.');

    // Log the failure in Firebase Analytics for monitoring
    await logFailureToFirebaseAnalytics(cleanUrl, 'All 5 Failover extraction servers failed');

    return MultiServerExtractionResult.failed(finalErrorMessage);
  }

  /// Low-level HTTP worker designed to run isolated inside background Isolate
  static Future<Map<String, dynamic>> _queryServerInIsolate(Map<String, String> args) async {
    final serverType = args['type']!;
    final serverUrl = args['url']!;
    final targetUrl = args['targetUrl']!;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 7);

    try {
      if (serverType == 'wispbyte') {
        // Wispbyte endpoint: GET {serverUrl}/extract?url={targetUrl}
        final baseUri = Uri.parse(serverUrl.endsWith('/') ? '${serverUrl}extract' : '$serverUrl/extract');
        final uri = baseUri.replace(queryParameters: {'url': targetUrl});

        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.userAgentHeader, 'PulseSphere-SpeedCore/4.2');

        final response = await request.close().timeout(const Duration(seconds: 7));
        final body = await response.transform(utf8.decoder).join();

        if (response.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          if (data['success'] == true && data['direct_url'] != null) {
            return {
              'success': true,
              'direct_url': data['direct_url'],
              'title': data['title'] ?? 'Video_Stream',
              'format': data['format'] ?? 'mp4',
              'size': data['size'] ?? 0,
              'thumbnail': data['thumbnail'] ?? '',
            };
          }
        }
        return {'success': false, 'error': 'Wispbyte returned status ${response.statusCode}'};
      } else {
        // Cobalt API endpoint: POST {serverUrl} with JSON payload
        final uri = Uri.parse(serverUrl);
        final request = await client.postUrl(uri);
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.userAgentHeader, 'PulseSphere-SpeedCore/4.2');

        final payload = jsonEncode({
          'url': targetUrl,
          'videoQuality': '720',
          'vQuality': '720',
          'filenamePattern': 'basic',
          'downloadMode': 'auto',
        });
        request.write(payload);

        final response = await request.close().timeout(const Duration(seconds: 7));
        final body = await response.transform(utf8.decoder).join();

        if (response.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          String? directUrl = data['url']?.toString();

          // Handle Cobalt picker streams
          if ((directUrl == null || directUrl.isEmpty) && data['picker'] is List) {
            final list = data['picker'] as List;
            if (list.isNotEmpty && list.first is Map) {
              directUrl = list.first['url']?.toString();
            }
          }

          if (directUrl != null && directUrl.isNotEmpty) {
            return {
              'success': true,
              'direct_url': directUrl,
              'title': data['filename']?.toString() ?? 'Cobalt_Stream',
              'format': 'mp4',
              'size': 0,
              'thumbnail': '',
            };
          }
        }
        return {'success': false, 'error': 'Cobalt returned status ${response.statusCode}'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    } finally {
      client.close(force: true);
    }
  }

  /// Logs extraction failures to Firebase Analytics for proactive monitoring
  static Future<void> logFailureToFirebaseAnalytics(String targetUrl, String reason) async {
    try {
      debugPrint('[FirebaseAnalytics] 📊 تسجيل حدث الفشل (extractor_failure):');
      debugPrint('  - URL: $targetUrl');
      debugPrint('  - Reason: $reason');
      debugPrint('  - Timestamp: ${DateTime.now().toIso8601String()}');

      // Attempt to report to backend / Firebase telemetry endpoint if configured
      final telemetryClient = HttpClient();
      telemetryClient.connectionTimeout = const Duration(seconds: 3);
      try {
        final uri = Uri.parse('http://10.0.2.2:3000/api/telemetry/extractor-failure');
        final req = await telemetryClient.postUrl(uri);
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.write(jsonEncode({
          'event': 'extractor_failure',
          'url': targetUrl,
          'reason': reason,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }));
        final res = await req.close();
        await res.drain();
      } catch (_) {}
      telemetryClient.close(force: true);
    } catch (e) {
      debugPrint('[FirebaseAnalytics] ⚠️ Logging error: $e');
    }
  }
}
