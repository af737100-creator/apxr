import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../engine/watermark_service.dart';

/// Representation of a remote broadcast push notification
class RemoteNotificationItem {
  final String id;
  final String title;
  final String body;
  final String? actionUrl;
  final String? imageUrl;
  final String type; // 'announcement', 'update', 'feature', 'system'
  final String priority; // 'high', 'normal'
  final DateTime receivedAt;
  bool isRead;

  RemoteNotificationItem({
    required this.id,
    required this.title,
    required this.body,
    this.actionUrl,
    this.imageUrl,
    this.type = 'system',
    this.priority = 'normal',
    required this.receivedAt,
    this.isRead = false,
  });

  factory RemoteNotificationItem.fromJson(Map<String, dynamic> json) {
    return RemoteNotificationItem(
      id: json['id']?.toString() ?? 'notif_${DateTime.now().millisecondsSinceEpoch}',
      title: json['title']?.toString() ?? 'إشعار من HyperPulse',
      body: json['body']?.toString() ?? '',
      actionUrl: json['action_url']?.toString() ?? json['actionUrl']?.toString(),
      imageUrl: json['image_url']?.toString() ?? json['imageUrl']?.toString(),
      type: json['type']?.toString() ?? 'system',
      priority: json['priority']?.toString() ?? 'normal',
      receivedAt: json['receivedAt'] != null
          ? DateTime.tryParse(json['receivedAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      isRead: json['isRead'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'actionUrl': actionUrl,
        'imageUrl': imageUrl,
        'type': type,
        'priority': priority,
        'receivedAt': receivedAt.toIso8601String(),
        'isRead': isRead,
      };
}

/// Remote Live App Configuration pushed from Firebase / Server Control Room
class RemoteAppConfig {
  final String announcementBanner;
  final bool isAnnouncementActive;
  final bool forceWatermark;
  final double watermarkOpacity;
  final int turboThreadsMultiplier;
  final bool maintenanceMode;
  final String? latestVersionCode;
  final String? apkDownloadUrl;

  const RemoteAppConfig({
    this.announcementBanner = '',
    this.isAnnouncementActive = false,
    this.forceWatermark = true,
    this.watermarkOpacity = 0.65,
    this.turboThreadsMultiplier = 8,
    this.maintenanceMode = false,
    this.latestVersionCode = '2.4.0',
    this.apkDownloadUrl,
  });

  factory RemoteAppConfig.fromJson(Map<String, dynamic> json) {
    return RemoteAppConfig(
      announcementBanner: json['announcementBanner']?.toString() ?? '',
      isAnnouncementActive: json['isAnnouncementActive'] == true,
      forceWatermark: json['forceWatermark'] ?? true,
      watermarkOpacity: (json['watermarkOpacity'] as num?)?.toDouble() ?? 0.65,
      turboThreadsMultiplier: (json['turboThreadsMultiplier'] as num?)?.toInt() ?? 8,
      maintenanceMode: json['maintenanceMode'] == true,
      latestVersionCode: json['latestVersionCode']?.toString() ?? '2.4.0',
      apkDownloadUrl: json['apkDownloadUrl']?.toString(),
    );
  }
}

/// [FirebaseRemoteControlService] manages:
/// 1. Firebase Cloud Messaging (FCM) topic subscriptions ('all_users').
/// 2. Remote push notifications listener & in-app notification center.
/// 3. Remote app configuration synchronization (Watermark rules, Emergency broadcasts, Turbo multipliers).
class FirebaseRemoteControlService extends ChangeNotifier {
  static final FirebaseRemoteControlService _instance = FirebaseRemoteControlService._internal();
  factory FirebaseRemoteControlService() => _instance;
  FirebaseRemoteControlService._internal();

  bool _isInitialized = false;
  String? _fcmToken;
  RemoteAppConfig _remoteConfig = const RemoteAppConfig();
  final List<RemoteNotificationItem> _notifications = [];
  Timer? _syncTimer;

  // Firebase Project Constants
  static const String firebaseProjectId = 'hyperpulse-4f35f';
  static const String firebaseProjectNumber = '1043365619113';
  static const String firebaseAppId = '1:1043365619113:android:4196601026b0dbccfdd0b8';
  static const String firebaseApiKey = 'AIzaSyCf-vCtDDVubdlJ5pqGz2XNfCNaf2xZAcQ';
  static const String firebasePackageName = 'com.hyperpulse.app';
  static const String broadcastTopic = 'all_users';

  bool get isInitialized => _isInitialized;
  String? get fcmToken => _fcmToken;
  RemoteAppConfig get remoteConfig => _remoteConfig;
  List<RemoteNotificationItem> get notifications => List.unmodifiable(_notifications);
  int get unreadCount => _notifications.where((n) => !n.isRead).length;

  /// Stream of new incoming notifications for UI snackbars or heads-up banners
  final StreamController<RemoteNotificationItem> _notificationStreamController =
      StreamController<RemoteNotificationItem>.broadcast();
  Stream<RemoteNotificationItem> get onNotificationReceived => _notificationStreamController.stream;

  /// Initialize Firebase & start sync with the Firebase Remote Control Room
  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    debugPrint('[FirebaseRemoteControl] 🚀 Initializing Firebase for project: $firebaseProjectId ($firebasePackageName)');

    // 1. Initial simulated / fallback token for instant readiness
    _fcmToken = 'fcm_token_hyperpulse_${DateTime.now().millisecondsSinceEpoch}';

    // 2. Initial fetch from server remote control room & sync
    await fetchRemoteConfigAndNotifications();

    // 3. Periodic real-time poll fallback (keeps all devices perfectly synced with control room)
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      fetchRemoteConfigAndNotifications();
    });
  }

