import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:adhan/adhan.dart';
import 'package:quran_connect/core/data/athkar_motivational_messages.dart';
import 'package:quran_connect/core/services/notification_copy_builder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:quran_connect/main.dart' show navigatorKey;
import 'package:go_router/go_router.dart';
import 'dart:io';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  // Audio player for Adhan sound
  static AudioPlayer? _adhanPlayer;
  static String _currentAdhanSound = 'makkah'; // Default

  static const String _dailyReminderChannelId = 'daily_reminder';
  static const String _streakWarningChannelId = 'streak_warning';
  static const String _completionChannelId = 'completion';
  static const String _athkarChannelId = 'athkar_reminders';
  static const String _adhanChannelId = 'adhan_notifications';
  static const String _dailyDuaChannelId = 'daily_dua_reminders';
  static const String _socialChannelId = 'social_notifications';
  static const String _sunanChannelId = 'sunan_reminders';
  static const String _memorizationChannelId = 'memorization_reminders';

  // Memorization Assistant notification IDs (kept in a dedicated range so they
  // never collide with the daily/streak/social/prayer IDs above).
  static const int _memorizationReinforcementId = 700;
  static const int _memorizationRevisionId = 701;
  static const int _memorizationReviewId = 702;
  static const int _memorizationInvitationId = 703;
  static const int _memorizationDecisionId = 704;
  static const int _memorizationOverdueId = 705;
  static const int _memorizationLiveReminderId = 706;

  /// True once [initialize] has set up timezone data (`tz.local`).
  /// Guards scheduled notifications against the startup race where the
  /// prayer-times provider resolves before background init completes.
  static bool _timezoneReady = false;

  Future<void> initialize() async {
    tz.initializeTimeZones();

    // Set local timezone to fix notification timing issues
    try {
      // Get system timezone offset to determine appropriate timezone
      final offset = DateTime.now().timeZoneOffset;
      final hours = offset.inHours;

      // Try common Middle Eastern timezones based on locale and offset
      final List<String> timeZonesToTry = [];

      // If Arabic locale, prioritize Middle Eastern timezones
      if (Platform.localeName.contains('ar')) {
        // Map UTC offset to common Middle Eastern timezones
        if (hours == 2) {
          timeZonesToTry.addAll(['Africa/Cairo', 'Asia/Jerusalem']);
        } else if (hours == 3) {
          timeZonesToTry.addAll([
            'Asia/Riyadh',
            'Asia/Kuwait',
            'Asia/Bahrain',
            'Asia/Qatar',
            'Asia/Baghdad',
          ]);
        } else if (hours == 4) {
          timeZonesToTry.addAll(['Asia/Dubai', 'Asia/Muscat']);
        } else {
          // Default to Riyadh for Arabic locales
          timeZonesToTry.add('Asia/Riyadh');
        }
      } else {
        // For non-Arabic locales, try to match offset first
        if (hours == 2) {
          timeZonesToTry.addAll([
            'Africa/Cairo',
            'Europe/Athens',
            'Asia/Jerusalem',
          ]);
        } else if (hours == 3) {
          timeZonesToTry.addAll([
            'Asia/Riyadh',
            'Europe/Moscow',
            'Africa/Nairobi',
          ]);
        } else if (hours == 4) {
          timeZonesToTry.addAll(['Asia/Dubai', 'Europe/Samara']);
        }
      }

      // Add common fallbacks
      timeZonesToTry.addAll(['Asia/Riyadh', 'Africa/Cairo', 'Asia/Dubai']);

      tz.Location? localLocation;
      for (final tzName in timeZonesToTry) {
        try {
          localLocation = tz.getLocation(tzName);
          tz.setLocalLocation(localLocation);
          debugPrint(
            'NotificationService: Set local timezone to $tzName (offset: ${hours}h)',
          );
          break;
        } catch (e) {
          // Continue to next timezone
          continue;
        }
      }

      // Final fallback if all attempts failed
      if (localLocation == null) {
        try {
          // Use Riyadh as absolute last resort for Arabic apps
          localLocation = tz.getLocation('Asia/Riyadh');
          tz.setLocalLocation(localLocation);
          debugPrint(
            'NotificationService: Set fallback timezone to Asia/Riyadh',
          );
        } catch (e) {
          debugPrint(
            'NotificationService: Failed to set timezone, using UTC: $e',
          );
          // Will use UTC as last resort
        }
      }
    } catch (e) {
      debugPrint('NotificationService: Error setting timezone: $e');
      // Continue without setting timezone (will use UTC)
    }
    // Timezone database is loaded (even if only UTC), so tz.local is safe now.
    _timezoneReady = true;

    const androidSettings = AndroidInitializationSettings(
      '@drawable/ic_stat_notification',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
      onDidReceiveBackgroundNotificationResponse:
          _onBackgroundNotificationResponse,
    );

    // Create notification channels (Android)
    await _createNotificationChannels();
  }

  // Background notification response handler (must be top-level or static)
  @pragma('vm:entry-point')
  static void _onBackgroundNotificationResponse(NotificationResponse response) {
    debugPrint('Background notification tapped: ${response.payload}');
    // For background, we can't navigate directly, but we can handle it
    // The app will handle navigation when opened
  }

  /// Create adhan notification channel for a specific sound
  /// In Android, notification channels cache their sound settings, so we need a separate channel for each sound
  /// Note: This function expects normalized sound (not 'default' - should be 'makkah', 'madina', 'cairo', or 'istanbul')
  /// If forceRecreate is true, the channel will be deleted and recreated (useful for testing or updating sound)
  Future<void> _createAdhanChannelForSound(
    String sound,
    bool enableVibration, {
    bool forceRecreate = false,
  }) async {
    // Normalize sound: if 'default' or empty, use 'makkah' as default
    final normalizedSound =
        (sound == 'default' || sound.isEmpty) ? 'makkah' : sound;

    // Get channel ID and name
    final channelId =
        normalizedSound == 'makkah'
            ? _adhanChannelId
            : '${_adhanChannelId}_$normalizedSound';
    final channelName =
        normalizedSound == 'makkah'
            ? 'إشعارات الأذان'
            : 'الأذان - ${_getAdhanSoundDisplayName(normalizedSound)}';

    final androidImplementation =
        _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

    // In Android, we cannot change channel sound after creation, so delete and recreate if needed
    if (forceRecreate && androidImplementation != null) {
      try {
        await androidImplementation.deleteNotificationChannel(channelId);
        debugPrint('Deleted existing adhan channel: $channelId for recreation');
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        debugPrint('Error deleting adhan channel: $e');
      }
    }

    // Create Android sound resource
    final androidSound = RawResourceAndroidNotificationSound(
      'adhan_$normalizedSound',
    );

    // Create the channel with ALARM attributes for reliable playback
    final adhanChannel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: 'إشعارات أوقات الصلاة (الأذان)',
      importance: Importance.max,
      playSound: true,
      enableVibration: enableVibration,
      sound: androidSound,
      audioAttributesUsage: AudioAttributesUsage.alarm, // CRITICAL FIX
    );

    await androidImplementation?.createNotificationChannel(adhanChannel);

    debugPrint(
      'Created adhan channel: $channelId with sound: adhan_$normalizedSound (ALARM)',
    );
  }

  Future<void> _createNotificationChannels() async {
    const dailyChannel = AndroidNotificationChannel(
      _dailyReminderChannelId,
      'تذكير الورد اليومي',
      description: 'تذكير لإكمال الورد اليومي',
      importance: Importance.high,
    );

    const streakChannel = AndroidNotificationChannel(
      _streakWarningChannelId,
      'تحذيرات الستريك',
      description: 'تحذيرات حول فقدان الستريك',
      importance: Importance.max,
    );

    const completionChannel = AndroidNotificationChannel(
      _completionChannelId,
      'إشعارات الإكمال',
      description: 'إشعارات عند إكمال الورد اليومي',
      importance: Importance.high,
    );

    // Create default adhan channel with Makkah sound
    const adhanChannelDefault = AndroidNotificationChannel(
      _adhanChannelId,
      'إشعارات الأذان',
      description: 'إشعارات أوقات الصلاة (الأذان)',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound('adhan_makkah'),
      audioAttributesUsage: AudioAttributesUsage.alarm, // CRITICAL FIX
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(dailyChannel);

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(streakChannel);

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(completionChannel);

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(adhanChannelDefault);

    // Create Athkar notification channel
    const athkarChannel = AndroidNotificationChannel(
      _athkarChannelId,
      'تذكير الأذكار',
      description: 'تذكيرات أذكار الصباح والمساء',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(athkarChannel);

    // Create Social notification channel for friends and social features
    const socialChannel = AndroidNotificationChannel(
      _socialChannelId,
      'إشعارات الأصدقاء',
      description: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(socialChannel);

    // Create Daily Dua notification channel
    const dailyDuaChannel = AndroidNotificationChannel(
      _dailyDuaChannelId,
      'تذكير دعاء اليوم',
      description: 'تذكير يومي بدعاء اليوم',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(dailyDuaChannel);

    // Create Sunan notification channel for Friday reminders
    const sunanChannel = AndroidNotificationChannel(
      _sunanChannelId,
      'إشعارات السنن',
      description: 'تذكير بقراءة سورة الكهف يوم الجمعة والسنن الأخرى',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(sunanChannel);

    // Create Memorization Assistant channel (reinforcement + review reminders)
    const memorizationChannel = AndroidNotificationChannel(
      _memorizationChannelId,
      'تذكيرات الحفظ',
      description: 'تذكيرات تثبيت الآيات ومراجعة التسميع في مساعد الحفظ',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(memorizationChannel);
  }

  // ----- Memorization Assistant ---------------------------------------------

  static const AndroidNotificationDetails _memorizationAndroidDetails =
      AndroidNotificationDetails(
        _memorizationChannelId,
        'تذكيرات الحفظ',
        channelDescription:
            'تذكيرات تثبيت الآيات ومراجعة التسميع في مساعد الحفظ',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@drawable/ic_stat_notification',
        color: Color(0xFF006D5B),
        enableVibration: true,
        playSound: true,
      );

  static const DarwinNotificationDetails _memorizationIosDetails =
      DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

  /// Gentle confirmation when an ayah/range is added to the reinforcement list.
  Future<void> showMemorizationReinforcementNotification(
    String rangeLabel,
    int totalCount,
  ) async {
    await _notifications.show(
      _memorizationReinforcementId,
      'أُضيفت إلى قائمة التثبيت',
      totalCount > 1
          ? '$rangeLabel — لديك $totalCount مقاطع تنتظر المراجعة.'
          : '$rangeLabel — سنذكّرك بمراجعتها لتثبيت حفظك.',
      const NotificationDetails(
        android: _memorizationAndroidDetails,
        iOS: _memorizationIosDetails,
      ),
      payload: 'memorization',
    );
  }

  /// Daily revision nudge while the reinforcement list is non-empty.
  Future<void> scheduleMemorizationRevisionReminder(
    int hour,
    int minute,
  ) async {
    try {
      await _notifications.zonedSchedule(
        _memorizationRevisionId,
        'وقت تثبيت الحفظ',
        'راجع الآيات التي تحتاج تثبيتاً اليوم، ولو مقطعاً واحداً.',
        _nextInstanceOfTime(hour, minute),
        const NotificationDetails(
          android: _memorizationAndroidDetails,
          iOS: _memorizationIosDetails,
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'memorization',
      );
    } catch (e) {
      debugPrint('Error scheduling memorization revision reminder: $e');
      await _notifications.zonedSchedule(
        _memorizationRevisionId,
        'وقت تثبيت الحفظ',
        'راجع الآيات التي تحتاج تثبيتاً اليوم، ولو مقطعاً واحداً.',
        _nextInstanceOfTime(hour, minute),
        const NotificationDetails(
          android: _memorizationAndroidDetails,
          iOS: _memorizationIosDetails,
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'memorization',
      );
    }
  }

  Future<void> cancelMemorizationRevisionReminder() async {
    await _notifications.cancel(_memorizationRevisionId);
  }

  /// Notifies the reviewer that a new recitation is waiting in a group queue.
  Future<void> showNewSubmissionForReviewNotification(
    String groupName,
    int pendingCount, {
    String? memberName,
    String? rangeLabel,
    String? groupId,
    int? id,
  }) async {
    final copy = NotificationCopyBuilder.newSubmissionForReview(
      groupName: groupName,
      pendingCount: pendingCount,
      memberName: memberName,
      rangeLabel: rangeLabel,
    );
    final notificationId = id ?? (groupId != null ? (groupId.hashCode.abs() % 1000 + 710) : _memorizationReviewId);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: _memorizationAndroidDetails,
        iOS: _memorizationIosDetails,
      ),
      payload: groupId != null && groupId.isNotEmpty
          ? 'memorization/review/$groupId'
          : 'memorization',
    );
  }

  /// Notifies a member that they were invited to a private memorization group.
  Future<void> showGroupInvitationNotification(
    String groupName, {
    String? groupId,
    String? rangeLabel,
    int? id,
  }) async {
    final copy = NotificationCopyBuilder.groupInvitation(
      groupName: groupName,
      rangeLabel: rangeLabel,
    );
    final notificationId = id ?? (groupId != null ? (groupId.hashCode.abs() % 1000 + 720) : _memorizationInvitationId);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: _memorizationAndroidDetails,
        iOS: _memorizationIosDetails,
      ),
      payload: groupId != null && groupId.isNotEmpty
          ? 'memorization/group/$groupId'
          : 'memorization',
    );
  }

  /// Notifies a member of a reviewer's decision on their submission.
  Future<void> showReviewDecisionNotification(
    String groupName,
    MemorizationDecisionKind kind, {
    String? rangeLabel,
    String? groupId,
    bool hasVoiceNote = false,
    int? id,
  }) async {
    final copy = NotificationCopyBuilder.reviewDecision(
      groupName: groupName,
      kind: kind,
      rangeLabel: rangeLabel,
      hasVoiceNote: hasVoiceNote,
    );
    final notificationId = id ?? (groupId != null ? (groupId.hashCode.abs() % 1000 + 730) : _memorizationDecisionId);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: _memorizationAndroidDetails,
        iOS: _memorizationIosDetails,
      ),
      payload: groupId != null && groupId.isNotEmpty
          ? 'memorization/group/$groupId'
          : 'memorization',
    );
  }

  /// Reminds a member that today's group assignment is overdue.
  Future<void> showGroupAssignmentOverdueNotification(String groupName) async {
    await _notifications.show(
      _memorizationOverdueId,
      'ورد الحفظ متأخر ⏰',
      'لم يصل تسميعك في «$groupName» بعد. سمّع وردك قبل نهاية اليوم.',
      const NotificationDetails(
        android: _memorizationAndroidDetails,
        iOS: _memorizationIosDetails,
      ),
      payload: 'memorization',
    );
  }

  /// Schedules a daily nudge at the group's due time to submit before the day
  /// ends. A gentle catch-all reminder; cancelled when the group is removed or
  /// loses its due time.
  Future<void> scheduleGroupAssignmentOverdueReminder(
    int hour,
    int minute,
  ) async {
    try {
      await _notifications.zonedSchedule(
        _memorizationOverdueId,
        'ورد الحفظ ⏰',
        'إن لم تكن سمّعت وردك في مجموعتك اليوم، فهذا تذكير لطيف قبل انتهاء الوقت.',
        _nextInstanceOfTime(hour, minute),
        const NotificationDetails(
          android: _memorizationAndroidDetails,
          iOS: _memorizationIosDetails,
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'memorization',
      );
    } catch (e) {
      debugPrint('Error scheduling group overdue reminder: $e');
    }
  }

  Future<void> cancelGroupAssignmentOverdueReminder() async {
    await _notifications.cancel(_memorizationOverdueId);
  }

  /// Schedules a one-off reminder [leadMinutes] before a live halaqah at
  /// [sessionAt]. No-op when the reminder time is already in the past.
  Future<void> scheduleLiveSessionReminder(
    DateTime sessionAt,
    String groupName, {
    int leadMinutes = 30,
  }) async {
    try {
      final remindAt = sessionAt.subtract(Duration(minutes: leadMinutes));
      if (remindAt.isBefore(DateTime.now())) return;
      await _notifications.zonedSchedule(
        _memorizationLiveReminderId,
        'حلقة الحفظ المباشرة قريباً',
        'حلقة «$groupName» تبدأ قريباً. جهّز وردك وادخل الحلقة في موعدها.',
        tz.TZDateTime.from(remindAt, tz.local),
        const NotificationDetails(
          android: _memorizationAndroidDetails,
          iOS: _memorizationIosDetails,
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'memorization',
      );
    } catch (e) {
      debugPrint('Error scheduling live session reminder: $e');
    }
  }

  Future<void> cancelLiveSessionReminder() async {
    await _notifications.cancel(_memorizationLiveReminderId);
  }

  Future<bool> requestPermissions() async {
    final androidImplementation =
        _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

    final androidGranted =
        await androidImplementation?.requestNotificationsPermission();

    final iosImplementation =
        _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();

    final iosGranted = await iosImplementation?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    return (androidGranted ?? false) || (iosGranted ?? false);
  }

  Future<void> scheduleDailyReminder(int hour, int minute) async {
    await _notifications.zonedSchedule(
      0, // Notification ID
      'حان وقت الورد اليومي!',
      'لا تكسر الستريك! اقرأ القرآن اليوم.',
      _nextInstanceOfTime(hour, minute),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _dailyReminderChannelId,
          'تذكير الورد اليومي',
          channelDescription: 'تذكير لإكمال الورد اليومي',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'wird', // Deep link to wird screen
    );
  }

  Future<void> scheduleStreakWarning(int currentStreak) async {
    // Schedule warning for 10 PM if user hasn't completed Wird
    final now = DateTime.now();
    final warningTime = DateTime(now.year, now.month, now.day, 22, 0);

    if (now.isBefore(warningTime)) {
      await _notifications.zonedSchedule(
        1, // Notification ID
        'لا تفقد الستريك البالغ $currentStreak أيام!',
        'لم تكمل الورد اليوم. اضغط للقراءة الآن!',
        tz.TZDateTime.from(warningTime, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _streakWarningChannelId,
            'تحذيرات الستريك',
            channelDescription: 'تحذيرات حول فقدان الستريك',
            importance: Importance.max,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
            color: Color(0xFFFF5722),
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: 'wird', // Deep link to wird screen
      );
    }
  }

  Future<void> cancelAllNotifications() async {
    await _notifications.cancelAll();
  }

  Future<void> cancelDailyReminder() async {
    await _notifications.cancel(0);
  }

  Future<void> cancelStreakWarning() async {
    await _notifications.cancel(1);
  }

  Future<void> cancelNotification(int id) async {
    await _notifications.cancel(id);
  }

  Future<void> showRemoteNotification({
    String? title,
    String? body,
    String? payload,
    int? id,
  }) async {
    final notificationId = id ?? (DateTime.now().millisecondsSinceEpoch.abs() % 100000 + 8000);
    await _notifications.show(
      notificationId,
      title ?? 'عون',
      body ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات التطبيق والمجتمع',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والتحديثات',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF006D5B),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: payload ?? 'home',
    );
  }

  Future<void> showCompletionNotification(
    int currentStreak,
    int pagesRead,
  ) async {
    await _notifications.show(
      2, // Notification ID
      'تم إكمال الورد اليومي!',
      'لقد قرأت $pagesRead صفحة اليوم. سلسلتك الحالية: $currentStreak أيام متتالية',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _completionChannelId,
          'إشعارات الإكمال',
          channelDescription: 'إشعارات عند إكمال الورد اليومي',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF4CAF50),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'wird', // Deep link to wird screen
    );
  }

  /// Send notification when friend streak is at risk
  Future<void> sendFriendStreakRiskNotification(
    String friendName,
    int sharedStreak,
  ) async {
    await _notifications.show(
      3, // Notification ID
      'خطر كسر الستريك المشترك!',
      '$friendName لم يكمل الورد اليوم. الستريك المشترك: $sharedStreak أيام',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFFFF5722),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social', // Deep link to social screen
    );
  }

  /// Send notification when friend streak milestone is reached
  Future<void> sendFriendStreakMilestoneNotification(
    String friendName,
    int milestone,
    bool isShared,
  ) async {
    final streakType = isShared ? 'المشترك' : 'الفردي';
    await _notifications.show(
      4, // Notification ID
      'معلم جديد في الستريك!',
      'وصلت أنت و$friendName إلى $milestone يوم في الستريك $streakType!',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF4CAF50),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social', // Deep link to social screen
    );
  }

  /// Send notification when friend streak is broken
  Future<void> sendFriendStreakBrokenNotification(
    String friendName,
    int brokenStreak,
    bool isShared,
  ) async {
    final streakType = isShared ? 'المشترك' : 'الفردي';
    await _notifications.show(
      5, // Notification ID
      'تم كسر الستريك $streakType',
      'انتهى الستريك $streakType مع $friendName بعد $brokenStreak أيام',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFFFF5722),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social', // Deep link to social screen
    );
  }

  /// Send notification when friend completed wird
  Future<void> sendFriendCompletedNotification(String friendName) async {
    await _notifications.show(
      6, // Notification ID
      '$friendName أكمل الورد!',
      'أكمل $friendName ورده اليومي. استمر في الستريك المشترك!',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF4CAF50),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social', // Deep link to social screen
    );
  }

  Future<void> showAthkarItemCompletionNotification() async {
    final message = AthkarMotivationalMessages.getRandomItemMessage();
    await _notifications.show(
      100, // Notification ID for athkar items
      'ذكر مكتمل',
      message,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _athkarChannelId,
          'إشعارات الأذكار',
          channelDescription: 'إشعارات الأذكار والذكر',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF4CAF50),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'athkar', // Deep link to athkar screen
    );
  }

  /// Send poke / nudge notification
  Future<void> showPokeNotification(String friendName, {bool isNudge = false, String? senderId, int? id}) async {
    final copy = NotificationCopyBuilder.pokeOrNudge(friendName, isNudge: isNudge);
    final notificationId = id ?? (senderId != null ? (senderId.hashCode.abs() % 1000 + 840) : 600);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFFFFD700),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'wird',
    );
  }

  Future<void> showAthkarCategoryCompletionNotification(
    String categoryId,
    int currentStreak,
  ) async {
    final categoryName = AthkarMotivationalMessages.getCategoryName(categoryId);
    final baseMessage = AthkarMotivationalMessages.getRandomCategoryMessage();
    final milestoneMessage = AthkarMotivationalMessages.getMilestoneMessage(
      currentStreak,
      categoryName,
    );

    final message =
        milestoneMessage.contains('ممتاز! استمر')
            ? baseMessage
            : milestoneMessage;

    await _notifications.show(
      101, // Notification ID for category completion
      '$categoryName مكتملة!',
      '$message\nستريكك الحالي: $currentStreak يوم',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _athkarChannelId,
          'إشعارات الأذكار',
          channelDescription: 'إشعارات الأذكار والذكر',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF4CAF50),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'athkar', // Deep link to athkar screen
    );
  }

  Future<void> scheduleAthkarReminders() async {
    // Morning athkar reminder at 6:00 AM
    try {
      await _notifications.zonedSchedule(
        200,
        'وقت أذكار الصباح',
        'لا تنس أذكار الصباح المباركة',
        _nextInstanceOfTime(6, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _athkarChannelId,
            'إشعارات الأذكار',
            channelDescription: 'إشعارات الأذكار والذكر',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'athkar:morning', // Deep link directly to morning category
      );
    } catch (e) {
      debugPrint('Error scheduling morning athkar: $e');
      await _notifications.zonedSchedule(
        200,
        'وقت أذكار الصباح',
        'لا تنس أذكار الصباح المباركة',
        _nextInstanceOfTime(6, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _athkarChannelId,
            'إشعارات الأذكار',
            channelDescription: 'إشعارات الأذكار والذكر',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }

    // Evening athkar reminder at 6:00 PM
    try {
      await _notifications.zonedSchedule(
        201,
        'وقت أذكار المساء',
        'لا تنس أذكار المساء المباركة',
        _nextInstanceOfTime(18, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _athkarChannelId,
            'إشعارات الأذكار',
            channelDescription: 'إشعارات الأذكار والذكر',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'athkar:evening', // Deep link directly to evening category
      );
    } catch (e) {
      debugPrint('Error scheduling evening athkar: $e');
      await _notifications.zonedSchedule(
        201,
        'وقت أذكار المساء',
        'لا تنس أذكار المساء المباركة',
        _nextInstanceOfTime(18, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _athkarChannelId,
            'إشعارات الأذكار',
            channelDescription: 'إشعارات الأذكار والذكر',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }

    // Sleep athkar reminder at 9:00 PM
    try {
      await _notifications.zonedSchedule(
        202,
        'وقت أذكار النوم',
        'لا تنس أذكار النوم قبل النوم',
        _nextInstanceOfTime(21, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _athkarChannelId,
            'إشعارات الأذكار',
            channelDescription: 'إشعارات الأذكار والذكر',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'athkar:sleep', // Deep link directly to sleep category
      );
    } catch (e) {
      debugPrint('Error scheduling sleep athkar: $e');
      await _notifications.zonedSchedule(
        202,
        'وقت أذكار النوم',
        'لا تنس أذكار النوم قبل النوم',
        _nextInstanceOfTime(21, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _athkarChannelId,
            'إشعارات الأذكار',
            channelDescription: 'إشعارات الأذكار والذكر',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  }

  /// Schedule daily dua reminder notification
  Future<void> scheduleDailyDuaReminder(int hour, int minute) async {
    try {
      await _notifications.zonedSchedule(
        250, // Unique ID for daily dua reminder
        'دعاء اليوم',
        'لا تنسَ دعاء اليوم! ادعُ ربك واستفتح يومك بالدعاء المبارك',
        _nextInstanceOfTime(hour, minute),
        NotificationDetails(
          android: AndroidNotificationDetails(
            _dailyDuaChannelId,
            'تذكير دعاء اليوم',
            channelDescription: 'تذكير يومي بدعاء اليوم',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
            color: const Color(0xFFC5A021), // Gold color
            enableVibration: true,
            playSound: true,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'daily_dua', // Deep link to daily dua screen
      );
    } catch (e) {
      debugPrint('Error scheduling daily dua reminder: $e');
      // Fallback to inexact scheduling
      await _notifications.zonedSchedule(
        250,
        'دعاء اليوم',
        'لا تنسَ دعاء اليوم! ادعُ ربك واستفتح يومك بالدعاء المبارك',
        _nextInstanceOfTime(hour, minute),
        NotificationDetails(
          android: AndroidNotificationDetails(
            _dailyDuaChannelId,
            'تذكير دعاء اليوم',
            channelDescription: 'تذكير يومي بدعاء اليوم',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
            color: const Color(0xFFC5A021),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'daily_dua',
      );
    }
  }

  /// Cancel daily dua reminder
  Future<void> cancelDailyDuaReminder() async {
    await _notifications.cancel(250);
  }

  /// Schedule Friday reminder for Al-Kahf surah at 1 PM local time
  Future<void> scheduleFridayAlKahfReminder() async {
    try {
      final now = tz.TZDateTime.now(tz.local);

      // Find next Friday at 1:00 PM (13:00)
      var nextFriday = now;

      // Calculate days until next Friday (DateTime.friday = 5)
      // weekday: Monday = 1, Friday = 5, Sunday = 7
      int daysUntilFriday = (DateTime.friday - now.weekday + 7) % 7;

      // If today is Friday and it's before 1 PM, use today
      // Otherwise, use next Friday
      if (daysUntilFriday == 0 && now.hour < 13) {
        nextFriday = tz.TZDateTime(
          tz.local,
          now.year,
          now.month,
          now.day,
          13,
          0,
        );
      } else {
        // If today is Friday but past 1 PM, or any other day
        if (daysUntilFriday == 0) {
          daysUntilFriday = 7; // Next Friday (7 days later)
        }

        final targetDate = now.add(Duration(days: daysUntilFriday));
        nextFriday = tz.TZDateTime(
          tz.local,
          targetDate.year,
          targetDate.month,
          targetDate.day,
          13,
          0,
        );
      }

      await _notifications.zonedSchedule(
        500, // Unique ID for Friday Al-Kahf reminder
        'يوم الجمعة - وقت قراءة سورة الكهف',
        'لا تنس قراءة سورة الكهف يوم الجمعة. نورٌ يضيء لك ما بين الجمعتين',
        nextFriday,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _sunanChannelId,
            'إشعارات السنن',
            channelDescription:
                'تذكير بقراءة سورة الكهف يوم الجمعة والسنن الأخرى',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notification',
            color: Color(0xFF2196F3), // Blue color
            enableVibration: true,
            playSound: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: 'sunan|al_kahf', // Deep link to sunan screen
      );

      debugPrint(
        'NotificationService: Friday Al-Kahf reminder scheduled for $nextFriday',
      );
    } catch (e) {
      debugPrint('Error scheduling Friday Al-Kahf reminder: $e');
      // Fallback to inexact scheduling
      try {
        final now = tz.TZDateTime.now(tz.local);
        int daysUntilFriday = (DateTime.friday - now.weekday + 7) % 7;
        if (daysUntilFriday == 0 && now.hour >= 13) {
          daysUntilFriday = 7;
        } else if (daysUntilFriday == 0) {
          daysUntilFriday = 0;
        }

        final targetDate = now.add(Duration(days: daysUntilFriday));
        final fridayTime = tz.TZDateTime(
          tz.local,
          targetDate.year,
          targetDate.month,
          targetDate.day,
          13,
          0,
        );

        await _notifications.zonedSchedule(
          500,
          'يوم الجمعة - وقت قراءة سورة الكهف',
          'لا تنس قراءة سورة الكهف يوم الجمعة. نورٌ يضيء لك ما بين الجمعتين',
          fridayTime,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _sunanChannelId,
              'إشعارات السنن',
              channelDescription:
                  'تذكير بقراءة سورة الكهف يوم الجمعة والسنن الأخرى',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@drawable/ic_stat_notification',
              color: Color(0xFF2196F3),
              enableVibration: true,
              playSound: true,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: 'sunan|al_kahf',
        );
        debugPrint(
          'Fallback: Friday Al-Kahf reminder scheduled with inexact mode',
        );
      } catch (e2) {
        debugPrint('Error scheduling fallback Friday Al-Kahf reminder: $e2');
      }
    }
  }

  /// Cancel Friday Al-Kahf reminder
  Future<void> cancelFridayAlKahfReminder() async {
    await _notifications.cancel(500);
  }

  /// Send notification when friend request is received
  Future<void> sendFriendRequestNotification(String requesterName, {String? requesterId, int? id}) async {
    final copy = NotificationCopyBuilder.friendRequest(requesterName);
    final notificationId = id ?? (requesterId != null ? (requesterId.hashCode.abs() % 1000 + 800) : 7);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF006D5B),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social',
    );
  }

  /// Send notification when friend request is accepted
  Future<void> sendFriendRequestAcceptedNotification(String friendName, {String? friendId, int? id}) async {
    final copy = NotificationCopyBuilder.friendRequestAccepted(friendName);
    final notificationId = id ?? (friendId != null ? (friendId.hashCode.abs() % 1000 + 810) : 8);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF006D5B),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social',
    );
  }

  /// Send notification when a friend challenge is created
  Future<void> showChallengeNotification({
    required String challengerName,
    String? challengeType,
    int? targetValue,
    String? challengeId,
    int? id,
  }) async {
    final copy = NotificationCopyBuilder.challengeCreated(
      challengerName: challengerName,
      challengeType: challengeType,
      targetValue: targetValue,
    );
    final notificationId = id ?? (challengeId != null ? (challengeId.hashCode.abs() % 1000 + 820) : 820);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFFFF9800),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social',
    );
  }

  /// Send notification when a friend completes a Khatma
  Future<void> showFriendKhatmaNotification(String friendName, {String? friendId, int? id}) async {
    final copy = NotificationCopyBuilder.khatmaCompleted(friendName);
    final notificationId = id ?? (friendId != null ? (friendId.hashCode.abs() % 1000 + 830) : 830);
    await _notifications.show(
      notificationId,
      copy.title,
      copy.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _socialChannelId,
          'إشعارات الأصدقاء',
          channelDescription: 'إشعارات الأصدقاء والمجتمع والستريك المشترك',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          color: Color(0xFF006D5B),
          enableVibration: true,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'social',
    );
  }

  Future<void> schedulePrayerNotifications(
    PrayerTimes prayerTimes, {
    String? adhanSound,
    bool includeSunrise = false,
    int startId = 300,
    bool? vibrationEnabled,
    Map<Prayer, int>? iqamahOffsets,
  }) async {
    if (!_timezoneReady) {
      debugPrint(
        'NotificationService: skipping prayer scheduling — timezone not '
        'initialized yet (initialize() has not completed).',
      );
      return;
    }
    final prayers = {
      Prayer.fajr: prayerTimes.fajr,
      Prayer.dhuhr: prayerTimes.dhuhr,
      Prayer.asr: prayerTimes.asr,
      Prayer.maghrib: prayerTimes.maghrib,
      Prayer.isha: prayerTimes.isha,
    };

    int notificationId = startId;
    // Normalize sound: use 'makkah' as default instead of 'default'
    final sound =
        (adhanSound == null || adhanSound == 'default' || adhanSound.isEmpty)
            ? 'makkah'
            : adhanSound;
    final enableVibration = vibrationEnabled ?? true; // Default: enabled

    // Create the notification channel for this sound BEFORE scheduling notifications
    // This is critical for Android 8.0+ where channels cache their sound settings
    try {
      await _createAdhanChannelForSound(sound, enableVibration);
    } catch (e) {
      debugPrint('Error creating adhan channel for sound $sound: $e');
      // Continue anyway - will use default channel
    }

    // Get channel ID and name based on sound
    final channelId =
        sound == 'makkah' ? _adhanChannelId : '${_adhanChannelId}_$sound';
    final channelName =
        sound == 'makkah'
            ? 'إشعارات الأذان'
            : 'الأذان - ${_getAdhanSoundDisplayName(sound)}';

    // Android sound resource
    final androidSound = RawResourceAndroidNotificationSound('adhan_$sound');
    // iOS sound file
    final iosSound = 'adhan_$sound.mp3';

    for (var entry in prayers.entries) {
      final prayerName = _getPrayerNameInArabic(entry.key);
      final prayerTime = entry.value;

      if (prayerTime.isAfter(DateTime.now())) {
        try {
          final iqamahOffset = iqamahOffsets?[entry.key] ?? 0;
          final body =
              iqamahOffset > 0
                  ? 'الله أكبر، الله أكبر. (الإقامة بعد $iqamahOffset دقيقة)'
                  : 'حي على الصلاة، حي على الفلاح';

          await _notifications.zonedSchedule(
            notificationId++,
            'حان وقت صلاة $prayerName',
            body,
            tz.TZDateTime.from(prayerTime, tz.local),
            NotificationDetails(
              android: AndroidNotificationDetails(
                channelId,
                channelName,
                channelDescription: 'إشعارات أوقات الصلاة (الأذان)',
                importance: Importance.max,
                priority: Priority.high,
                icon: '@drawable/ic_stat_notification',
                sound: androidSound,
                playSound: true,
                enableVibration: enableVibration,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
                sound: iosSound,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            payload:
                'prayer|$sound|${entry.key.name}', // Deep link + sound type + prayer name
          );

          debugPrint(
            'Scheduled adhan notification for $prayerName at $prayerTime with sound: adhan_$sound',
          );
        } catch (e) {
          debugPrint('Error scheduling adhan for $prayerName: $e');
          // Fallback: try with default Makkah channel
          try {
            await _createAdhanChannelForSound('makkah', enableVibration);
            await _notifications.zonedSchedule(
              notificationId - 1,
              'حان وقت صلاة $prayerName',
              'حي على الصلاة، حي على الفلاح',
              tz.TZDateTime.from(prayerTime, tz.local),
              NotificationDetails(
                android: AndroidNotificationDetails(
                  _adhanChannelId,
                  'إشعارات الأذان',
                  channelDescription: 'إشعارات أوقات الصلاة (الأذان)',
                  importance: Importance.max,
                  priority: Priority.high,
                  icon: '@drawable/ic_stat_notification',
                  sound: RawResourceAndroidNotificationSound('adhan_makkah'),
                  playSound: true,
                  enableVibration: enableVibration,
                ),
                iOS: DarwinNotificationDetails(
                  presentAlert: true,
                  presentBadge: true,
                  presentSound: true,
                  sound: 'adhan_makkah.mp3',
                ),
              ),
              androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
              payload: 'prayer|makkah|${entry.key.name}',
            );
            debugPrint('Fallback: Scheduled adhan with default Makkah sound');
          } catch (e2) {
            debugPrint('Error scheduling fallback default adhan: $e2');
          }
        }
      }
    }
  }

  String _getPrayerNameInArabic(Prayer prayer) {
    switch (prayer) {
      case Prayer.fajr:
        return 'الفجر';
      case Prayer.sunrise:
        return 'الشروق';
      case Prayer.dhuhr:
        return 'الظهر';
      case Prayer.asr:
        return 'العصر';
      case Prayer.maghrib:
        return 'المغرب';
      case Prayer.isha:
        return 'العشاء';
      case Prayer.none:
        return '';
    }
  }

  /// Test adhan sound by playing it
  /// This will delete and recreate the channel to ensure the sound is set correctly
  Future<void> testAdhanSound(String sound) async {
    // Normalize sound: use 'makkah' as default
    final normalizedSound =
        (sound == 'default' || sound.isEmpty) ? 'makkah' : sound;

    // Force recreate channel to ensure sound is set correctly (delete and recreate)
    // This is necessary because Android caches channel sound settings and cannot be changed after creation
    try {
      await _createAdhanChannelForSound(
        normalizedSound,
        true,
        forceRecreate: true,
      );
      // Small delay to ensure channel is fully created
      await Future.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      debugPrint('Error creating test adhan channel: $e');
    }

    // Play sound directly first to verify file and audio system
    try {
      if (_adhanPlayer != null) {
        await _adhanPlayer!.stop();
        await _adhanPlayer!.dispose();
      }
      _adhanPlayer = AudioPlayer();
      await _adhanPlayer!.play(AssetSource('audio/adhan_$normalizedSound.mp3'));
      debugPrint('Test: Playing adhan via AudioPlayer directly');

      // Stop after 5 seconds
      Future.delayed(const Duration(seconds: 5), () {
        if (_adhanPlayer != null) {
          _adhanPlayer!.stop();
        }
      });
    } catch (e) {
      debugPrint('Test: Error playing adhan via AudioPlayer: $e');
    }

    final channelId =
        normalizedSound == 'makkah'
            ? _adhanChannelId
            : '${_adhanChannelId}_$normalizedSound';
    final channelName =
        normalizedSound == 'makkah'
            ? 'إشعارات الأذان'
            : 'الأذان - ${_getAdhanSoundDisplayName(normalizedSound)}';

    final androidSound = RawResourceAndroidNotificationSound(
      'adhan_$normalizedSound',
    );
    final iosSound = 'adhan_$normalizedSound.mp3';

    // Show notification with sound
    await _notifications.show(
      9999, // Test notification ID
      'اختبار صوت الأذان',
      'صوت الأذان: ${_getAdhanSoundDisplayName(normalizedSound)}',
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'إشعارات أوقات الصلاة (الأذان)',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notification',
          sound: androidSound, // Explicitly set sound
          playSound: true, // Ensure sound is enabled
          enableVibration: true,
          audioAttributesUsage: AudioAttributesUsage.alarm, // CRITICAL FIX
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: iosSound,
        ),
      ),
    );

    debugPrint(
      'Test notification shown for adhan sound: adhan_$normalizedSound on channel: $channelId',
    );

    // Cancel test notification after 10 seconds
    Future.delayed(const Duration(seconds: 10), () {
      _notifications.cancel(9999);
    });
  }

  String _getAdhanSoundDisplayName(String sound) {
    switch (sound) {
      case 'makkah':
        return 'مكة المكرمة';
      case 'madina':
        return 'المدينة المنورة';
      case 'cairo':
        return 'القاهرة';
      case 'istanbul':
        return 'إسطنبول';
      default:
        return 'افتراضي النظام';
    }
  }

  tz.TZDateTime _nextInstanceOfTime(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    return scheduledDate;
  }

  /// Play Adhan audio when notification is tapped or received
  /// Note: For background notifications, the system plays the notification sound automatically
  /// For foreground, we play the actual audio file for better quality
  static Future<void> _playAdhanOnNotificationTap(
    String? soundFromPayload,
  ) async {
    try {
      // Stop any existing playback
      await stopAdhan();

      // Use sound from payload if available, otherwise use current default
      final sound = soundFromPayload ?? _currentAdhanSound;

      if (sound.isEmpty || sound == 'default') {
        debugPrint(
          'Default sound - notification system will handle, or using makkah as fallback',
        );
        // Try to play default sound (makkah) even if payload says default
        _adhanPlayer = AudioPlayer();
        final assetPath = 'audio/adhan_makkah.mp3';

        _adhanPlayer!.onPlayerComplete.listen((_) {
          _adhanPlayer?.dispose();
          _adhanPlayer = null;
        });

        try {
          await _adhanPlayer!.play(AssetSource(assetPath));
          debugPrint('Playing default Adhan (makkah): $assetPath');
        } catch (e) {
          debugPrint(
            'Error playing default Adhan, notification sound will be used: $e',
          );
          await stopAdhan();
        }
        return;
      }

      // Play custom Adhan sound
      _adhanPlayer = AudioPlayer();
      final assetPath = 'audio/adhan_$sound.mp3';

      _adhanPlayer!.onPlayerComplete.listen((_) {
        _adhanPlayer?.dispose();
        _adhanPlayer = null;
        debugPrint('Adhan playback completed');
      });

      await _adhanPlayer!.play(AssetSource(assetPath));
      debugPrint('Playing Adhan: $assetPath');

      // Auto-dispose after maximum duration (safety timeout - 2 minutes)
      Future.delayed(const Duration(minutes: 2), () {
        if (_adhanPlayer != null) {
          stopAdhan();
          debugPrint('Adhan playback stopped after timeout');
        }
      });
    } catch (e) {
      debugPrint('Error playing Adhan: $e');
      // Try to cleanup on error
      await stopAdhan();
    }
  }

  /// Stop Adhan playback
  static Future<void> stopAdhan() async {
    try {
      if (_adhanPlayer != null) {
        await _adhanPlayer!.stop();
        await _adhanPlayer!.dispose();
        _adhanPlayer = null;
        debugPrint('Adhan playback stopped');
      }
    } catch (e) {
      debugPrint('Error stopping Adhan: $e');
      _adhanPlayer = null;
    }
  }

  /// Get current Adhan player instance (for external control if needed)
  static AudioPlayer? get adhanPlayer => _adhanPlayer;

  /// Check if Adhan is currently playing
  static bool get isAdhanPlaying => _adhanPlayer != null;

  /// Set the Adhan sound to use
  static void setAdhanSoundForNotification(String sound) {
    _currentAdhanSound = sound;
  }

  /// Verify all notification channels are created (for debugging)
  Future<Map<String, bool>> verifyNotificationChannels() async {
    final androidImplementation =
        _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

    if (androidImplementation == null) {
      return {'error': false, 'platform': false};
    }

    // List of expected channels
    final channels = [
      _dailyReminderChannelId,
      _streakWarningChannelId,
      _completionChannelId,
      _athkarChannelId,
      _adhanChannelId,
      _dailyDuaChannelId,
      _socialChannelId,
    ];

    final results = <String, bool>{};

    // Note: flutter_local_notifications doesn't provide direct API to check channel existence
    // So we return that channels should be created (they are created in initialize)
    for (final channelId in channels) {
      results[channelId] = true; // Assumed created during initialization
    }

    return results;
  }

  /// Get list of all notification channel IDs (for reference)
  static List<String> get allChannelIds => [
    _dailyReminderChannelId,
    _streakWarningChannelId,
    _completionChannelId,
    _athkarChannelId,
    _adhanChannelId,
    _dailyDuaChannelId,
    _socialChannelId,
    _sunanChannelId,
  ];

  void _onNotificationTapped(NotificationResponse response) async {
    // Handle notification tap with deep linking
    debugPrint('Notification tapped: ${response.payload}');

    // Handle different notification types based on payload
    final payload = response.payload;

    try {
      if (navigatorKey.currentContext == null) {
        debugPrint('Navigator context not available yet');
        return;
      }

      final context = navigatorKey.currentContext!;

      if (payload != null && payload.isNotEmpty) {
        // Parse payload to determine destination
        if (payload.contains('wird') || payload == 'wird') {
          // Navigate to wird screen using GoRouter
          context.go('/wird');
        } else if (payload.startsWith('prayer')) {
          // Parse prayer notification payload: prayer|sound|prayerName
          final parts = payload.split('|');
          final sound = parts.length > 1 ? parts[1] : null;

          // Navigate to prayer times AND play Adhan
          await _playAdhanOnNotificationTap(sound);
          if (!context.mounted) return;
          context.go('/prayer-times');
        } else if (payload.contains('daily_dua') || payload == 'daily_dua') {
          // Daily dua card lives inside the athkar tab
          context.go('/athkar');
        } else if (payload.startsWith('athkar:')) {
          // Deep link to a specific category, e.g. athkar:morning / athkar:evening / athkar:sleep
          final categoryId = payload.substring('athkar:'.length).trim();
          if (categoryId.isEmpty) {
            context.go('/athkar');
          } else {
            context.go('/athkar/$categoryId');
          }
        } else if (payload.contains('athkar') || payload == 'athkar') {
          context.go('/athkar');
        } else if (payload.contains('sunan') || payload == 'sunan') {
          context.go('/sunan');
        } else if (payload.contains('social') || payload == 'social') {
          context.go('/social');
        } else if (payload.startsWith('memorization/review/')) {
          // Deep-link straight into a حلقة's review queue (reviewer/owner).
          final groupId =
              payload.substring('memorization/review/'.length).trim();
          if (groupId.isEmpty) {
            context.go('/memorization');
          } else {
            context.go('/memorization/review/$groupId');
          }
        } else if (payload.startsWith('memorization/group/')) {
          // Deep-link straight into a specific حلقة.
          final groupId =
              payload.substring('memorization/group/'.length).trim();
          if (groupId.isEmpty) {
            context.go('/memorization');
          } else {
            context.go('/memorization/group/$groupId');
          }
        } else if (payload.contains('memorization') ||
            payload == 'memorization') {
          // Deep-link straight into the memorization assistant hub.
          context.go('/memorization');
        } else if (payload.contains('home') || payload == 'home') {
          // Navigate to home
          context.go('/home');
        } else {
          // Default: navigate to home
          context.go('/home');
        }
      } else {
        // No payload: navigate to home
        context.go('/home');
      }
    } catch (e) {
      debugPrint('Error handling notification tap: $e');
      // Fallback: try to navigate to home
      try {
        if (navigatorKey.currentContext != null) {
          navigatorKey.currentContext!.go('/home');
        }
      } catch (e2) {
        debugPrint('Failed to navigate on notification tap: $e2');
      }
    }
  }
}
