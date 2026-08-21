/// Central app metadata: name, version, and developer contact.
///
/// Single source of truth for branding and attribution shown across the app
/// (settings footer, about section). Keep [appVersion] in sync with
/// `pubspec.yaml`.
abstract final class AppInfo {
  static const String appName = 'عون';

  /// Display version, synced with `pubspec.yaml` (`version: 1.3.0+4`).
  static const String appVersion = '1.3.0';

  static const String developerName = 'عبدالملك الجنيد';

  /// WhatsApp number in E.164 digits (no `+`), as required by wa.me links.
  static const String developerWhatsAppE164 = '967774843888';

  static const String _whatsAppGreeting = 'السلام عليكم، أتواصل معك من تطبيق عون';

  /// Opens a WhatsApp chat with the developer, pre-filled with a greeting.
  static Uri get developerWhatsAppUri => Uri.https(
        'wa.me',
        '/$developerWhatsAppE164',
        {'text': _whatsAppGreeting},
      );
}
