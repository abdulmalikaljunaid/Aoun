import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:quran_connect/core/supa_config.dart';
import 'package:quran_connect/core/services/notification_copy_builder.dart';
import 'package:quran_connect/core/services/notification_service.dart';
import 'package:quran_connect/features/auth/services/auth_service.dart';

class RealtimeNotificationService {
  RealtimeChannel? _friendshipsChannel;
  RealtimeChannel? _socialEventsChannel;
  RealtimeChannel? _memorizationChannel;
  StreamSubscription<AuthState>? _authSubscription;
  final NotificationService _notificationService = NotificationService();
  final AuthService _auth = AuthService(SupaConfig.client);

  bool _isSubscribed = false;
  String? _subscribedUserId;

  /// Initialize Realtime subscriptions for instant notifications.
  /// Sets up an auth listener immediately so sessions restored asynchronously
  /// or future logins/token refreshes automatically subscribe.
  Future<void> initialize() async {
    // 1. Setup Auth state change listener FIRST to never miss events
    _authSubscription?.cancel();
    _authSubscription = SupaConfig.client.auth.onAuthStateChange.listen((data) {
      final event = data.event;
      final session = data.session;

      debugPrint('RealtimeNotificationService: Auth event -> $event');

      if (event == AuthChangeEvent.signedIn || event == AuthChangeEvent.initialSession) {
        if (session != null && session.user.id != _subscribedUserId) {
          debugPrint('RealtimeNotificationService: Subscribing for user ${session.user.id}');
          _resubscribe(session.user.id);
        }
      } else if (event == AuthChangeEvent.tokenRefreshed && session != null) {
        debugPrint('RealtimeNotificationService: Token refreshed, refreshing channels');
        _resubscribe(session.user.id);
      } else if (event == AuthChangeEvent.signedOut) {
        debugPrint('RealtimeNotificationService: User signed out, unsubscribing');
        _unsubscribeChannels();
      }
    });

    // 2. If a session is already present, subscribe immediately
    try {
      final userId = await _auth.getEffectiveUserId();
      if (userId != null && userId.isNotEmpty) {
        await _subscribe(userId);
      } else {
        debugPrint('RealtimeNotificationService: Waiting for user login...');
      }
    } catch (e) {
      debugPrint('RealtimeNotificationService: Initial startup check exception: $e');
    }
  }

  Future<void> _subscribe(String userId) async {
    if (_isSubscribed && _subscribedUserId == userId) return;

    _unsubscribeChannels();
    _subscribedUserId = userId;

    try {
      debugPrint('RealtimeNotificationService: Setting up realtime channels for $userId');

      // ─── 1. Friendships Channel (Requests & Acceptances) ───────────
      _friendshipsChannel = SupaConfig.client
          .channel('friendships_changes_$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'friendships',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'addressee_id',
              value: userId,
            ),
            callback: _handleFriendshipChange,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'friendships',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'requester_id',
              value: userId,
            ),
            callback: _handleFriendshipChange,
          )
          .subscribe((status, [error]) {
            debugPrint('RealtimeNotificationService: Friendships channel status: $status');
            if (error != null) {
              debugPrint('RealtimeNotificationService: Friendships channel error: $error');
            }
          });

      // ─── 2. Social Events Channel (Pokes, Nudges, Challenges, Milestones, Khatmas) ──
      _socialEventsChannel = SupaConfig.client
          .channel('social_events_changes_$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'social_events',
            callback: _handleSocialEvent,
          )
          .subscribe((status, [error]) {
            debugPrint('RealtimeNotificationService: Social events channel status: $status');
            if (error != null) {
              debugPrint('RealtimeNotificationService: Social events channel error: $error');
            }
          });

