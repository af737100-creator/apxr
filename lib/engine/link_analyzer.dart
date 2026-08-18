import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../models/media_stream_info.dart';

/// Result of Link Analyzer inspection.
enum LinkCategory {
  directBinary,
  mediaStreamingPlatform,
  webHtmlPage,
  unknown,
}

/// Abstract contract for media extraction engines (e.g. yt-dlp, FFmpeg, Custom parsers).
abstract class IMediaExtractor {
  Future<bool> canHandle(String url);
  Future<MediaStreamInfo> extractMedia(String url, {String? customCookiesPath});
}

/// Native wrapper that invokes `yt-dlp` executable/binary on Android / Linux / desktop environments.
class YtDlpNativeExtractor implements IMediaExtractor {
  final String ytDlpBinaryPath;
  final String? pythonBinaryPath;

  YtDlpNativeExtractor({
    this.ytDlpBinaryPath = 'yt-dlp',
    this.pythonBinaryPath,
  });

  @override
  Future<bool> canHandle(String url) async {
    final lower = url.toLowerCase();
    final knownDomains = [
      'youtube.com',
      'youtu.be',
      'tiktok.com',
      'instagram.com',
      'twitter.com',
      'x.com',
      'facebook.com',
      'fb.watch',
      'vimeo.com',
      'dailymotion.com',
      'soundcloud.com',
      'bilibili.com',
      'reddit.com',
    ];
    return knownDomains.any((domain) => lower.contains(domain));
  }

  @override
  Future<MediaStreamInfo> extractMedia(String url, {String? customCookiesPath}) async {
    // Arguments to query JSON metadata without downloading the full media file
    final List<String> args = [
      '--dump-single-json',
      '--no-warnings',
      '--no-playlist',
      '--format', 'best[ext=mp4]/best',
      if (customCookiesPath != null) ...['--cookies', customCookiesPath],
      url,
    ];

    try {
      final ProcessResult result = await Process.run(ytDlpBinaryPath, args);

      if (result.exitCode != 0) {
        throw Exception('yt-dlp extraction failed with code ${result.exitCode}: ${result.stderr}');
      }

      final String jsonOutput = result.stdout as String;
      final Map<String, dynamic> metadata = jsonDecode(jsonOutput) as Map<String, dynamic>;

      final String title = metadata['title'] as String? ?? 'Extracted_Media';
      final String directUrl = metadata['url'] as String? ?? '';
      final String ext = metadata['ext'] as String? ?? 'mp4';
      final String? resolution = metadata['resolution'] as String? ?? metadata['format_note'] as String?;
      final int? fileSize = metadata['filesize'] as int? ?? metadata['filesize_approx'] as int?;
      final String? thumbnail = metadata['thumbnail'] as String?;
      final String? extractor = metadata['extractor_key'] as String? ?? metadata['extractor'] as String?;

      if (directUrl.isEmpty) {
        throw Exception('Could not resolve direct streaming URL from yt-dlp payload.');
      }

      return MediaStreamInfo(
        title: title,
        directDownloadUrl: directUrl,
        format: ext,
        resolution: resolution,
        estimatedSizeBytes: fileSize,
        thumbnailUrl: thumbnail,
        sourcePlatform: extractor,
        isDirectFile: false,
        extraAttributes: metadata,
      );
    } catch (e) {
      throw Exception('yt-dlp execution error: $e');
    }
  }
}

/// [LinkAnalyzer] inspects incoming URLs to classify whether they are direct static files
/// or rich web pages requiring stream extraction through [IMediaExtractor] (yt-dlp).
class LinkAnalyzer {
  final Dio _dio;
  final IMediaExtractor _mediaExtractor;

  /// Known direct binary file extensions that bypass media extractors.
  static final Set<String> _directBinaryExtensions = {
    // Archives
    'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso', 'dmg',
    // Executables / Installers
    'apk', 'aab', 'exe', 'msi', 'bin', 'deb', 'rpm', 'appimage',
    // Media direct files
    'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg',
    // Documents & Images
    'pdf', 'docx', 'xlsx', 'pptx', 'epub', 'png', 'jpg', 'jpeg', 'webp', 'gif',
  };

  LinkAnalyzer({
    Dio? customDio,
    IMediaExtractor? mediaExtractor,
  })  : _dio = customDio ?? Dio(),
        _mediaExtractor = mediaExtractor ?? YtDlpNativeExtractor();

  /// Determines if a URL points directly to a known static binary extension.
  bool isDirectBinaryExtension(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.toLowerCase();
      for (final ext in _directBinaryExtensions) {
        if (path.endsWith('.$ext')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Complete analysis pipeline for an input URL:
  /// 1. Checks file extension pattern.
  /// 2. Performs quick HTTP HEAD request to check `Content-Type`.
  /// 3. If streaming page, delegates to yt-dlp extractor.
  Future<MediaStreamInfo> analyzeAndResolve(String url) async {
    final String cleanUrl = url.trim();

    // Fast Path: Direct file extension detected
    if (isDirectBinaryExtension(cleanUrl)) {
      final uri = Uri.parse(cleanUrl);
      final fileName = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download_file';
      final ext = fileName.contains('.') ? fileName.split('.').last : 'bin';

      return MediaStreamInfo(
        title: fileName,
        directDownloadUrl: cleanUrl,
        format: ext,
        isDirectFile: true,
        sourcePlatform: 'Direct Link',
      );
    }

    // Check if URL matches a known streaming media platform (YouTube, TikTok, etc.)
    if (await _mediaExtractor.canHandle(cleanUrl)) {
      return await _mediaExtractor.extractMedia(cleanUrl);
    }

    // Probing network Content-Type via HEAD
    try {
      final response = await _dio.head(
        cleanUrl,
        options: Options(followRedirects: true),
      );

      final contentType = response.headers.value('content-type')?.toLowerCase() ?? '';

      // If server returns application/octet-stream, video/*, audio/*, it's a direct download
      if (contentType.startsWith('video/') ||
          contentType.startsWith('audio/') ||
          contentType.startsWith('application/octet-stream') ||
          contentType.startsWith('application/zip') ||
          contentType.startsWith('application/vnd.android.package-archive')) {
        final uri = Uri.parse(cleanUrl);
        return MediaStreamInfo(
          title: uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'downloaded_asset',
          directDownloadUrl: cleanUrl,
          format: contentType.split('/').last,
          isDirectFile: true,
          sourcePlatform: 'Direct HTTP Stream',
        );
      }
    } catch (_) {
      // If HEAD fails, proceed to attempt media extractor fallback
    }

    // Fallback: Attempt yt-dlp extraction as a generic web parser
    try {
      return await _mediaExtractor.extractMedia(cleanUrl);
    } catch (e) {
      // If all fails, treat as generic direct URL
      final uri = Uri.parse(cleanUrl);
      return MediaStreamInfo(
        title: uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download',
        directDownloadUrl: cleanUrl,
        format: 'bin',
        isDirectFile: true,
        sourcePlatform: 'Generic URL',
      );
    }
  }
}
