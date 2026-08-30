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
  final String? providerUsed; // 'Primary (Local Turbo Engine)', 'SaveTube CDN ⚡', 'TikWM HD', etc.
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

/// Dual Cloud Extractor with Automatic High-Speed Failover & 10+ Parallel Racing Engines
class DualCloudExtractor {
  /// Default or custom primary Railway backend URL
  static String primaryRailwayUrl = 'https://hyperpulse-api-production.up.railway.app/extract';

  /// Modern Cobalt API instances pool
  static final List<String> cobaltInstances = [
    'https://api.cobalt.tools',
    'https://cobalt.api.redteam.tools',
    'https://co.wuk.sh',
    'https://cobalt.stream',
    'https://cobalt.hyonsu.com',
  ];

  static const Duration quickTimeout = Duration(milliseconds: 4000);

  /// Main extraction method with multi-layer automatic failover & parallel racing
  static Future<DualExtractionResult> extract(String rawUrl) async {
    final cleanUrl = rawUrl.trim();
    if (cleanUrl.isEmpty) {
      return DualExtractionResult.failed(errorMessage: 'رابط الوسائط فارغ');
    }

    // 0. Resolve shortlinks / share redirects (e.g. fb.watch, facebook.com/share/r/, instagram.com/share/)
    final canonicalUrl = await _resolveCanonicalUrl(cleanUrl);
    final targetUrl = canonicalUrl.isNotEmpty ? canonicalUrl : cleanUrl;

    debugPrint('[DualCloudExtractor] 🚀 Starting Parallel Race for: $targetUrl (Original: $cleanUrl)');

    // Build the master parallel racers list
    final List<Future<DualExtractionResult?>> masterRacers = [
      _tryLocalServerProxy(targetUrl),
      _trySaveTubeDirect(targetUrl),
      _tryTikWMDirect(targetUrl),
      _tryInstagramSaveClip(targetUrl),
      _tryInstagramFastDL(targetUrl),
      _tryInstagramSaveIG(targetUrl),
      _tryInstagramEmbed(targetUrl),
      _tryInstagramGraphQL(targetUrl),
      _tryFacebookSnapSave(targetUrl),
      _tryFacebookFDown(targetUrl),
      _tryFacebookFBDownloader(targetUrl),
      _tryFacebookGetFVid(targetUrl),
      _tryFacebookMobileHTML(targetUrl),
      _tryInvidiousDirect(targetUrl),
      _tryPipedDirect(targetUrl),
      _tryYt1s(targetUrl),
      _tryY2Mate(targetUrl),
      _tryLoaderTo(targetUrl),
      _tryPrimaryRailway(targetUrl),
    ];

    if (cleanUrl != targetUrl) {
      masterRacers.add(_tryLocalServerProxy(cleanUrl));
      masterRacers.add(_tryFacebookSnapSave(cleanUrl));
      masterRacers.add(_tryInstagramSaveClip(cleanUrl));
    }

    // Add Cobalt pool
    for (final host in cobaltInstances) {
      masterRacers.add(_tryCobaltV10Instance(targetUrl, host));
      if (cleanUrl != targetUrl) {
        masterRacers.add(_tryCobaltV10Instance(cleanUrl, host));
      }
    }

    try {
      final winner = await _raceFirstSuccessful(masterRacers, timeout: const Duration(seconds: 12));
      if (winner != null && winner.success && winner.directUrl != null && winner.directUrl!.isNotEmpty) {
        debugPrint('[DualCloudExtractor] 🏆 WINNER: ${winner.providerUsed} -> ${winner.directUrl}');
        return winner;
      }
    } catch (e) {
      debugPrint('[DualCloudExtractor] Race exception: $e');
    }

    debugPrint('[DualCloudExtractor] ❌ All extraction servers failed for: $targetUrl');
    return DualExtractionResult.failed(
      errorMessage: 'تعذر استخراج الرابط المباشر من السيرفرات السحابية. يرجى استخدام المتصفح المدمج 🌐 لتشغيله وتحميله.',
    );
  }

