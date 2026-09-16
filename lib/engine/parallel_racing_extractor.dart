import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class RacingResult {
  final bool success;
  final String? directUrl;
  final String? title;
  final String? format;
  final int? size;
  final String? thumbnail;
  final String? serverUsed;
  final Duration elapsed;
  final String? error;

  RacingResult({
    required this.success,
    this.directUrl,
    this.title,
    this.format,
    this.size,
    this.thumbnail,
    this.serverUsed,
    required this.elapsed,
    this.error,
  });
}

class ParallelRacingExtractor {
  /// Live Production Cloud Run instances (Clean, SSL-encrypted, zero localhost)
  static const List<String> _cloudRunServers = [
    'https://ais-dev-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app/api/extract',
    'https://ais-pre-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app/api/extract',
  ];

  static const List<String> _cobaltServers = [
    'https://api.cobalt.tools',
    'https://cobalt.stream',
    'https://co.wuk.sh',
  ];

  /// Maximum timeout per individual server
  static const Duration _serverTimeout = Duration(seconds: 3);

  /// Global race timeout
  static const Duration _totalTimeout = Duration(seconds: 8);

  /// Main entry point for parallel server racing
  static Future<RacingResult> race(String targetUrl) async {
    final stopwatch = Stopwatch()..start();

    // 1. Prepare candidate futures for concurrent execution
    final futures = <Future<RacingResult?>>[];

    // Cloud Run high-speed multi-resolvers
    for (final server in _cloudRunServers) {
      futures.add(_tryCloudRun(server, targetUrl, stopwatch));
    }

    // Cobalt instances (Backup)
    for (final server in _cobaltServers) {
      futures.add(_tryCobalt(server, targetUrl, stopwatch));
    }

    // TikTok direct API
    if (targetUrl.contains('tiktok.com') || targetUrl.contains('douyin.com')) {
      futures.add(_tryTikWM(targetUrl, stopwatch));
    }

    // YouTube direct resolvers
    if (targetUrl.contains('youtube.com') || targetUrl.contains('youtu.be')) {
      futures.add(_tryInvidious(targetUrl, stopwatch));
      futures.add(_tryPiped(targetUrl, stopwatch));
    }

    // 2. Race: First successful response completes immediately
    try {
      final winner = await _raceFirstSuccessful(futures, _totalTimeout);
      if (winner != null && winner.success) {
        debugPrint('[ParallelRacing] 🏆 الفائز في السباق: ${winner.serverUsed} في ${winner.elapsed.inMilliseconds}ms');
        return winner;
      }
    } catch (e) {
      debugPrint('[ParallelRacing] ⚠️ استثناء أثناء السباق: $e');
    }

    stopwatch.stop();
    return RacingResult(
      success: false,
      elapsed: stopwatch.elapsed,
      error: 'فشلت جميع السيرفرات في ${stopwatch.elapsed.inSeconds} ثانية',
    );
  }

