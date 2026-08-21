import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:quran_connect/core/services/notification_service.dart';
import 'package:quran_connect/core/supa_config.dart';
import 'package:quran_connect/features/auth/services/auth_service.dart';
import 'package:quran_connect/main.dart' show navigatorKey;
import 'package:supabase_flutter/supabase_flutter.dart';

// Top-level background message handler
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("FCM [Background]: Handling message ${message.messageId}");

  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('FCM [Background]: Firebase init status: $e');
  }

  debugPrint('FCM [Background] title: ${message.notification?.title ?? message.data['title']}');
  debugPrint('FCM [Background] body: ${message.notification?.body ?? message.data['body']}');
}

class FCMService {
  final NotificationService _notificationService = NotificationService();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    // Check if Firebase is initialized
    try {
      Firebase.app();
    } catch (e) {
      debugPrint('FCMService: Firebase not initialized: $e');
      return;
    }

    final firebaseMessaging = FirebaseMessaging.instance;

    // Request full notification permissions (iOS & Android 13+)
    try {
      final settings = await firebaseMessaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );
      debugPrint('FCMService: User granted permission: ${settings.authorizationStatus}');
    } catch (e) {
      debugPrint('FCMService: Error requesting permission: $e');
    }

    // Set background message handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Initial Token Retrieval
    try {
      final token = await firebaseMessaging.getToken();
      if (token != null) {
        debugPrint('FCMService: Token retrieved: $token');
        await _saveTokenToSupabase(token);
      }
    } catch (e) {
      debugPrint('FCMService: Error getting initial token: $e');
    }

    // Listen for Token Refresh
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      debugPrint('FCMService: Token refreshed: $newToken');
      await _saveTokenToSupabase(newToken);
    });

    // Listen for Supabase Auth state changes to sync token on login/restore
    SupaConfig.client.auth.onAuthStateChange.listen((data) async {
      final event = data.event;
      final session = data.session;

      if ((event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.tokenRefreshed ||
          event == AuthChangeEvent.initialSession) &&
          session != null) {
        debugPrint('FCMService: Auth event ($event) for user ${session.user.id}, syncing token...');
        try {
          final currentToken = await FirebaseMessaging.instance.getToken();
          if (currentToken != null) {
            await _saveTokenToSupabase(currentToken, explicitUserId: session.user.id);
          }
        } catch (e) {
          debugPrint('FCMService: Error syncing token on auth change: $e');
        }
      }
    });

    // Foreground Messages Handler
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('FCMService [Foreground]: Message received: ${message.messageId}');
      debugPrint('FCMService [Foreground] data: ${message.data}');

      final notification = message.notification;
      final title = notification?.title ?? message.data['title'] as String? ?? 'عون';
      final body = notification?.body ?? message.data['body'] as String? ?? '';
      final payload = message.data['route'] as String? ??
          message.data['payload'] as String? ??
          message.data['click_action'] as String? ??
          'social';

      if (title.isNotEmpty || body.isNotEmpty) {
        _notificationService.showRemoteNotification(
          title: title,
          body: body,
          payload: payload,
        );
      }
    });

    // Handle App Opened from Terminated State by Notification Tap
    FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        debugPrint('FCMService: App opened from terminated state by notification: ${message.data}');
        _handleNotificationTap(message);
      }
    });

    // Handle App Opened from Background State by Notification Tap
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('FCMService: App opened from background by notification: ${message.data}');
      _handleNotificationTap(message);
    });

    _initialized = true;
    debugPrint('FCMService: Successfully initialized');
  }

  /// Handle navigation when user taps a push notification
  void _handleNotificationTap(RemoteMessage message) {
    try {
      final route = message.data['route'] as String? ??
          message.data['payload'] as String? ??
          'home';

      if (navigatorKey.currentContext == null) return;
      final context = navigatorKey.currentContext!;

      if (route.startsWith('memorization/group/')) {
        final groupId = route.substring('memorization/group/'.length).trim();
        context.go('/memorization/group/$groupId');
      } else if (route.startsWith('memorization/review/')) {
        final groupId = route.substring('memorization/review/'.length).trim();
        context.go('/memorization/review/$groupId');
      } else if (route.contains('memorization')) {
        context.go('/memorization');
      } else if (route.contains('social') || route.contains('friends')) {
        context.go('/social');
      } else if (route.contains('wird')) {
        context.go('/wird');
      } else if (route.contains('athkar')) {
        context.go('/athkar');
      } else {
        context.go('/home');
      }
    } catch (e) {
      debugPrint('FCMService: Error navigating on notification tap: $e');
    }
  }

  /// Saves or updates the FCM token in Supabase `profiles` table
  Future<void> _saveTokenToSupabase(String token, {String? explicitUserId}) async {
    String? userId = explicitUserId;

    if (userId == null) {
      try {
        userId = await AuthService(SupaConfig.client).getEffectiveUserId();
      } catch (_) {
        userId = null;
      }
    }

    if (userId == null || userId.isEmpty) {
      debugPrint('FCMService: No active user session to save token for yet.');
      return;
    }

    try {
      await SupaConfig.client
          .from('profiles')
          .update({'fcm_token': token})
          .eq('id', userId);
      debugPrint('FCMService: ✅ Successfully saved FCM Token for user $userId');
    } catch (e) {
      debugPrint('FCMService: ⚠️ Failed to save FCM token to Supabase: $e');
    }
  }
}
