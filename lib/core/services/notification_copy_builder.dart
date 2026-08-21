/// Normalized reviewer-decision kind for memorization notifications.
///
/// Kept independent of the feature-layer `GroupReviewDecisionType` enum and of
/// the Supabase `decision_type` strings so that all notification copy lives in
/// one pure, testable place and stays consistent between the local
/// [NotificationService] and the realtime listener.
enum MemorizationDecisionKind {
  accepted,
  acceptedWithNotes,
  retryAyah,
  retryAssignment,
  unknown,
}

/// A notification's title and body. Immutable value object.
class NotificationCopy {
  final String title;
  final String body;

  const NotificationCopy({required this.title, required this.body});
}

/// Pure builder for Aoun notification copy across social, memorization, and reminders.
abstract final class NotificationCopyBuilder {
  /// Maps a raw decision string to a [MemorizationDecisionKind].
  static MemorizationDecisionKind parseDecision(String? raw) {
    switch (raw) {
      case 'accepted':
        return MemorizationDecisionKind.accepted;
      case 'accepted_with_notes':
      case 'acceptedWithNotes':
        return MemorizationDecisionKind.acceptedWithNotes;
      case 'retry_ayah':
      case 'retryAyah':
        return MemorizationDecisionKind.retryAyah;
      case 'retry_assignment':
      case 'retryAssignment':
        return MemorizationDecisionKind.retryAssignment;
      default:
        return MemorizationDecisionKind.unknown;
    }
  }

  /// Reviewer-facing: a member submitted a recitation awaiting review.
  static NotificationCopy newSubmissionForReview({
    required String groupName,
    required int pendingCount,
    String? memberName,
    String? rangeLabel,
  }) {
    const title = 'تسميع جديد بانتظارك 🎙️';
    final String body;
    if (memberName != null && rangeLabel != null) {
      body = '$memberName أرسل $rangeLabel في حلقة «$groupName»';
    } else if (rangeLabel != null) {
      body =
          'تسميع جديد ($rangeLabel) في حلقة «$groupName» — بانتظار المراجعة ($pendingCount)';
    } else {
      body =
          'وصل تسميع جديد في حلقة «$groupName» — بانتظار المراجعة ($pendingCount)';
    }
    return NotificationCopy(title: title, body: body);
  }

  /// Member-facing: the reviewer recorded a decision on the member's تسميع.
  static NotificationCopy reviewDecision({
    required String groupName,
    required MemorizationDecisionKind kind,
    String? rangeLabel,
    bool hasVoiceNote = false,
  }) {
    final String title;
    switch (kind) {
      case MemorizationDecisionKind.accepted:
        title = 'تم قبول تسميعك في حلقة $groupName ✅';
      case MemorizationDecisionKind.acceptedWithNotes:
        title = 'قُبل تسميعك مع ملاحظة في حلقة $groupName 📝';
      case MemorizationDecisionKind.retryAyah:
        title = 'أعد آية في حلقة $groupName 🔁';
      case MemorizationDecisionKind.retryAssignment:
        title = 'أعد الورد في حلقة $groupName 🔁';
      case MemorizationDecisionKind.unknown:
        title = 'قرار المراجع على تسميعك في حلقة $groupName';
    }
    var body = rangeLabel ?? 'افتح مساعد الحفظ لمتابعة قرار المراجع.';
    if (hasVoiceNote) {
      body = '$body\n🎙️ استمع لملاحظة المراجع الصوتية.';
    }
    return NotificationCopy(title: title, body: body);
  }

  /// Member-facing: an invitation to join a private memorization حلقة.
  static NotificationCopy groupInvitation({
    required String groupName,
    String? rangeLabel,
  }) {
    final String body;
    if (rangeLabel != null && rangeLabel.isNotEmpty) {
      body =
          'دعوة لحلقة «$groupName»\nورد البداية: $rangeLabel\nافتح مساعد الحفظ للانضمام.';
    } else {
      body = 'تمت دعوتك للانضمام إلى حلقة «$groupName». افتح مساعد الحفظ للبدء.';
    }
    return NotificationCopy(title: 'دعوة لحلقة حفظ 🕌', body: body);
  }

  /// Social: New friend request
  static NotificationCopy friendRequest(String requesterName) {
    return NotificationCopy(
      title: 'طلب صداقة جديد 👋',
      body: '$requesterName أرسل لك طلب صداقة على تطبيق عون.',
    );
  }

  /// Social: Friend request accepted
  static NotificationCopy friendRequestAccepted(String friendName) {
    return NotificationCopy(
      title: 'تم قبول طلب الصداقة! 🎉',
      body: '$friendName قبل طلب صداقتك. ابدأوا التنافس والستريك المشترك الآن!',
    );
  }

  /// Social: Poke or Nudge from a friend
  static NotificationCopy pokeOrNudge(String friendName, {bool isNudge = false}) {
    if (isNudge) {
      return NotificationCopy(
        title: 'تذكير بالورد من $friendName ⏰',
        body: 'يذكّرك $friendName بقراءة وردك اليوم للحفاظ على الستريك المشترك 🔥',
      );
    }
    return NotificationCopy(
      title: 'نكزة تشجيع من $friendName ✨',
      body: 'قام $friendName بنكزك للتذكير بالورد اليومي. لا تكسر الستريك!',
    );
  }

  /// Social: Quran Challenge created
  static NotificationCopy challengeCreated({
    required String challengerName,
    String? challengeType,
    int? targetValue,
  }) {
    final targetStr = targetValue != null ? ' ($targetValue صفحة/آية)' : '';
    return NotificationCopy(
      title: 'تحدي قرآني جديد! 🏆',
      body: 'أرسل لك $challengerName تحدياً قرآنياً جديداً$targetStr. هل تقبل التحدي؟',
    );
  }

  /// Social: Quran Challenge completed
  static NotificationCopy challengeCompleted() {
    return const NotificationCopy(
      title: 'اكتمل التحدي القرآني! 🏅',
      body: 'مبارك! تم إكمال التحدي القرآني المشترك بنجاح. بارك الله في همتكم!',
    );
  }

  /// Social: Friend completed Khatma
  static NotificationCopy khatmaCompleted(String friendName) {
    return NotificationCopy(
      title: 'مبارك الختمة! 📖✨',
      body: 'أتم $friendName ختم القرآن الكريم كاملًا، بارك الله له وعقباك!',
    );
  }

  /// Social: Friend streak milestone
  static NotificationCopy streakMilestone({
    required String friendName,
    required int milestone,
    required bool isShared,
  }) {
    final streakType = isShared ? 'المشترك' : 'الفردي';
    return NotificationCopy(
      title: 'معلم جديد في الستريك! 🔥',
      body: 'وصلت أنت و$friendName إلى $milestone يوم في الستريك $streakType! استمروا!',
    );
  }
}
