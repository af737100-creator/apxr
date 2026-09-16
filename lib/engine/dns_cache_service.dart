import 'dart:io';
import 'package:flutter/foundation.dart';

/// [DnsCacheService] provides a high-speed in-memory DNS lookup cache with TTL
/// to eliminate redundant DNS roundtrips across social media platforms.
class DnsCacheService {
  static final Map<String, _DnsCacheEntry> _cache = {};
  static const Duration _defaultTtl = Duration(minutes: 5);

  /// Resolves a host to InternetAddress list, consulting the in-memory cache first
  static Future<List<InternetAddress>> lookup(String host, {Duration? ttl}) async {
    final cleanHost = host.trim().toLowerCase();
    final now = DateTime.now();
    final entry = _cache[cleanHost];

    if (entry != null && now.isBefore(entry.expiresAt)) {
      return entry.addresses;
    }

    try {
      final addresses = await InternetAddress.lookup(cleanHost);
      _cache[cleanHost] = _DnsCacheEntry(
        addresses: addresses,
        expiresAt: now.add(ttl ?? _defaultTtl),
      );
      return addresses;
    } catch (e) {
      // If live lookup fails but we have an expired cache entry, use it as graceful fallback
      if (entry != null && entry.addresses.isNotEmpty) {
        debugPrint('[DnsCacheService] ⚠️ Lookup failed for $cleanHost, using stale cache');
        return entry.addresses;
      }
      rethrow;
    }
  }

  /// Manually prime cache with known IP mapping
  static void set(String host, List<InternetAddress> addresses, {Duration? ttl}) {
    _cache[host.trim().toLowerCase()] = _DnsCacheEntry(
      addresses: addresses,
      expiresAt: DateTime.now().add(ttl ?? _defaultTtl),
    );
  }

  /// Clears the DNS cache
  static void clear() {
    _cache.clear();
  }
}

class _DnsCacheEntry {
  final List<InternetAddress> addresses;
  final DateTime expiresAt;

  _DnsCacheEntry({
    required this.addresses,
    required this.expiresAt,
  });
}