  /// Automatically resolves shortlinks & redirects (fb.watch, facebook.com/share, instagram.com/share, etc.)
  static Future<String> _resolveCanonicalUrl(String url) async {
    final lower = url.toLowerCase();
    final isShortLink = lower.contains('fb.watch') ||
        lower.contains('facebook.com/share/') ||
        lower.contains('instagram.com/share/') ||
        lower.contains('vm.tiktok.com') ||
        lower.contains('vt.tiktok.com') ||
        lower.contains('youtu.be/') ||
        lower.contains('t.co/') ||
        lower.contains('bit.ly/');

    if (!isShortLink) return url;

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = false;
      final response = await request.close();

      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null && location.isNotEmpty) {
          debugPrint('[DualCloudExtractor] 🔗 Unshortened redirect: $url -> $location');
          return location;
        }
      }
    } catch (_) {}

    return url;
  }

  /// Races multiple futures and returns the FIRST ONE that resolves to a non-null successful result
  static Future<DualExtractionResult?> _raceFirstSuccessful(
    Iterable<Future<DualExtractionResult?>> futuresList, {
    required Duration timeout,
  }) async {
    final completer = Completer<DualExtractionResult?>();
    final list = futuresList.toList();
    int remaining = list.length;

    if (remaining == 0) return null;

    for (final fut in list) {
      fut.then((res) {
        if (res != null && res.success && res.directUrl != null && res.directUrl!.isNotEmpty) {
          if (!completer.isCompleted) {
            completer.complete(res);
          }
        }
      }).catchError((_) {
        // Ignore single failure in race
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

  /// 1. Local Node/Express Backend Multi-Resolver (/api/extract)
  static Future<DualExtractionResult?> _tryLocalServerProxy(String videoUrl) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('/api/extract').replace(queryParameters: {'url': videoUrl});
      final res = await client.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'HyperPulse-Dart-Engine/4.0',
        },
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is Map && data['success'] == true && data['direct_url'] != null) {
          return DualExtractionResult.successful(
            directUrl: data['direct_url'].toString(),
            title: data['title']?.toString() ?? 'HyperPulse_Media',
            format: data['format']?.toString() ?? 'mp4',
            size: data['size'] is num ? (data['size'] as num).toInt() : 0,
            providerUsed: data['provider']?.toString() ?? 'محرك HyperPulse السحابي المدمج ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 2. Direct SaveTube Engine (YouTube)
  static Future<DualExtractionResult?> _trySaveTubeDirect(String videoUrl) async {
    final client = http.Client();
    final endpoints = [
      'https://cdn51.savetube.me/info',
      'https://cdn35.savetube.me/info',
      'https://cdn54.savetube.me/info',
    ];

    try {
      for (final ep in endpoints) {
        try {
          final uri = Uri.parse(ep).replace(queryParameters: {'url': videoUrl});
          final res = await client.get(
            uri,
            headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
          ).timeout(const Duration(milliseconds: 2800));

          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data is Map && data['data'] != null && data['data']['video_formats'] is List) {
              final formats = data['data']['video_formats'] as List;
              if (formats.isNotEmpty) {
                final first = formats.first;
                final streamUrl = first['url']?.toString();
                if (streamUrl != null && streamUrl.startsWith('http')) {
                  var title = (data['data']['title'] ?? 'YouTube_Video').toString();
                  title = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
                  return DualExtractionResult.successful(
                    directUrl: streamUrl,
                    title: title,
                    format: 'mp4',
                    providerUsed: 'سيرفر SaveTube CDN ⚡',
                  );
                }
              }
            }
          }
        } catch (_) {}
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// 3. Direct TikWM HD Engine (TikTok)
  static Future<DualExtractionResult?> _tryTikWMDirect(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('tiktok.com') && !lower.contains('douyin.com')) return null;

    final client = http.Client();
    try {
      final uri = Uri.parse('https://www.tikwm.com/api/').replace(queryParameters: {
        'url': videoUrl,
        'hd': '1',
      });

      final res = await client.get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Referer': 'https://www.tikwm.com/',
        },
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['code'] == 0 && data['data'] is Map) {
          final d = data['data'] as Map;
          var playUrl = d['play']?.toString() ?? d['hdplay']?.toString();
          if (playUrl != null) {
            if (playUrl.startsWith('/')) playUrl = 'https://www.tikwm.com$playUrl';
            var title = (d['title'] ?? 'TikTok_${DateTime.now().millisecondsSinceEpoch}').toString();
            title = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
            if (title.length > 50) title = title.substring(0, 50);

            return DualExtractionResult.successful(
              directUrl: playUrl,
              title: title,
              format: 'mp4',
              providerUsed: 'محرك TikWM HD (بدون علامة مائية) ⚡',
            );
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 4. Direct Instagram SaveClip Engine
  static Future<DualExtractionResult?> _tryInstagramSaveClip(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('instagram.com')) return null;

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://api.saveclip.app/v1/get'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'url': videoUrl}),
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is Map && data['data'] is List && (data['data'] as List).isNotEmpty) {
          final first = (data['data'] as List).first;
          final streamUrl = first['url'] ?? first['video_url'];
          if (streamUrl != null && streamUrl.toString().startsWith('http')) {
            return DualExtractionResult.successful(
              directUrl: streamUrl.toString(),
              title: 'Instagram_Reel_${DateTime.now().millisecondsSinceEpoch}',
              format: 'mp4',
              providerUsed: 'سيرفر SaveClip Instagram 📸',
            );
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 5. Direct Instagram FastDL Scraper Engine
  static Future<DualExtractionResult?> _tryInstagramFastDL(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('instagram.com')) return null;

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://v3.fastdl.app/api/convert'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: {'q': videoUrl, 't': 'media', 'lang': 'en'},
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final html = utf8.decode(res.bodyBytes);
        final match = RegExp(r'href="([^"]+)"[^>]*title="Download Video"').firstMatch(html) ??
            RegExp(r'href="(https:\/\/[^"]+\.mp4[^"]*)"').firstMatch(html) ??
            RegExp(r'class="btn-download[^"]*"[^>]*href="([^"]+)"').firstMatch(html);

        if (match != null && match.group(1) != null) {
          final directUrl = match.group(1)!.replaceAll('&amp;', '&');
          return DualExtractionResult.successful(
            directUrl: directUrl,
            title: 'Instagram_Media_${DateTime.now().millisecondsSinceEpoch}',
            format: 'mp4',
            providerUsed: 'سيرفر FastDL Instagram ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 5b. Direct Instagram SaveIG Engine
  static Future<DualExtractionResult?> _tryInstagramSaveIG(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('instagram.com')) return null;

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://saveig.app/api/ajaxSearch'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: {'q': videoUrl, 't': 'media', 'lang': 'en'},
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is Map && data['data'] != null) {
          final html = data['data'].toString();
          final match = RegExp(r'href="([^"]+)"[^>]*download').firstMatch(html) ??
              RegExp(r'href="(https:\/\/[^"]+\.mp4[^"]*)"').firstMatch(html);
          if (match != null && match.group(1) != null) {
            return DualExtractionResult.successful(
              directUrl: match.group(1)!.replaceAll('&amp;', '&'),
              title: 'Instagram_Media_${DateTime.now().millisecondsSinceEpoch}',
              format: 'mp4',
              providerUsed: 'سيرفر SaveIG Instagram 📸',
            );
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 5c. Direct Instagram Embed HTML Scraper
  static Future<DualExtractionResult?> _tryInstagramEmbed(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('instagram.com')) return null;

    // Extract shortcode from /p/XYZ/ or /reel/XYZ/ or /reels/XYZ/
    final match = RegExp(r'instagram\.com\/(?:p|reel|reels)\/([A-Za-z0-9_-]+)').firstMatch(videoUrl);
    final shortcode = match?.group(1);
    if (shortcode == null) return null;

    final client = http.Client();
    try {
      final embedUri = Uri.parse('https://www.instagram.com/p/$shortcode/embed/captioned/');
      final res = await client.get(
        embedUri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final body = utf8.decode(res.bodyBytes);
        final videoUrlMatch = RegExp(r'"video_url":"([^"]+)"').firstMatch(body) ??
            RegExp(r'src="(https:\/\/[^"]+\.mp4[^"]*)"').firstMatch(body);
        if (videoUrlMatch != null && videoUrlMatch.group(1) != null) {
          var streamUrl = videoUrlMatch.group(1)!.replaceAll(r'\u0026', '&').replaceAll(r'\/', '/').replaceAll(r'\', '');
          return DualExtractionResult.successful(
            directUrl: streamUrl,
            title: 'Instagram_Reel_${DateTime.now().millisecondsSinceEpoch}',
            format: 'mp4',
            providerUsed: 'مستخرج Instagram Direct Embed ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 5d. Direct Instagram GraphQL Public API
  static Future<DualExtractionResult?> _tryInstagramGraphQL(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('instagram.com')) return null;

    final match = RegExp(r'instagram\.com\/(?:p|reel|reels)\/([A-Za-z0-9_-]+)').firstMatch(videoUrl);
    final shortcode = match?.group(1);
    if (shortcode == null) return null;

    final client = http.Client();
    try {
      final jsonUri = Uri.parse('https://www.instagram.com/graphql/query/?query_hash=b3055c2e470ed3d87ba33cbe268db881&variables=${Uri.encodeComponent('{"shortcode":"$shortcode"}')}');
      final res = await client.get(
        jsonUri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Accept': 'application/json',
        },
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final media = data['data']?['shortcode_media'];
        if (media != null && media['video_url'] != null) {
          return DualExtractionResult.successful(
            directUrl: media['video_url'].toString(),
            title: 'Instagram_Media_${DateTime.now().millisecondsSinceEpoch}',
            format: 'mp4',
            providerUsed: 'شبكة Instagram GraphQL ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 6. Direct Facebook SnapSave Engine
  static Future<DualExtractionResult?> _tryFacebookSnapSave(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('facebook.com') && !lower.contains('fb.watch') && !lower.contains('fb.com')) return null;

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://snapsave.app/action.php?lang=en'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        },
        body: {'url': videoUrl},
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final body = utf8.decode(res.bodyBytes);
        final match = RegExp(r'href=\\"([^\\"]+)\\"[^>]*class=\\"button is-success').firstMatch(body) ??
            RegExp(r'(https?://[^\s"<>\\]+?\.mp4[^\s"<>\\]*)').firstMatch(body);

        if (match != null && match.group(1) != null) {
          final streamUrl = match.group(1)!.replaceAll(r'\', '').replaceAll('&amp;', '&');
          return DualExtractionResult.successful(
            directUrl: streamUrl,
            title: 'Facebook_Video_${DateTime.now().millisecondsSinceEpoch}',
            format: 'mp4',
            providerUsed: 'سيرفر SnapSave Facebook HD ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 7. Direct Facebook FDown Engine
  static Future<DualExtractionResult?> _tryFacebookFDown(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('facebook.com') && !lower.contains('fb.watch') && !lower.contains('fb.com')) return null;

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://fdown.net/download.php'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {'url': videoUrl},
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final body = utf8.decode(res.bodyBytes);
        final hdMatch = RegExp(r'id="hd"[\s\S]*?href="([^"]+)"').firstMatch(body);
        final sdMatch = RegExp(r'id="sd"[\s\S]*?href="([^"]+)"').firstMatch(body);
        final streamUrl = hdMatch?.group(1) ?? sdMatch?.group(1);

        if (streamUrl != null && streamUrl.startsWith('http')) {
          return DualExtractionResult.successful(
            directUrl: streamUrl.replaceAll('&amp;', '&'),
            title: 'Facebook_Video_${DateTime.now().millisecondsSinceEpoch}',
            format: 'mp4',
            providerUsed: 'سيرفر FDown Facebook ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 7b. Direct Facebook FBDownloader Engine
  static Future<DualExtractionResult?> _tryFacebookFBDownloader(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('facebook.com') && !lower.contains('fb.watch') && !lower.contains('fb.com')) return null;

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://fbdownloader.to/api/ajaxSearch'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: {'q': videoUrl, 't': 'media', 'lang': 'en'},
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is Map && data['data'] != null) {
          final html = data['data'].toString();
          final match = RegExp(r'href="([^"]+)"[^>]*class="button[^"]*is-success').firstMatch(html) ??
              RegExp(r'href="(https:\/\/[^"]+\.mp4[^"]*)"').firstMatch(html);
          if (match != null && match.group(1) != null) {
            return DualExtractionResult.successful(
              directUrl: match.group(1)!.replaceAll('&amp;', '&'),
              title: 'Facebook_Video_${DateTime.now().millisecondsSinceEpoch}',
              format: 'mp4',
              providerUsed: 'سيرفر FBDownloader HD ⚡',
            );
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 7c. Direct Facebook GetFVid Engine
  static Future<DualExtractionResult?> _tryFacebookGetFVid(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('facebook.com') && !lower.contains('fb.watch') && !lower.contains('fb.com')) return null;

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('https://www.getfvid.com/downloader'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {'url': videoUrl},
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final html = utf8.decode(res.bodyBytes);
        final hdMatch = RegExp(r'href="([^"]+)"[^>]*class="btn btn-download[^"]*"').firstMatch(html) ??
            RegExp(r'href="(https:\/\/[^"]+\.mp4[^"]*)"').firstMatch(html);
        if (hdMatch != null && hdMatch.group(1) != null) {
          return DualExtractionResult.successful(
            directUrl: hdMatch.group(1)!.replaceAll('&amp;', '&'),
            title: 'Facebook_Video_${DateTime.now().millisecondsSinceEpoch}',
            format: 'mp4',
            providerUsed: 'سيرفر GetFVid Facebook ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 7d. Direct Facebook Mobile HTML Scraper
  static Future<DualExtractionResult?> _tryFacebookMobileHTML(String videoUrl) async {
    final lower = videoUrl.toLowerCase();
    if (!lower.contains('facebook.com') && !lower.contains('fb.watch') && !lower.contains('fb.com')) return null;

    final client = http.Client();
    try {
      var mobileUrl = videoUrl.replaceFirst('www.facebook.com', 'm.facebook.com').replaceFirst('web.facebook.com', 'm.facebook.com');
      final res = await client.get(
        Uri.parse(mobileUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final body = utf8.decode(res.bodyBytes, allowMalformed: true);
        final hdMatch = RegExp(r'"playable_url_quality_hd":"([^"]+)"').firstMatch(body) ??
            RegExp(r'"browser_native_hd_url":"([^"]+)"').firstMatch(body);
        final sdMatch = RegExp(r'"playable_url":"([^"]+)"').firstMatch(body) ??
            RegExp(r'"browser_native_sd_url":"([^"]+)"').firstMatch(body) ??
            RegExp(r'"sd_src":"([^"]+)"').firstMatch(body) ??
            RegExp(r'"hd_src":"([^"]+)"').firstMatch(body);

        var streamUrl = hdMatch?.group(1) ?? sdMatch?.group(1);
        if (streamUrl != null) {
          streamUrl = streamUrl.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&').replaceAll(r'\', '');
          return DualExtractionResult.successful(
            directUrl: streamUrl,
            title: 'Facebook_Video_${DateTime.now().millisecondsSinceEpoch}',
            format: 'mp4',
            providerUsed: 'مستخرج Facebook Native CDN ⚡',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 8. Invidious Rotating Engine
  static Future<DualExtractionResult?> _tryInvidiousDirect(String videoUrl) async {
    final match = RegExp(r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})', caseSensitive: false).firstMatch(videoUrl);
    final videoId = match?.group(1);
    if (videoId == null) return null;

    final instances = [
      'https://inv.tux.pizza',
      'https://invidious.nerdvpn.de',
      'https://yewtu.be',
      'https://iv.melmac.space',
    ];

    final client = http.Client();
    try {
      for (final host in instances) {
        try {
          final res = await client.get(
            Uri.parse('$host/api/v1/videos/$videoId'),
            headers: {'User-Agent': 'Mozilla/5.0'},
          ).timeout(const Duration(milliseconds: 2500));

          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data is Map && data['formatStreams'] is List && (data['formatStreams'] as List).isNotEmpty) {
              final formats = data['formatStreams'] as List;
              final chosen = formats.first;
              if (chosen is Map && chosen['url'] != null) {
                var dUrl = chosen['url'].toString();
                if (dUrl.startsWith('/')) dUrl = '$host$dUrl';
                return DualExtractionResult.successful(
                  directUrl: dUrl,
                  title: (data['title'] ?? 'YouTube_Video').toString(),
                  format: 'mp4',
                  providerUsed: 'شبكة Invidious السحابية ⚡',
                );
              }
            }
          }
        } catch (_) {}
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// 5. Piped API Engine
  static Future<DualExtractionResult?> _tryPipedDirect(String videoUrl) async {
    final match = RegExp(r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})', caseSensitive: false).firstMatch(videoUrl);
    final videoId = match?.group(1);
    if (videoId == null) return null;

    final instances = [
      'https://pipedapi.kavin.rocks',
      'https://api.piped.privacydev.net',
    ];

    final client = http.Client();
    try {
      for (final host in instances) {
        try {
          final res = await client.get(
            Uri.parse('$host/streams/$videoId'),
            headers: {'User-Agent': 'Mozilla/5.0'},
          ).timeout(const Duration(milliseconds: 2500));

          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data is Map && data['videoStreams'] is List && (data['videoStreams'] as List).isNotEmpty) {
              final streams = data['videoStreams'] as List;
              for (final s in streams) {
                if (s is Map && s['url'] != null) {
                  return DualExtractionResult.successful(
                    directUrl: s['url'].toString(),
                    title: (data['title'] ?? 'YouTube_Video').toString(),
                    format: 'mp4',
                    providerUsed: 'شبكة Piped Streams ⚡',
                  );
                }
              }
            }
          }
        } catch (_) {}
      }
      return null;
    } finally {
      client.close();
    }
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
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
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
    } catch (_) {
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

          String? kToken;
          if (links['mp4'] is Map) {
            final mp4Map = links['mp4'] as Map;
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
    } catch (_) {
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
    } catch (_) {
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
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
      ).timeout(quickTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['success'] == true && data['id'] != null) {
          final id = data['id'].toString();
          for (int i = 0; i < 2; i++) {
            await Future.delayed(const Duration(milliseconds: 800));
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
    } catch (_) {
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
          'User-Agent': 'HyperPulse-Rocket-Engine/4.0',
        },
      ).timeout(const Duration(milliseconds: 2500));

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
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}
