import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Innertube client context profile
class InnertubeClient {
  final String name;
  final String version;
  final String userAgent;
  final int clientId;
  final String? androidSdk;
  final String? deviceMake;
  final String? deviceModel;
  final String? osName;
  final String? osVersion;
  final String apiKey;

  const InnertubeClient({
    required this.name,
    required this.version,
    required this.userAgent,
    required this.clientId,
    required this.apiKey,
    this.androidSdk,
    this.deviceMake,
    this.deviceModel,
    this.osName,
    this.osVersion,
  });

  /// High-reliability ANDROID_VR client (Oculus Quest 3) - bypasses bot checks without PO token
  static const androidVr = InnertubeClient(
    name: 'ANDROID_VR',
    version: '1.60.19',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12; GB) gzip',
    clientId: 28,
    apiKey: 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
    androidSdk: '32',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    osName: 'Android',
    osVersion: '12',
  );

  /// Native iOS client context profile
  static const ios = InnertubeClient(
    name: 'IOS',
    version: '19.09.3',
    userAgent: 'com.google.ios.youtube/19.09.3 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X)',
    clientId: 5,
    apiKey: 'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
    deviceMake: 'Apple',
    deviceModel: 'iPhone16,2',
    osName: 'iPhone',
    osVersion: '17.5.1.21F90',
  );
}

/// Extracted stream model
class InnertubeStream {
  final String url;
  final int itag;
  final String mimeType;
  final int bitrate;
  final int? contentLength;
  final bool isVideo;
  final bool isAudio;
  final bool hasAudio;
  final String? qualityLabel;
  final int? height;
  final String? audioQuality;

  InnertubeStream({
    required this.url,
    required this.itag,
    required this.mimeType,
    required this.bitrate,
    this.contentLength,
    required this.isVideo,
    required this.isAudio,
    required this.hasAudio,
    this.qualityLabel,
    this.height,
    this.audioQuality,
  });

  bool get isMp4 => mimeType.contains('mp4');
  bool get isWebm => mimeType.contains('webm');
}

/// Result returned from Innertube extraction
class InnertubeResult {
  final bool success;
  final String videoId;
  final String title;
  final int duration;
  final String? thumbnail;
  final List<InnertubeStream> streams;
  final String? error;
  final Duration elapsed;

  InnertubeResult({
    required this.success,
    this.videoId = '',
    this.title = '',
    this.duration = 0,
    this.thumbnail,
    this.streams = const [],
    this.error,
    required this.elapsed,
  });

  bool get hasStreams => streams.isNotEmpty;

  /// Returns the highest quality progressive MP4 stream (audio + video muxed together)
  InnertubeStream? get bestProgressive {
    final list = streams
        .where((s) => s.isVideo && s.hasAudio && s.isMp4)
        .toList()
      ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    return list.isEmpty ? null : list.first;
  }

  /// Best video-only stream
  InnertubeStream? get bestVideoOnly {
    final list = streams
        .where((s) => s.isVideo && !s.hasAudio && s.isMp4)
        .toList()
      ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    return list.isEmpty ? null : list.first;
  }

  /// Best audio stream
  InnertubeStream? get bestAudio {
    final list = streams.where((s) => s.isAudio && !s.isVideo).toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return list.isEmpty ? null : list.first;
  }
}

/// High-speed Innertube extractor directly querying YouTube's internal player API
class InnertubeExtractor {
  final Dio _dio;

