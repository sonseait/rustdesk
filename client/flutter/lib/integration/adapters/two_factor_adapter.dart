import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// A device that passed two-factor verification and was trusted afterwards.
///
/// Ported from `TrustedDevice` in
/// `flutter_legacy/lib/common/widgets/dialog.dart`. The JSON keys are the
/// core's contract, and `hwid` is the identifier the core matches on when
/// removing one, so neither may be renamed.
@immutable
class TrustedDevice {
  const TrustedDevice({
    required this.hwid,
    required this.time,
    required this.id,
    required this.name,
    required this.platform,
  });

  factory TrustedDevice.fromJson(Map<String, dynamic> json) => TrustedDevice(
        hwid: List<int>.unmodifiable(
            (json['hwid'] as List<dynamic>? ?? const []).cast<int>()),
        time: json['time'] as int? ?? 0,
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
      );

  /// The hardware id the core keys this device on.
  final List<int> hwid;

  /// When the device was trusted, in milliseconds since the epoch.
  final int time;

  final String id;
  final String name;
  final String platform;

  /// How long the core keeps a trusted device before it must verify again.
  static const trustDuration = Duration(days: 90);

  /// Whole days left before this device has to verify again, never negative.
  ///
  /// [now] is injectable so a test does not depend on the wall clock.
  int daysRemaining({DateTime? now}) {
    final expiry = time + trustDuration.inMilliseconds;
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final remaining = expiry - at;
    if (remaining <= 0) return 0;
    return (remaining / Duration.millisecondsPerDay).round();
  }

  bool get isExpired => daysRemaining() == 0;

  /// A stable key for selection, since [hwid] is a list and compares by
  /// identity.
  String get hwidKey => hwid.join(',');
}

/// Two-factor authentication, its Telegram bot, and the trusted devices it
/// issues.
///
/// Wraps the existing bridge calls without changing what they mean: enabling
/// 2FA verifies a generated secret, and disabling it clears the trusted devices
/// too, the way the legacy dialog did — a trusted device would otherwise let a
/// re-enabled 2FA be skipped.
class TwoFactorAdapter extends ChangeNotifier {
  TwoFactorAdapter();

  static final TwoFactorAdapter instance = TwoFactorAdapter();

  /// The option key the core stores the 2FA secret under.
  static const String secretOptionKey = '2fa';

  /// The option key the core stores the Telegram bot token under.
  static const String botOptionKey = 'bot';

  // -------------------------------------------------------------- reading

  /// Whether 2FA is configured. Synchronous because the core caches it.
  bool get isEnabled {
    try {
      return bind.mainHasValid2FaSync();
    } catch (e) {
      debugPrint('failed to read the 2FA state: $e');
      return false;
    }
  }

  /// Whether a Telegram bot is configured for verification codes.
  bool get hasBot {
    try {
      return bind.mainHasValidBotSync();
    } catch (e) {
      debugPrint('failed to read the bot state: $e');
      return false;
    }
  }

  // ------------------------------------------------------------------ 2FA

  /// Start enrolment and return the `otpauth://` URI to show as a QR code.
  ///
  /// Returns an empty string when the core could not generate one.
  Future<String> generateSecret() async {
    try {
      return await bind.mainGenerate2Fa();
    } catch (e) {
      debugPrint('failed to generate a 2FA secret: $e');
      return '';
    }
  }

  /// The `secret=` parameter of an enrolment URI, for people who cannot scan
  /// the QR code.
  static String secretOf(String enrolmentUri) =>
      RegExp(r'secret=([^&]+)').firstMatch(enrolmentUri)?.group(1) ?? '';

  /// Confirm enrolment with the code from the authenticator app.
  ///
  /// 2FA is only on once the core accepts a code, so a wrong code leaves it
  /// off rather than half-configured.
  Future<bool> verify(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return false;
    try {
      final ok = await bind.mainVerify2Fa(code: trimmed);
      if (ok) notifyListeners();
      return ok;
    } catch (e) {
      debugPrint('failed to verify the 2FA code: $e');
      return false;
    }
  }

  /// Turn 2FA off.
  ///
  /// The trusted devices go with it: they exist to skip 2FA, so leaving them
  /// behind would let them skip a later re-enrolment.
  Future<void> disable() async {
    try {
      await bind.mainSetOption(key: secretOptionKey, value: '');
      await bind.mainClearTrustedDevices();
      notifyListeners();
    } catch (e) {
      debugPrint('failed to disable 2FA: $e');
    }
  }

  // ------------------------------------------------------------------ bot

  /// Register a Telegram bot token.
  ///
  /// Returns null on success, otherwise the core's translation key for the
  /// problem.
  Future<String?> verifyBot(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return 'Empty Value';
    try {
      final error = await bind.mainVerifyBot(token: trimmed);
      if (error.isEmpty) {
        notifyListeners();
        return null;
      }
      return error;
    } catch (e) {
      debugPrint('failed to verify the bot token: $e');
      return 'Failed';
    }
  }

  Future<void> removeBot() async {
    try {
      await bind.mainSetOption(key: botOptionKey, value: '');
      notifyListeners();
    } catch (e) {
      debugPrint('failed to remove the bot: $e');
    }
  }

  // ------------------------------------------------------- trusted devices

  /// The trusted devices, newest first.
  Future<List<TrustedDevice>> trustedDevices() async {
    try {
      final payload = await bind.mainGetTrustedDevices();
      if (payload.isEmpty) return const [];
      final decoded = jsonDecode(payload);
      if (decoded is! List) return const [];
      final devices = [
        for (final device in decoded)
          if (device is Map<String, dynamic>) TrustedDevice.fromJson(device)
      ];
      devices.sort((a, b) => b.time.compareTo(a.time));
      return devices;
    } catch (e) {
      debugPrint('failed to read the trusted devices: $e');
      return const [];
    }
  }

  /// Remove [devices].
  ///
  /// Removing every device uses the core's clear call, matching the legacy
  /// dialog; the core treats that as a full reset rather than a list of
  /// removals.
  Future<void> removeTrustedDevices(
    List<TrustedDevice> devices, {
    required int total,
  }) async {
    if (devices.isEmpty) return;
    try {
      if (devices.length >= total) {
        await bind.mainClearTrustedDevices();
      } else {
        await bind.mainRemoveTrustedDevices(
            json: jsonEncode([for (final device in devices) device.hwid]));
      }
      notifyListeners();
    } catch (e) {
      debugPrint('failed to remove trusted devices: $e');
    }
  }

  Future<void> clearTrustedDevices() async {
    try {
      await bind.mainClearTrustedDevices();
      notifyListeners();
    } catch (e) {
      debugPrint('failed to clear the trusted devices: $e');
    }
  }
}
