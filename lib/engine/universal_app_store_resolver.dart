import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

/// Represents the resolved download details from any store or webpage
class ResolvedStoreDownload {
  final String directDownloadUrl;
  final String cleanFileName;
  final String fileExtension;
  final int? estimatedSizeBytes;
  final String? storeName;
  final bool isDirectApk;

  const ResolvedStoreDownload({
    required this.directDownloadUrl,
    required this.cleanFileName,
    required this.fileExtension,
    this.estimatedSizeBytes,
    this.storeName,
    this.isDirectApk = true,
  });
}

/// [UniversalAppStoreResolver] intelligently resolves authentic APK download links
/// and cleans application filenames from Uptodown, APKPure, MediaFire, APKMirror,
/// Aptoide, GitHub, SourceForge, and all standard web download sources.
class UniversalAppStoreResolver {
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// Cleans titles containing store wrapper text like:
  /// "تحميل Telegram 11.14.0 من أجل Android (مجانًا)" -> "Telegram_11.14.0.apk"
  static String cleanAppTitle(String rawTitle, {String defaultExt = 'apk'}) {
    var title = rawTitle.trim();

    // 1. Remove unwanted HTML entities
    title = title
        .replaceAll('&quot;', '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '')
        .replaceAll('&gt;', '')
        .replaceAll('&#39;', "'");

    // 2. Strip common Arabic & English store prefixes
    final prefixPatterns = [
      RegExp(r'^تحميل\s+', caseSensitive: false),
      RegExp(r'^تنزيل\s+', caseSensitive: false),
      RegExp(r'^تثبيت\s+', caseSensitive: false),
      RegExp(r'^Download\s+', caseSensitive: false),
      RegExp(r'^Get\s+', caseSensitive: false),
      RegExp(r'^Install\s+', caseSensitive: false),
    ];
    for (final pattern in prefixPatterns) {
      title = title.replaceAll(pattern, '');
    }

    // 3. Strip common store suffixes
    final suffixPatterns = [
      RegExp(r'\s*من أجل\s+Android.*$', caseSensitive: false),
      RegExp(r'\s*لأجهزة\s+Android.*$', caseSensitive: false),
      RegExp(r'\s*لـ\s+Android.*$', caseSensitive: false),
      RegExp(r'\s*for\s+Android.*$', caseSensitive: false),
      RegExp(r'\s*\(مجانًا\)', caseSensitive: false),
      RegExp(r'\s*\(مجاناً\)', caseSensitive: false),
      RegExp(r'\s*\(Free\)', caseSensitive: false),
      RegExp(r'\s*-\s*APK.*$', caseSensitive: false),
      RegExp(r'\s*\|\s*Uptodown.*$', caseSensitive: false),
      RegExp(r'\s*\|\s*APKPure.*$', caseSensitive: false),
      RegExp(r'\s*-\s*APKPure.*$', caseSensitive: false),
      RegExp(r'\s*-\s*Uptodown.*$', caseSensitive: false),
      RegExp(r'\s*-\s*APKMirror.*$', caseSensitive: false),
      RegExp(r'\s*APK\s+Download.*$', caseSensitive: false),
    ];
    for (final pattern in suffixPatterns) {
      title = title.replaceAll(pattern, '');
    }

    title = title.trim();

    // 4. Remove unwanted punctuation from start/end
    while (title.endsWith('.') || title.endsWith('-') || title.endsWith('_') || title.endsWith('|')) {
      title = title.substring(0, title.length - 1).trim();
    }

    // 5. If title ends with .bin, remove it!
    if (title.toLowerCase().endsWith('.bin')) {
      title = title.substring(0, title.length - 4).trim();
    }

    // 6. Normalize internal whitespace to underscores for filesystem safety
    title = title.replaceAll(RegExp(r'\s+'), '_');

    if (title.isEmpty) {
      title = 'App_${DateTime.now().millisecondsSinceEpoch}';
    }

    // 7. Ensure proper extension (never .bin)
    final lower = title.toLowerCase();
    if (!lower.endsWith('.apk') && !lower.endsWith('.xapk') && !lower.endsWith('.zip') && !lower.endsWith('.apks')) {
      title = '$title.$defaultExt';
    }

    return title;
  }

  /// Checks if URL belongs to a known app store or file hosting service
  static bool isStoreOrHostingPage(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      final host = uri.host.toLowerCase();
      final path = uri.path.toLowerCase();

      return host.contains('uptodown.com') ||
          host.contains('apkpure.com') ||
          host.contains('apkpure.net') ||
          host.contains('apkmirror.com') ||
          host.contains('mediafire.com') ||
          host.contains('aptoide.com') ||
          host.contains('apkcombo.com') ||
          host.contains('softonic.com') ||
          host.contains('malavida.com') ||
          host.contains('f-droid.org') ||
          (host.contains('github.com') && path.contains('/releases'));
    } catch (_) {
      return false;
    }
  }