  /// Concurrently waits for the first Future that returns a valid successful result
  static Future<RacingResult?> _raceFirstSuccessful(
    List<Future<RacingResult?>> futures,
    Duration timeout,
  ) async {
    final completer = Completer<RacingResult?>();
    int remaining = futures.length;

    if (remaining == 0) return null;

    for (final future in futures) {
      future.then((result) {
        if (result != null && result.success && result.directUrl != null && result.directUrl!.isNotEmpty) {
          if (!completer.isCompleted) {
            completer.complete(result);
          }
        }
      }).catchError((_) {
        // Individual server failures are ignored
      }).whenComplete(() {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    try {
      return await completer.future.timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// Cloud Run API extractor
  static Future<RacingResult?> _tryCloudRun(
    String serverUrl,
    String targetUrl,
    Stopwatch sw,
  ) async {
    HttpClient? client;
    try {
      final uri = Uri.parse(serverUrl).replace(
        queryParameters: {'url': targetUrl},
      );
      client = HttpClient();
      client.connectionTimeout = _serverTimeout;

      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36');

      final response = await request.close().timeout(_serverTimeout);
      if (response.statusCode != 200) {
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (data['success'] == true && data['direct_url'] != null) {
        final directUrl = data['direct_url'].toString();
        if (directUrl.isNotEmpty) {
          return RacingResult(
            success: true,
            directUrl: directUrl,
            title: data['title']?.toString(),
            format: data['format']?.toString() ?? 'mp4',
            size: data['size'] is num ? (data['size'] as num).toInt() : null,
            thumbnail: data['thumbnail']?.toString(),
            serverUsed: 'Cloud Run (${serverUrl.contains('dev') ? 'Primary' : 'Mirror'})',
            elapsed: sw.elapsed,
          );
        }
      }
    } catch (_) {
    } finally {
      client?.close(force: true);
    }
    return null;
  }

  /// Cobalt API extractor
  static Future<RacingResult?> _tryCobalt(
    String serverUrl,
    String targetUrl,
    Stopwatch sw,
  ) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = _serverTimeout;

      final uri = Uri.parse(serverUrl.endsWith('/') ? '${serverUrl}api/json' : '$serverUrl/api/json');
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36');

      request.write(jsonEncode({
        'url': targetUrl,
        'videoQuality': '720',
        'vQuality': '720',
        'filenameStyle': 'basic',
        'downloadMode': 'auto',
      }));

      final response = await request.close().timeout(_serverTimeout);
      if (response.statusCode != 200) {
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      String? directUrl = data['url']?.toString();
      if ((directUrl == null || directUrl.isEmpty) && data['picker'] is List) {
        final picker = data['picker'] as List;
        if (picker.isNotEmpty && picker.first is Map) {
          directUrl = picker.first['url']?.toString();
        }
      }

      if (directUrl != null && directUrl.isNotEmpty) {
        return RacingResult(
          success: true,
          directUrl: directUrl,
          title: data['filename']?.toString() ?? 'Cobalt_Media',
          format: 'mp4',
          serverUsed: 'Cobalt (${Uri.parse(serverUrl).host})',
          elapsed: sw.elapsed,
        );
      }
    } catch (_) {
    } finally {
      client?.close(force: true);
    }
    return null;
  }

  /// TikWM specialized resolver (Instant response for TikTok)
  static Future<RacingResult?> _tryTikWM(String targetUrl, Stopwatch sw) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = _serverTimeout;

      final uri = Uri.parse('https://www.tikwm.com/api/')
          .replace(queryParameters: {'url': targetUrl, 'hd': '1'});

      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36');
      request.headers.set(HttpHeaders.refererHeader, 'https://www.tikwm.com/');

      final response = await request.close().timeout(_serverTimeout);
      if (response.statusCode != 200) {
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (data['code'] == 0 && data['data'] != null) {
        final d = data['data'] as Map;
        var playUrl = d['play']?.toString() ?? d['hdplay']?.toString() ?? d['wmplay']?.toString();
        if (playUrl != null && playUrl.isNotEmpty) {
          if (playUrl.startsWith('/')) {
            playUrl = 'https://www.tikwm.com$playUrl';
          }
          return RacingResult(
            success: true,
            directUrl: playUrl,
            title: d['title']?.toString() ?? 'TikTok_Video',
            format: 'mp4',
            thumbnail: d['cover']?.toString(),
            serverUsed: 'TikWM HD (Zero Watermark)',
            elapsed: sw.elapsed,
          );
        }
      }
    } catch (_) {
    } finally {
      client?.close(force: true);
    }
    return null;
  }

  /// Invidious (YouTube direct parser)
  static Future<RacingResult?> _tryInvidious(String targetUrl, Stopwatch sw) async {
    final match = RegExp(
      r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})',
      caseSensitive: false,
    ).firstMatch(targetUrl);
    final videoId = match?.group(1);
    if (videoId == null) return null;

    const instances = [
      'https://inv.tux.pizza',
      'https://invidious.nerdvpn.de',
      'https://yewtu.be',
    ];

    for (final host in instances) {
      HttpClient? client;
      try {
        client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 2);

        final request = await client.getUrl(
          Uri.parse('$host/api/v1/videos/$videoId'),
        );
        request.headers.set(HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36');

        final response = await request.close().timeout(const Duration(seconds: 2));
        if (response.statusCode != 200) {
          continue;
        }

        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        if (data['formatStreams'] is List && (data['formatStreams'] as List).isNotEmpty) {
          final formats = data['formatStreams'] as List;
          final chosen = formats.first as Map;
          var dUrl = chosen['url'].toString();
          if (dUrl.startsWith('/')) dUrl = '$host$dUrl';

          return RacingResult(
            success: true,
            directUrl: dUrl,
            title: (data['title'] ?? 'YouTube_Video').toString(),
            format: 'mp4',
            thumbnail: 'https://img.youtube.com/vi/$videoId/hqdefault.jpg',
            serverUsed: 'Invidious ($host)',
            elapsed: sw.elapsed,
          );
        }
      } catch (_) {
        continue;
      } finally {
        client?.close(force: true);
      }
    }
    return null;
  }

  /// Piped (YouTube direct streams)
  static Future<RacingResult?> _tryPiped(String targetUrl, Stopwatch sw) async {
    final match = RegExp(
      r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})',
      caseSensitive: false,
    ).firstMatch(targetUrl);
    final videoId = match?.group(1);
    if (videoId == null) return null;

    const instances = [
      'https://pipedapi.kavin.rocks',
      'https://api.piped.privacydev.net',
    ];

    for (final host in instances) {
      HttpClient? client;
      try {
        client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 2);

        final request = await client.getUrl(Uri.parse('$host/streams/$videoId'));
        request.headers.set(HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36');

        final response = await request.close().timeout(const Duration(seconds: 2));
        if (response.statusCode != 200) {
          continue;
        }

        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        if (data['videoStreams'] is List && (data['videoStreams'] as List).isNotEmpty) {
          final streams = data['videoStreams'] as List;
          for (final s in streams) {
            if (s is Map && s['url'] != null) {
              return RacingResult(
                success: true,
                directUrl: s['url'].toString(),
                title: (data['title'] ?? 'YouTube_Video').toString(),
                format: 'mp4',
                serverUsed: 'Piped ($host)',
                elapsed: sw.elapsed,
              );
            }
          }
        }
      } catch (_) {
        continue;
      } finally {
        client?.close(force: true);
      }
    }
    return null;
  }
}