      // ─── 3. Memorization Channel (Invitations, Submissions, Review Decisions) ──
      _memorizationChannel = SupaConfig.client
          .channel('memorization_changes_$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'memorization_group_members',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: _handleGroupInvitation,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'memorization_group_submissions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'member_id',
              value: userId,
            ),
            callback: _handleSubmissionDecision,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'memorization_group_submissions',
            callback: _handleNewSubmissionForReview,
          )
          .subscribe((status, [error]) {
            debugPrint('RealtimeNotificationService: Memorization channel status: $status');
            if (error != null) {
              debugPrint('RealtimeNotificationService: Memorization channel error: $error');
            }
          });

      _isSubscribed = true;
      debugPrint('RealtimeNotificationService: ✅ All Realtime channels active for $userId');
    } catch (e) {
      debugPrint('RealtimeNotificationService: ⚠️ Error subscribing to channels: $e');
      _isSubscribed = false;
    }
  }

  void _handleFriendshipChange(PostgresChangePayload payload) {
    try {
      final record = payload.newRecord;
      final status = record['status'] as String?;
      final requesterId = record['requester_id'] as String?;
      final addresseeId = record['addressee_id'] as String?;
      final currentUser = SupaConfig.client.auth.currentUser;

      if (currentUser == null) return;

      // Case A: New friend request received
      if (payload.eventType == PostgresChangeEvent.insert &&
          status == 'pending' &&
          addresseeId == currentUser.id &&
          requesterId != currentUser.id) {
        _handleNewFriendRequest(requesterId);
      }
      // Case B: Request accepted by friend
      else if (payload.eventType == PostgresChangeEvent.update &&
          status == 'accepted' &&
          requesterId == currentUser.id &&
          addresseeId != currentUser.id) {
        _handleRequestAccepted(addresseeId);
      }
    } catch (e) {
      debugPrint('RealtimeNotificationService: Error handling friendship change: $e');
    }
  }

  Future<void> _handleNewFriendRequest(String? requesterId) async {
    if (requesterId == null) return;
    try {
      final requesterName = await _fetchProfileDisplayName(requesterId) ?? 'مستخدم';
      await _notificationService.sendFriendRequestNotification(
        requesterName,
        requesterId: requesterId,
      );
      debugPrint('RealtimeNotificationService: Notified about friend request from $requesterName');
    } catch (e) {
      debugPrint('RealtimeNotificationService: Error handling friend request: $e');
    }
  }

  Future<void> _handleRequestAccepted(String? addresseeId) async {
    if (addresseeId == null) return;
    try {
      final friendName = await _fetchProfileDisplayName(addresseeId) ?? 'صديقك';
      await _notificationService.sendFriendRequestAcceptedNotification(
        friendName,
        friendId: addresseeId,
      );
      debugPrint('RealtimeNotificationService: Notified about accepted request from $friendName');
    } catch (e) {
      debugPrint('RealtimeNotificationService: Error handling accepted request: $e');
    }
  }

  void _handleSocialEvent(PostgresChangePayload payload) async {
    try {
      final record = payload.newRecord;
      final eventType = record['event_type'] as String?;
      final jsonPayload = record['payload'] as Map<String, dynamic>?;
      final eventUserId = record['user_id'] as String?;
      final currentUser = SupaConfig.client.auth.currentUser;

      if (currentUser == null || eventType == null) return;

      // Don't notify oneself about own broadcasted actions
      if (eventUserId == currentUser.id && eventType != 'challenge_completed') {
        return;
      }

      // Case 1: Poke
      if (eventType == 'poke') {
        final targetId = jsonPayload?['target_user_id'] as String?;
        if (targetId == currentUser.id) {
          final senderName = await _fetchProfileDisplayName(eventUserId) ?? 'صديق';
          await _notificationService.showPokeNotification(
            senderName,
            isNudge: false,
            senderId: eventUserId,
          );
        }
      }
      // Case 2: Nudge
      else if (eventType == 'nudge') {
        final targetId = jsonPayload?['target_user_id'] as String?;
        if (targetId == currentUser.id) {
          final senderName = await _fetchProfileDisplayName(eventUserId) ?? 'صديق';
          await _notificationService.showPokeNotification(
            senderName,
            isNudge: true,
            senderId: eventUserId,
          );
        }
      }
      // Case 3: Quran Challenge created
      else if (eventType == 'challenge_created') {
        final challengedId = jsonPayload?['challenged_id'] as String?;
        if (challengedId == currentUser.id) {
          final challengerName = await _fetchProfileDisplayName(eventUserId) ?? 'صديق';
          final challengeType = jsonPayload?['challenge_type'] as String?;
          final targetValue = (jsonPayload?['target_value'] as num?)?.toInt();
          final challengeId = jsonPayload?['challenge_id'] as String?;

          await _notificationService.showChallengeNotification(
            challengerName: challengerName,
            challengeType: challengeType,
            targetValue: targetValue,
            challengeId: challengeId,
          );
        }
      }
      // Case 4: Challenge completed
      else if (eventType == 'challenge_completed') {
        final challengerId = jsonPayload?['challenger_id'] as String?;
        final challengedId = jsonPayload?['challenged_id'] as String?;
        if (challengerId == currentUser.id || challengedId == currentUser.id) {
          final copy = NotificationCopyBuilder.challengeCompleted();
          await _notificationService.showRemoteNotification(
            title: copy.title,
            body: copy.body,
            payload: 'social',
          );
        }
      }
      // Case 5: Friend Streak Milestone
      else if (eventType == 'milestone' || eventType == 'streak_milestone') {
        final friendId = jsonPayload?['friend_id'] as String?;
        if (friendId == currentUser.id) {
          final friendName = await _fetchProfileDisplayName(eventUserId) ?? 'صديقك';
          final milestone = (jsonPayload?['milestone'] as num?)?.toInt() ?? 0;
          final isShared = jsonPayload?['is_shared'] as bool? ?? true;

          await _notificationService.sendFriendStreakMilestoneNotification(
            friendName,
            milestone,
            isShared,
          );
        }
      }
      // Case 6: Khatma completed by a friend
      else if (eventType == 'khatma_completed') {
        final isFriend = await _isFriend(currentUser.id, eventUserId);
        if (isFriend) {
          final friendName = await _fetchProfileDisplayName(eventUserId) ?? 'أحد أصدقائك';
          await _notificationService.showFriendKhatmaNotification(
            friendName,
            friendId: eventUserId,
          );
        }
      }
    } catch (e) {
      debugPrint('RealtimeNotificationService: Error handling social event: $e');
    }
  }

  Future<void> _handleGroupInvitation(PostgresChangePayload payload) async {
    try {
      final record = payload.newRecord;
      final status = record['status'] as String?;
      final groupId = record['group_id'] as String?;
      if (status != 'invited' || groupId == null) return;

      final groupName = await _fetchGroupName(groupId);
      final rangeLabel = await _fetchGroupRangeLabel(groupId);

      await _notificationService.showGroupInvitationNotification(
        groupName,
        groupId: groupId,
        rangeLabel: rangeLabel,
      );
      debugPrint('RealtimeNotificationService: Notified about invitation to $groupName');
    } catch (e) {
      debugPrint('RealtimeNotificationService: Error handling invitation: $e');
    }
  }

  Future<void> _handleSubmissionDecision(PostgresChangePayload payload) async {
    try {
      final record = payload.newRecord;
      final decisionType = record['decision_type'] as String?;
      final groupId = record['group_id'] as String?;
      if (decisionType == null || groupId == null) return;

      final oldDecision = payload.oldRecord['decision_type'] as String?;
      if (oldDecision == decisionType) return;

      final groupName = await _fetchGroupName(groupId);
      final rangeLabel = await _fetchSubmissionRangeLabel(record, groupId);
      final hasVoiceNote = (record['reviewer_voice_url'] as String?)?.isNotEmpty == true;

      await _notificationService.showReviewDecisionNotification(
        groupName,
        NotificationCopyBuilder.parseDecision(decisionType),
        rangeLabel: rangeLabel,
        groupId: groupId,
        hasVoiceNote: hasVoiceNote,
      );
      debugPrint('RealtimeNotificationService: Notified about decision in $groupName');
    } catch (e) {
      debugPrint('RealtimeNotificationService: Error handling decision: $e');
    }
  }

  Future<void> _handleNewSubmissionForReview(PostgresChangePayload payload) async {
    try {
      final record = payload.newRecord;
      final status = record['status'] as String?;
      final groupId = record['group_id'] as String?;
      final submitterId = record['member_id'] as String?;
      final currentUser = SupaConfig.client.auth.currentUser;

      if (currentUser == null || groupId == null || status != 'waiting_review') return;
      if (submitterId == currentUser.id) return; // Don't notify the student about their own submission

      // Check if the current user is the owner or an active reviewer of this group
      final isReviewer = await _isUserReviewerOrOwner(groupId, currentUser.id);
      if (!isReviewer) return;

      final groupName = await _fetchGroupName(groupId);
      final submitterName = await _fetchProfileDisplayName(submitterId) ?? 'أحد الطلاب';
      final rangeLabel = await _fetchSubmissionRangeLabel(record, groupId);

      await _notificationService.showNewSubmissionForReviewNotification(
        groupName,
        1,
        memberName: submitterName,
        rangeLabel: rangeLabel,
        groupId: groupId,
      );
      debugPrint('RealtimeNotificationService: Reviewer notified of new submission in $groupName');
    } catch (e) {
      debugPrint('RealtimeNotificationService: Error handling reviewer notification: $e');
    }
  }

  // ─── Helpers & Database Query Utilities ───────────────────────────────

  Future<bool> _isUserReviewerOrOwner(String groupId, String userId) async {
    try {
      // 1. Check if owner
      final groupRow = await SupaConfig.client
          .from('memorization_groups')
          .select('owner_id')
          .eq('id', groupId)
          .maybeSingle();

      if (groupRow?['owner_id'] == userId) return true;

      // 2. Check if reviewer member
      final memberRow = await SupaConfig.client
          .from('memorization_group_members')
          .select('role, status')
          .eq('group_id', groupId)
          .eq('user_id', userId)
          .maybeSingle();

      return memberRow?['status'] == 'active' &&
          (memberRow?['role'] == 'reviewer' || memberRow?['role'] == 'admin');
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isFriend(String userId1, String? userId2) async {
    if (userId2 == null || userId1 == userId2) return false;
    try {
      final res = await SupaConfig.client
          .from('friendships')
          .select('id')
          .eq('status', 'accepted')
          .or('and(requester_id.eq.$userId1,addressee_id.eq.$userId2),and(requester_id.eq.$userId2,addressee_id.eq.$userId1)')
          .maybeSingle();
      return res != null;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _fetchProfileDisplayName(String? userId) async {
    if (userId == null) return null;
    try {
      final response = await SupaConfig.client
          .from('profiles')
          .select('display_name')
          .eq('id', userId)
          .maybeSingle();
      return (response?['display_name'] as String?)?.trim();
    } catch (_) {
      return null;
    }
  }

  Future<String> _fetchGroupName(String groupId) async {
    try {
      final row = await SupaConfig.client
          .from('memorization_groups')
          .select('name')
          .eq('id', groupId)
          .maybeSingle();
      return (row?['name'] as String?)?.trim().isNotEmpty == true
          ? row!['name'] as String
          : 'حلقة';
    } catch (_) {
      return 'حلقة';
    }
  }

  Future<String?> _fetchGroupRangeLabel(String groupId) async {
    try {
      final row = await SupaConfig.client
          .from('memorization_groups')
          .select('surah_name_ar, from_ayah, to_ayah')
          .eq('id', groupId)
          .maybeSingle();
      if (row == null) return null;
      final surahName = (row['surah_name_ar'] as String?)?.trim();
      final from = (row['from_ayah'] as num?)?.toInt();
      final to = (row['to_ayah'] as num?)?.toInt();
      if (surahName == null || surahName.isEmpty || from == null || to == null) {
        return null;
      }
      final range = from == to ? '$from' : '$from–$to';
      return '$surahName $range';
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetchSubmissionRangeLabel(
    Map<String, dynamic> record,
    String groupId,
  ) async {
    final from = (record['from_ayah'] as num?)?.toInt();
    final to = (record['to_ayah'] as num?)?.toInt();
    if (from == null || to == null) return null;

    String? surahName;
    try {
      final groupRow = await SupaConfig.client
          .from('memorization_groups')
          .select('surah_name_ar')
          .eq('id', groupId)
          .maybeSingle();
      surahName = (groupRow?['surah_name_ar'] as String?)?.trim();
    } catch (_) {
      surahName = null;
    }

    final ayahPart = from == to ? 'الآية $from' : 'الآيات $from–$to';
    if (surahName != null && surahName.isNotEmpty) {
      final range = from == to ? '$from' : '$from–$to';
      return '$surahName $range';
    }
    return ayahPart;
  }

  void _unsubscribeChannels() {
    _friendshipsChannel?.unsubscribe();
    _friendshipsChannel = null;
    _socialEventsChannel?.unsubscribe();
    _socialEventsChannel = null;
    _memorizationChannel?.unsubscribe();
    _memorizationChannel = null;
    _isSubscribed = false;
    _subscribedUserId = null;
    debugPrint('RealtimeNotificationService: Channels unsubscribed');
  }

  Future<void> _resubscribe(String userId) async {
    _unsubscribeChannels();
    await Future.delayed(const Duration(milliseconds: 300));
    await _subscribe(userId);
  }

  void dispose() {
    _authSubscription?.cancel();
    _authSubscription = null;
    _unsubscribeChannels();
    debugPrint('RealtimeNotificationService: Disposed');
  }
}
