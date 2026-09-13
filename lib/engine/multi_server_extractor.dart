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
  /// Default or custom Wispbyte server URL (can be updated dynamically at runtime via Firebase Remote Config)
  static String wispbyteServerUrl = '';

  /// Updates the Wispbyte server URL dynamically
  static void setWispbyteServerUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isNotEmpty && !trimmed.contains('78.154.103.45')) {
      wispbyteServerUrl = trimmed;
      debugPrint('[MultiServerExtractor] 🔗 Updated Wispbyte Server URL to: $wispbyteServerUrl');
    }
  }

  /// Builds the prioritized list of extraction servers:
  /// Server 1 (Primary): Cloud Run Primary Engine
  /// Server 2 (Backup): Cloud Run Mirror Engine
  /// Server 3 (Backup): Custom server if provided
  /// Server 4 (Backup): Cobalt Tools API
  /// Server 5 (Backup): Wuk.sh Cobalt API
  static List<ExtractionServerConfig> getServers({String? customWispbyteUrl}) {
    final activeWispbyteUrl = (customWispbyteUrl != null && customWispbyteUrl.trim().isNotEmpty)
        ? customWispbyteUrl.trim()
        : wispbyteServerUrl;

    return [
      const ExtractionServerConfig(
        priority: 1,
        name: 'السيرفر 1 (سحابي خارق ⚡): Cloud Run Primary Engine',
        url: 'https://ais-dev-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app/api/extract',
        type: 'wispbyte',
      ),
      const ExtractionServerConfig(
        priority: 2,
        name: 'السيرفر 2 (مرآة سحابية ⚡): Cloud Run Mirror Engine',
        url: 'https://ais-pre-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app/api/extract',
        type: 'wispbyte',
      ),
      if (activeWispbyteUrl.isNotEmpty && !activeWispbyteUrl.contains('78.154.103.45'))
        ExtractionServerConfig(
          priority: 3,
          name: 'السيرفر 3 (احتياطي سحابي مخصص): Custom Server Direct',
          url: activeWispbyteUrl,
          type: 'wispbyte',
        ),
      const ExtractionServerConfig(
        priority: 4,
        name: 'السيرفر 4 (احتياطي): Cobalt Tools API',
        url: 'https://api.cobalt.tools/api/json',
        type: 'cobalt',
      ),
      const ExtractionServerConfig(
        priority: 5,
        name: 'السيرفر 5 (احتياطي): Wuk.sh Cobalt API',
        url: 'https://co.wuk.sh/api/json',
        type: 'cobalt',
      ),
      const ExtractionServerConfig(
        priority: 6,
        name: 'السيرفر 6 (احتياطي): Cobalt Stream API',
        url: 'https://cobalt.stream/api/json',
        type: 'cobalt',
      ),
    ];
  }

  /// Main extraction method with Parallel Racing for Cloud servers and fast failover
  static Future<MultiServerExtractionResult> extract(
    String targetUrl, {
    String? customWispbyteUrl,
  }) async {
    final cleanUrl = targetUrl.trim();
    if (cleanUrl.isEmpty) {
      return MultiServerExtractionResult.failed('رابط الفيديو فارغ');
    }

    final servers = getServers(customWispbyteUrl: customWispbyteUrl);
    debugPrint('[MultiServerExtractor] 🚀 بدء نظام الاستخراج المتوازي فائق السرعة (Parallel Racing) للرابط: $cleanUrl');

    // 1. Parallel Racing across primary Cloud Run servers
    final cloudServers = servers.where((s) => s.type == 'wispbyte').toList();
    if (cloudServers.isNotEmpty) {
      final completer = Completer<MultiServerExtractionResult?>();
      int pending = cloudServers.length;

      for (final server in cloudServers) {
        () async {
          try {
            debugPrint('[MultiServerExtractor] ⚡ سباق متزامن مع: ${server.name}...');
            final result = await Isolate.run<Map<String, dynamic>>(() async {
              return await _queryServerInIsolate({
                'type': server.type,
                'url': server.url,
                'targetUrl': cleanUrl,
              });
            }).timeout(const Duration(milliseconds: 3500));

            if (result['success'] == true && result['direct_url'] != null && !completer.isCompleted) {
              final directUrl = result['direct_url'] as String;
              if (directUrl.isNotEmpty && !completer.isCompleted) {
                debugPrint('[MultiServerExtractor] 🏆 فاز في السباق المتزامن: ${server.name} ⚡');
                completer.complete(MultiServerExtractionResult(
                  success: true,
                  directUrl: directUrl,
                  title: result['title'] as String?,
                  format: result['format'] as String? ?? 'mp4',
                  size: result['size'] as int?,
                  thumbnailUrl: result['thumbnail'] as String?,
                  serverUsed: server.name,
                ));
                return;
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
        final raceWinner = await completer.future.timeout(const Duration(milliseconds: 3800));
        if (raceWinner != null && raceWinner.success) {
          return raceWinner;
        }
      } catch (_) {}
    }

    // 2. Sequential fallback to Cobalt backup servers
    final backupServers = servers.where((s) => s.type != 'wispbyte').toList();
    for (final server in backupServers) {
      debugPrint('[MultiServerExtractor] ⏳ تجربة سيرفر احتياطي: ${server.name}...');
      try {
        final result = await Isolate.run<Map<String, dynamic>>(() async {
          return await _queryServerInIsolate({
            'type': server.type,
            'url': server.url,
            'targetUrl': cleanUrl,
          });
        }).timeout(const Duration(seconds: 3));

        if (result['success'] == true && result['direct_url'] != null) {
          final directUrl = result['direct_url'] as String;
          if (directUrl.isNotEmpty) {
            debugPrint('[MultiServerExtractor] ✅ نجح الاستخراج عبر الاحتياطي: ${server.name}');
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
      } catch (_) {}
    }

    // If all servers failed:
    const finalErrorMessage = 'تعذر استخراج الفيديو. جرب لاحقاً أو استخدم الرابط المباشر.';
    debugPrint('[MultiServerExtractor] ❌ فشلت جميع السيرفرات في استخراج الفيديو.');

    // Log the failure in Firebase Analytics for monitoring
    await logFailureToFirebaseAnalytics(cleanUrl, 'All Failover extraction servers failed');

    return MultiServerExtractionResult.failed(finalErrorMessage);
  }

  /// Low-level HTTP worker designed to run isolated inside background Isolate
  static Future<Map<String, dynamic>> _queryServerInIsolate(Map<String, String> args) async {
    final serverType = args['type']!;
    final serverUrl = args['url']!;
    final targetUrl = args['targetUrl']!;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);

    try {
      if (serverType == 'wispbyte') {
        // Wispbyte endpoint: GET {serverUrl}/extract?url={targetUrl}
        final baseUri = Uri.parse(serverUrl.endsWith('/') ? '${serverUrl}extract' : '$serverUrl/extract');
        final uri = baseUri.replace(queryParameters: {'url': targetUrl});

        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36');

        final response = await request.close().timeout(const Duration(seconds: 3));
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
        request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36');

        final payload = jsonEncode({
          'url': targetUrl,
          'videoQuality': '720',
          'vQuality': '720',
          'filenamePattern': 'basic',
          'downloadMode': 'auto',
        });
        request.write(payload);

        final response = await request.close().timeout(const Duration(seconds: 3));
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
      telemetryClient.connectionTimeout = const Duration(seconds: 1);
      try {
        final uri = Uri.parse('https://ais-dev-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app/api/telemetry/extractor-failure');
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
