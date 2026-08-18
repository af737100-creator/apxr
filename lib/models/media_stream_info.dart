/// Represents media metadata extracted from streaming platforms (YouTube, TikTok, Instagram, etc.)
class MediaStreamInfo {
  final String title;
  final String directDownloadUrl;
  final String format;
  final String? resolution;
  final int? estimatedSizeBytes;
  final String? thumbnailUrl;
  final String? sourcePlatform;
  final bool isDirectFile;
  final Map<String, dynamic> extraAttributes;

  const MediaStreamInfo({
    required this.title,
    required this.directDownloadUrl,
    required this.format,
    this.resolution,
    this.estimatedSizeBytes,
    this.thumbnailUrl,
    this.sourcePlatform,
    this.isDirectFile = false,
    this.extraAttributes = const {},
  });

  @override
  String toString() {
    return 'MediaStreamInfo(title: $title, platform: $sourcePlatform, format: $format, directUrl: $directDownloadUrl)';
  }
}