  InnertubeExtractor({Dio? customDio})
      : _dio = customDio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 4),
              receiveTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 4),
            ));

  /// Extract video streams with automatic failover across client profiles
  Future<InnertubeResult> extract(String videoId) async {
    final sw = Stopwatch()..start();

    // 1. Try ANDROID_VR (Oculus Quest) first - fastest & cleanest responses
    final vr = await _extractWithClient(videoId, InnertubeClient.androidVr, sw);
    if (vr.success && vr.hasStreams) {
      debugPrint('[InnertubeExtractor] ⚡ نجح استخراج VR في ${vr.elapsed.inMilliseconds}ms');
      return vr;
    }

    // 2. Try iOS client as fallback
    final ios = await _extractWithClient(videoId, InnertubeClient.ios, sw);
    if (ios.success && ios.hasStreams) {
      debugPrint('[InnertubeExtractor] ⚡ نجح استخراج iOS في ${ios.elapsed.inMilliseconds}ms');
      return ios;
    }

    return InnertubeResult(
      success: false,
      videoId: videoId,
      error: vr.error ?? ios.error ?? 'فشل استخراج الفيديو عبر بروتوكول Innertube',
      elapsed: sw.elapsed,
    );
  }

  Future<InnertubeResult> _extractWithClient(
    String videoId,
    InnertubeClient client,
    Stopwatch sw,
  ) async {
    try {
      final url = 'https://www.youtube.com/youtubei/v1/player?key=${client.apiKey}';

      final body = {
        'context': {
          'client': {
            'clientName': client.name,
            'clientVersion': client.version,
            'androidSdkVersion': client.androidSdk != null
                ? int.tryParse(client.androidSdk!)
                : null,
            'deviceMake': client.deviceMake,
            'deviceModel': client.deviceModel,
            'osName': client.osName,
            'osVersion': client.osVersion,
            'hl': 'ar',
            'gl': 'US',
            'utcOffsetMinutes': 0,
          },
        },
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      };

      final response = await _dio.post(
        url,
        data: body,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': client.userAgent,
            'X-Youtube-Client-Name': client.clientId.toString(),
            'X-Youtube-Client-Version': client.version,
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (response.statusCode != 200 || response.data == null) {
        return InnertubeResult(
          success: false,
          videoId: videoId,
          error: 'HTTP ${response.statusCode}',
          elapsed: sw.elapsed,
        );
      }

      final Map<String, dynamic> data;
      if (response.data is Map<String, dynamic>) {
        data = response.data as Map<String, dynamic>;
      } else if (response.data is String) {
        data = jsonDecode(response.data as String) as Map<String, dynamic>;
      } else {
        return InnertubeResult(
          success: false,
          videoId: videoId,
          error: 'استجابة غير متوقعة',
          elapsed: sw.elapsed,
        );
      }

      return _parseResponse(data, videoId, sw);
    } catch (e) {
      return InnertubeResult(
        success: false,
        videoId: videoId,
        error: e.toString(),
        elapsed: sw.elapsed,
      );
    }
  }

  InnertubeResult _parseResponse(
    Map<String, dynamic> data,
    String videoId,
    Stopwatch sw,
  ) {
    final status = data['playabilityStatus']?['status']?.toString() ?? '';
    if (status != 'OK') {
      final reason = data['playabilityStatus']?['reason'] ?? 'الفيديو غير متاح للتشغيل';
      return InnertubeResult(
        success: false,
        videoId: videoId,
        error: reason.toString(),
        elapsed: sw.elapsed,
      );
    }

    final videoDetails = data['videoDetails'] as Map<String, dynamic>? ?? {};
    final title = (videoDetails['title']?.toString() ?? 'YouTube_Video')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final duration = int.tryParse(videoDetails['lengthSeconds']?.toString() ?? '0') ?? 0;
    final thumbnail = (videoDetails['thumbnail']?['thumbnails'] as List?)
        ?.last?['url']
        ?.toString();

    final streamingData = data['streamingData'] as Map<String, dynamic>? ?? {};
    final formats = (streamingData['formats'] as List?) ?? [];
    final adaptiveFormats = (streamingData['adaptiveFormats'] as List?) ?? [];

    final streams = <InnertubeStream>[];

    for (final f in formats) {
      if (f is Map<String, dynamic>) {
        final stream = _parseFormat(f, hasAudio: true);
        if (stream != null) streams.add(stream);
      }
    }

    for (final f in adaptiveFormats) {
      if (f is Map<String, dynamic>) {
        final stream = _parseFormat(f, hasAudio: false);
        if (stream != null) streams.add(stream);
      }
    }

    if (streams.isEmpty) {
      return InnertubeResult(
        success: false,
        videoId: videoId,
        error: 'لم يتم العثور على روابط وسائط قابلة للتشغيل المباشر',
        elapsed: sw.elapsed,
      );
    }

    return InnertubeResult(
      success: true,
      videoId: videoId,
      title: title,
      duration: duration,
      thumbnail: thumbnail,
      streams: streams,
      elapsed: sw.elapsed,
    );
  }

  InnertubeStream? _parseFormat(Map<String, dynamic> format, {required bool hasAudio}) {
    final url = format['url']?.toString();
    if (url == null || url.isEmpty) return null;

    final itag = format['itag'] as int? ?? 0;
    final mimeType = format['mimeType']?.toString() ?? '';
    final bitrate = format['bitrate'] as int? ?? 0;
    final contentLength = int.tryParse(format['contentLength']?.toString() ?? '');
    final height = format['height'] as int?;
    final qualityLabel = format['qualityLabel']?.toString();

    final isVideo = mimeType.contains('video/');
    final isAudio = mimeType.contains('audio/');

    return InnertubeStream(
      url: url,
      itag: itag,
      mimeType: mimeType,
      bitrate: bitrate,
      contentLength: contentLength,
      isVideo: isVideo,
      isAudio: isAudio,
      hasAudio: hasAudio,
      qualityLabel: qualityLabel,
      height: height,
      audioQuality: format['audioQuality']?.toString(),
    );
  }
}

/// Helper function to extract YouTube video ID from any standard URL
String? extractYouTubeVideoId(String url) {
  final regExp = RegExp(
    r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})',
    caseSensitive: false,
  );
  return regExp.firstMatch(url)?.group(1);
}