  /// Attempts to resolve an authentic direct download URL from any app store or download page
  static Future<ResolvedStoreDownload?> resolveStoreUrl(String targetUrl, {String? pageTitle}) async {
    try {
      final uri = Uri.parse(targetUrl);
      final host = uri.host.toLowerCase();

      // 1. Direct CDN link already:
      if (host.contains('dw.uptodown.com') ||
          host.contains('d.apkpure.net') ||
          host.contains('download.apkpure.com') ||
          host.contains('download.mediafire.com') ||
          targetUrl.toLowerCase().endsWith('.apk') ||
          targetUrl.toLowerCase().endsWith('.xapk')) {
        final cleanName = cleanAppTitle(pageTitle ?? uri.pathSegments.lastOrNull ?? 'App.apk');
        return ResolvedStoreDownload(
          directDownloadUrl: targetUrl,
          cleanFileName: cleanName,
          fileExtension: cleanName.split('.').last,
          isDirectApk: true,
        );
      }

      // 2. Fetch page HTML to extract direct target
      final client = http.Client();
      try {
        final response = await client
            .get(
              uri,
              headers: {
                'User-Agent': _defaultUserAgent,
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.9,ar;q=0.8',
              },
            )
            .timeout(const Duration(seconds: 8));

        if (response.statusCode != 200 || response.body.isEmpty) {
          return null;
        }

        final document = html_parser.parse(response.body);
        final title = pageTitle ?? document.querySelector('title')?.text ?? 'App.apk';
        final cleanName = cleanAppTitle(title);

        // A. Uptodown Extraction
        if (host.contains('uptodown.com')) {
          // Check #detail-download-button or data-url
          final dlBtn = document.querySelector('#detail-download-button, button[data-url], a[data-url]');
          final dataUrl = dlBtn?.attributes['data-url'];
          if (dataUrl != null && dataUrl.startsWith('http')) {
            return ResolvedStoreDownload(
              directDownloadUrl: dataUrl,
              cleanFileName: cleanName,
              fileExtension: 'apk',
              storeName: 'Uptodown',
            );
          }

          // Check post-download CDN link
          final cdnLink = document.querySelector('a[href*="dw.uptodown.com"], a[href*="/dwn/"]');
          final href = cdnLink?.attributes['href'];
          if (href != null && href.startsWith('http')) {
            return ResolvedStoreDownload(
              directDownloadUrl: href,
              cleanFileName: cleanName,
              fileExtension: 'apk',
              storeName: 'Uptodown',
            );
          }
        }

        // B. APKPure Extraction
        if (host.contains('apkpure.com') || host.contains('apkpure.net')) {
          final apkBtn = document.querySelector('#download_link, a[href*="/b/APK/"], a[href*="/b/XAPK/"], a[href*="d.apkpure.net"]');
          final href = apkBtn?.attributes['href'];
          if (href != null && href.isNotEmpty) {
            final absoluteUrl = Uri.parse(targetUrl).resolve(href).toString();
            final isXapk = href.contains('/XAPK/') || href.contains('.xapk');
            return ResolvedStoreDownload(
              directDownloadUrl: absoluteUrl,
              cleanFileName: cleanAppTitle(title, defaultExt: isXapk ? 'xapk' : 'apk'),
              fileExtension: isXapk ? 'xapk' : 'apk',
              storeName: 'APKPure',
            );
          }
        }

        // C. MediaFire Extraction
        if (host.contains('mediafire.com')) {
          final mfBtn = document.querySelector('#downloadButton, a[aria-label="Download file"], .download_link a');
          final href = mfBtn?.attributes['href'];
          if (href != null && href.startsWith('http')) {
            final ext = href.split('.').last.split('?').first.toLowerCase();
            return ResolvedStoreDownload(
              directDownloadUrl: href,
              cleanFileName: cleanAppTitle(title, defaultExt: ext.isNotEmpty ? ext : 'apk'),
              fileExtension: ext.isNotEmpty ? ext : 'apk',
              storeName: 'MediaFire',
            );
          }
        }

        // D. Generic Store / Web Page Fallback
        final anyApkAnchor = document.querySelector('a[href*=".apk"], a[href*=".xapk"], a[href*=".zip"]');
        final anyHref = anyApkAnchor?.attributes['href'];
        if (anyHref != null && anyHref.isNotEmpty) {
          final absoluteUrl = Uri.parse(targetUrl).resolve(anyHref).toString();
          final ext = absoluteUrl.split('.').last.split('?').first.toLowerCase();
          return ResolvedStoreDownload(
            directDownloadUrl: absoluteUrl,
            cleanFileName: cleanAppTitle(title, defaultExt: ext.isNotEmpty ? ext : 'apk'),
            fileExtension: ext.isNotEmpty ? ext : 'apk',
            storeName: 'Universal Web',
          );
        }
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[UniversalAppStoreResolver] Resolution notice: $e');
    }

    return null;
  }
}