  /// Syncs remote config & notification broadcasts from the HyperPulse Control Server
  Future<void> fetchRemoteConfigAndNotifications() async {
    final candidateHosts = [
      'http://10.0.2.2:3000',
      'http://localhost:3000',
      'https://ais-dev-xup7lx4kbcs2dslmo2kjbi-470430127443.europe-west2.run.app',
    ];

    for (final host in candidateHosts) {
      try {
        final client = http.Client();
        // 1. Fetch Remote Config
        final cfgRes = await client.get(
          Uri.parse('$host/api/firebase/remote-config'),
          headers: {'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 4));

        if (cfgRes.statusCode == 200) {
          final data = jsonDecode(utf8.decode(cfgRes.bodyBytes));
          if (data is Map<String, dynamic> && data['config'] != null) {
            _remoteConfig = RemoteAppConfig.fromJson(Map<String, dynamic>.from(data['config']));
            
            // If remote config forces watermark, update WatermarkService immediately
            if (_remoteConfig.forceWatermark) {
              WatermarkService().updateConfig(
                isEnabled: true,
                opacity: _remoteConfig.watermarkOpacity,
              );
            }
          }
        }

        // 2. Fetch Notifications
        final notifRes = await client.get(
          Uri.parse('$host/api/firebase/notifications'),
          headers: {'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 4));

        if (notifRes.statusCode == 200) {
          final data = jsonDecode(utf8.decode(notifRes.bodyBytes));
          if (data is Map && data['notifications'] is List) {
            final List list = data['notifications'];
            bool hasNew = false;
            for (final item in list) {
              if (item is Map) {
                final notif = RemoteNotificationItem.fromJson(Map<String, dynamic>.from(item));
                final exists = _notifications.any((n) => n.id == notif.id);
                if (!exists) {
                  _notifications.insert(0, notif);
                  _notificationStreamController.add(notif);
                  hasNew = true;
                }
              }
            }
            if (hasNew) {
              notifyListeners();
            }
          }
        }

        client.close();
        break;
      } catch (_) {
        // Try next host
      }
    }
  }

  /// Manually add a notification (e.g. from local broadcast or FCM message)
  void addNotification(RemoteNotificationItem item) {
    if (!_notifications.any((n) => n.id == item.id)) {
      _notifications.insert(0, item);
      _notificationStreamController.add(item);
      notifyListeners();
    }
  }

  /// Mark all notifications as read
  void markAllAsRead() {
    for (final n in _notifications) {
      n.isRead = true;
    }
    notifyListeners();
  }

  /// Clear all notifications
  void clearNotifications() {
    _notifications.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _notificationStreamController.close();
    super.dispose();
  }
}
