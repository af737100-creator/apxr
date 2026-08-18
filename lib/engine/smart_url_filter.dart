import 'dart:core';

/// [SmartUrlFilter] provides deep inspection, heuristics, and domain-level sanitization
/// to block scam links, fake download buttons, ad networks, tracking telemetry, and malicious redirects.
class SmartUrlFilter {
  // Blacklisted ad networks, telemetry trackers, and click-hijacking hosts
  static const Set<String> adAndTrackerKeywords = {
    'ads',
    'adservice',
    'doubleclick',
    'googleadservices',
    'googlesyndication',
    'tracking',
    'analytics',
    'popunder',
    'popads',
    'adsterra',
    'propellerads',
    'clickadu',
    'trafficjunky',
    'affiliate',
    'adclick',
    'adnxs',
    'taboola',
    'outbrain',
    'pagead2',
    'adcolony',
    'unityads',
    'applovin',
    'ironsource',
    'redirector',
    'safe-link',
    'linkvertise',
    'ouo.io',
    'shrinkme',
  };

  // Blacklisted query parameters often used by ad trackers
  static const Set<String> suspiciousQueryParams = {
    'utm_source',
    'utm_medium',
    'utm_campaign',
    'gclid',
    'fbclid',
    'aff_id',
    'ref_id',
    'click_id',
  };

  // Common direct binary & media file extensions
  static const Set<String> downloadableExtensions = {
    'apk', 'zip', 'rar', '7z', 'tar', 'gz', 'iso', 'dmg',
    'mp4', 'mkv', 'webm', 'mov', 'avi', 'flv', '3gp',
    'mp3', 'm4a', 'flac', 'wav', 'aac', 'ogg',
    'pdf', 'epub', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
    'exe', 'msi', 'bin', 'deb', 'rpm', 'jar',
  };

  /// Checks whether a given URL is clean and safe to download (not an ad/tracker).
  static bool isCleanAndSafe(String rawUrl) {
    if (rawUrl.trim().isEmpty) return false;

    try {
      final uri = Uri.parse(rawUrl.trim());
      if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return false;
      }

      final host = uri.host.toLowerCase();
      final fullPath = uri.toString().toLowerCase();

      // 1. Check against blacklist keywords in hostname or path
      for (final keyword in adAndTrackerKeywords) {
        if (host.contains(keyword) || uri.path.toLowerCase().contains('/$keyword/')) {
          return false;
        }
      }

      // 2. Reject javascript:, data:, or blob: URLs
      if (uri.scheme == 'javascript' || uri.scheme == 'data') {
        return false;
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  /// Extracts the real download target from cloaked redirect query parameters
  /// e.g. https://domain.com/download?url=https://real-file.com/app.apk
  static String extractRealTargetUrl(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl.trim());
      for (final param in ['url', 'target', 'download', 'file', 'link', 'dest', 'redirect', 'r']) {
        final candidate = uri.queryParameters[param];
        if (candidate != null && candidate.isNotEmpty) {
          final decoded = Uri.decodeFull(candidate);
          if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
            if (isCleanAndSafe(decoded)) {
              return decoded;
            }
          }
        }
      }
    } catch (_) {}
    return rawUrl;
  }

  /// Determines if a URL directly targets a downloadable file based on extension.
  static bool isDownloadableFileUrl(String rawUrl) {
    try {
      final cleanUrl = extractRealTargetUrl(rawUrl);
      final uri = Uri.parse(cleanUrl);
      final path = uri.path.toLowerCase();

      // Check file extension
      final lastSegment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last.toLowerCase() : '';
      if (lastSegment.contains('.')) {
        final ext = lastSegment.split('.').last.split('?').first;
        if (downloadableExtensions.contains(ext)) {
          return true;
        }
      }

      // Check if URL ends with known downloadable extension
      for (final ext in downloadableExtensions) {
        if (path.endsWith('.$ext')) return true;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  /// Extracts the inferred file extension from a URL (e.g. "apk", "mp4", "zip").
  static String? inferFileExtension(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      final path = uri.path.toLowerCase();
      for (final ext in downloadableExtensions) {
        if (path.endsWith('.$ext') || path.contains('.$ext?')) {
          return ext;
        }
      }
      if (uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.last;
        if (last.contains('.')) {
          final ext = last.split('.').last.toLowerCase();
          if (downloadableExtensions.contains(ext)) return ext;
        }
      }
    } catch (_) {}
    return null;
  }
}
