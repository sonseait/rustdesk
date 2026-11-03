import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/adapters/two_factor_adapter.dart';

void main() {
  group('TrustedDevice', () {
    // These keys are the core's JSON contract. Renaming one silently produces
    // a device with no name and a zero timestamp, which then reads as expired.
    test('reads the core payload', () {
      final device = TrustedDevice.fromJson(const {
        'hwid': [1, 2, 3],
        'time': 1700000000000,
        'id': '847293160',
        'name': 'Ada workstation',
        'platform': 'Linux',
      });

      expect(device.hwid, [1, 2, 3]);
      expect(device.time, 1700000000000);
      expect(device.id, '847293160');
      expect(device.name, 'Ada workstation');
      expect(device.platform, 'Linux');
    });

    test('survives a payload missing fields', () {
      final device = TrustedDevice.fromJson(const {});

      expect(device.hwid, isEmpty);
      expect(device.time, 0);
      expect(device.id, isEmpty);
    });

    test('counts the days left in the 90-day window', () {
      final trustedAt = DateTime.utc(2026, 1, 1);
      final device = TrustedDevice(
        hwid: const [1],
        time: trustedAt.millisecondsSinceEpoch,
        id: 'id',
        name: 'name',
        platform: 'Linux',
      );

      expect(device.daysRemaining(now: trustedAt), 90);
      expect(
          device.daysRemaining(now: trustedAt.add(const Duration(days: 30))),
          60);
    });

    test('an expired device never reports negative days', () {
      final trustedAt = DateTime.utc(2026, 1, 1);
      final device = TrustedDevice(
        hwid: const [1],
        time: trustedAt.millisecondsSinceEpoch,
        id: 'id',
        name: 'name',
        platform: 'Linux',
      );

      final wellPast = trustedAt.add(const Duration(days: 200));
      expect(device.daysRemaining(now: wellPast), 0);
    });

    test('the hwid key distinguishes two devices', () {
      const a = TrustedDevice(
          hwid: [1, 2], time: 0, id: 'a', name: 'a', platform: 'Linux');
      const b = TrustedDevice(
          hwid: [1, 3], time: 0, id: 'b', name: 'b', platform: 'Linux');

      expect(a.hwidKey, isNot(b.hwidKey));
    });
  });

  group('enrolment URI', () {
    test('the secret is pulled out for manual entry', () {
      const uri = 'otpauth://totp/RustDesk:847293160'
          '?secret=JBSWY3DPEHPK3PXP&issuer=RustDesk';

      expect(TwoFactorAdapter.secretOf(uri), 'JBSWY3DPEHPK3PXP');
    });

    test('a URI without a secret yields an empty string, not a crash', () {
      expect(TwoFactorAdapter.secretOf('otpauth://totp/RustDesk'), isEmpty);
    });
  });

  group('option keys', () {
    // The core stores 2FA under these names; renaming one would leave an
    // enrolled secret behind while the UI reports 2FA as off.
    test('are the names the core stores', () {
      expect(TwoFactorAdapter.secretOptionKey, '2fa');
      expect(TwoFactorAdapter.botOptionKey, 'bot');
    });
  });
}
