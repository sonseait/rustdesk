import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';

/// The encoding rules are pure, so they are tested directly against the
/// legacy semantics without a live bridge.
void main() {
  group('option2bool', () {
    test('enable- keys default to on when unset', () {
      expect(OptionRepository.option2bool(kOptionEnableAudio, ''), isTrue);
      expect(OptionRepository.option2bool(kOptionEnableAudio, 'Y'), isTrue);
      expect(OptionRepository.option2bool(kOptionEnableAudio, 'N'), isFalse);
    });

    test('allow- keys default to off when unset', () {
      expect(OptionRepository.option2bool(kOptionAllowAutoUpdate, ''), isFalse);
      expect(OptionRepository.option2bool(kOptionAllowAutoUpdate, 'Y'), isTrue);
      expect(OptionRepository.option2bool(kOptionAllowAutoUpdate, 'N'), isFalse);
    });

    test('the three explicit off-by-default keys behave like allow-', () {
      for (final key in [
        kOptionStopService,
        kOptionDirectServer,
        kOptionForceAlwaysRelay,
      ]) {
        expect(OptionRepository.option2bool(key, ''), isFalse, reason: key);
        expect(OptionRepository.option2bool(key, 'Y'), isTrue, reason: key);
        expect(OptionRepository.option2bool(key, 'N'), isFalse, reason: key);
      }
    });

    test('other keys treat unset as on', () {
      expect(OptionRepository.option2bool(kOptionViewOnly, ''), isTrue);
      expect(OptionRepository.option2bool(kOptionViewOnly, 'N'), isFalse);
    });
  });

  group('bool2option on the stock client', () {
    // The stock client writes '' rather than an explicit default.
    final repo = _StubRepository(isCustom: false);

    test('enable- keys write empty for true and N for false', () {
      expect(repo.bool2option(kOptionEnableAudio, true), '');
      expect(repo.bool2option(kOptionEnableAudio, false), 'N');
    });

    test('allow- keys write Y for true and empty for false', () {
      expect(repo.bool2option(kOptionAllowAutoUpdate, true), 'Y');
      expect(repo.bool2option(kOptionAllowAutoUpdate, false), '');
    });

    test('the punch keys are excluded from the enable- branch', () {
      // Deliberate legacy asymmetry: these enable- keys round-trip through
      // the plain Y/N branch, not the enable- branch.
      expect(repo.bool2option(kOptionEnableUdpPunch, true), 'Y');
      expect(repo.bool2option(kOptionEnableUdpPunch, false), 'N');
      expect(repo.bool2option(kOptionEnableIpv6Punch, true), 'Y');
      expect(repo.bool2option(kOptionEnableIpv6Punch, false), 'N');
    });
  });

  group('bool2option on a custom client', () {
    final repo = _StubRepository(isCustom: true);

    test('enable- keys write an explicit Y', () {
      expect(repo.bool2option(kOptionEnableAudio, true), 'Y');
      expect(repo.bool2option(kOptionEnableAudio, false), 'N');
    });

    test('allow- keys write an explicit N', () {
      expect(repo.bool2option(kOptionAllowAutoUpdate, true), 'Y');
      expect(repo.bool2option(kOptionAllowAutoUpdate, false), 'N');
    });
  });

  group('encoding round-trips', () {
    test('every bool option key survives a write/read cycle', () {
      const keys = [
        kOptionEnableAudio,
        kOptionEnableKeyboard,
        kOptionEnableClipboard,
        kOptionEnableFileTransfer,
        kOptionEnableRemotePrinter,
        kOptionEnableTerminal,
        kOptionAllowAutoUpdate,
        kOptionAllowAutoDisconnect,
        kOptionAllowRemoveWallpaper,
        kOptionAllowWebSocket,
        kOptionStopService,
        kOptionDirectServer,
        kOptionForceAlwaysRelay,
        kOptionViewOnly,
        kOptionEnableUdpPunch,
        kOptionEnableIpv6Punch,
      ];

      for (final custom in [false, true]) {
        final repo = _StubRepository(isCustom: custom);
        for (final key in keys) {
          for (final value in [true, false]) {
            final encoded = repo.bool2option(key, value);
            expect(
              OptionRepository.option2bool(key, encoded),
              value,
              reason: 'key=$key value=$value custom=$custom '
                  'encoded="$encoded"',
            );
          }
        }
      }
    });
  });

  group('platform availability', () {
    test('windows-only capture options are gated off other hosts', () {
      // The suite runs on the host platform; assert the mapping is declared
      // rather than assuming a specific host.
      const windowsOnly = [kOptionDirectxCapture, kOptionD3DRender];
      for (final key in windowsOnly) {
        expect(OptionRepository.isSupportedHere(key),
            OptionRepository.isSupportedHere(kOptionDirectxCapture),
            reason: key);
      }
    });

    test('unlisted keys are supported everywhere', () {
      expect(OptionRepository.isSupportedHere(kOptionEnableAudio), isTrue);
      expect(OptionRepository.isSupportedHere(kOptionAllowAutoUpdate), isTrue);
    });
  });

  group('OptionState', () {
    test('is editable only without a lock', () {
      expect(
        const OptionState(value: true, lock: OptionLock.none).isEditable,
        isTrue,
      );
      for (final lock in [
        OptionLock.fixed,
        OptionLock.managed,
        OptionLock.unsupported,
      ]) {
        expect(OptionState(value: true, lock: lock).isEditable, isFalse,
            reason: '$lock');
      }
    });
  });
}

/// Exercises the encoding rules without touching the native bridge.
class _StubRepository extends OptionRepository {
  _StubRepository({required this.isCustom});

  final bool isCustom;

  @override
  bool get isCustomClient => isCustom;
}
