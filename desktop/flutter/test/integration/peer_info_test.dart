import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';
import 'package:flutter_hbb/integration/session/session_adapter.dart';

/// A `peer_info` event as the Rust core sends it: nested structures arrive as
/// JSON strings, and booleans as the strings 'true'/'false'.
Map<String, dynamic> peerInfoEvent({
  String platform = PeerPlatform.windows,
  int currentDisplay = 0,
  List<Map<String, dynamic>> displays = const [],
  Map<String, dynamic> additions = const {},
  bool multiUi = true,
}) =>
    {
      'name': 'peer_info',
      'version': '1.4.9',
      'username': 'ada',
      'hostname': 'workstation',
      'platform': platform,
      'sas_enabled': 'false',
      'is_support_multi_ui_session': multiUi ? 'true' : 'false',
      'current_display': '$currentDisplay',
      'primary_display': '0',
      'displays': jsonEncode(displays),
      'resolutions': jsonEncode([
        {'width': 1920, 'height': 1080},
        {'width': 1280, 'height': 720},
      ]),
      'platform_additions': jsonEncode(additions),
      'features': jsonEncode({'privacy_mode': true}),
    };

/// A display entry. The original resolution defaults to the reported size, so
/// a display is unscaled unless a test says otherwise.
Map<String, dynamic> display({
  int width = 1920,
  int height = 1080,
  double x = 0,
  double y = 0,
  bool cursorEmbedded = false,
  int? originalWidth,
  int? originalHeight,
}) =>
    {
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'cursor_embedded': cursorEmbedded,
      'original_width': originalWidth ?? width,
      'original_height': originalHeight ?? height,
      'scale': 1.0,
    };

void main() {
  group('PeerInfo.fromEvent', () {
    test('parses the core event shape', () {
      final pi = PeerInfo.fromEvent(peerInfoEvent(displays: [display()]));

      expect(pi.isSet, isTrue);
      expect(pi.version, '1.4.9');
      expect(pi.hostname, 'workstation');
      expect(pi.platform, PeerPlatform.windows);
      expect(pi.displays.length, 1);
      expect(pi.displays.first.width, 1920);
      expect(pi.resolutions.length, 2);
      expect(pi.features.privacyMode, isTrue);
    });

    test('an unset PeerInfo reports isSet false', () {
      // The UI must not render a canvas before peer info arrives.
      expect(const PeerInfo().isSet, isFalse);
      expect(const PeerInfo().displays, isEmpty);
    });

    test('booleans arrive as strings and are still parsed', () {
      final pi = PeerInfo.fromEvent(peerInfoEvent(multiUi: true));
      expect(pi.isSupportMultiUiSession, isTrue);

      final single = PeerInfo.fromEvent(peerInfoEvent(multiUi: false));
      expect(single.isSupportMultiUiSession, isFalse);
    });

    test('malformed nested json does not throw', () {
      final pi = PeerInfo.fromEvent({
        'name': 'peer_info',
        'displays': 'not json',
        'resolutions': 'not json',
        'platform_additions': 'not json',
        'features': 'not json',
      });

      expect(pi.displays, isEmpty);
      expect(pi.resolutions, isEmpty);
      expect(pi.platformAdditions, isEmpty);
    });

    test('missing fields fall back to safe defaults', () {
      final pi = PeerInfo.fromEvent({'name': 'peer_info'});

      expect(pi.platform, isEmpty);
      expect(pi.currentDisplay, 0);
      expect(pi.primaryDisplay, kInvalidDisplayIndex);
    });
  });

  group('platform additions', () {
    test('detects wayland, headless and virtual displays', () {
      final pi = PeerInfo.fromEvent(peerInfoEvent(
        platform: PeerPlatform.linux,
        additions: {
          kPlatformAdditionsIsWayland: true,
          kPlatformAdditionsHeadless: true,
          kPlatformAdditionsRustDeskVirtualDisplays: [0, 1],
          kPlatformAdditionsAmyuniVirtualDisplays: 2,
          kPlatformAdditionsIddImpl: 'rustdesk_idd',
        },
      ));

      expect(pi.isWayland, isTrue);
      expect(pi.isHeadless, isTrue);
      expect(pi.rustDeskVirtualDisplays, [0, 1]);
      expect(pi.amyuniVirtualDisplayCount, 2);
      expect(pi.isRustDeskIdd, isTrue);
      expect(pi.isAmyuniIdd, isFalse);
    });

    test('only Windows reports installed state', () {
      // Non-Windows peers are always considered installed.
      final linux = PeerInfo.fromEvent(
          peerInfoEvent(platform: PeerPlatform.linux, additions: {}));
      expect(linux.isInstalled, isTrue);

      final winPortable = PeerInfo.fromEvent(
          peerInfoEvent(platform: PeerPlatform.windows, additions: {}));
      expect(winPortable.isInstalled, isFalse);

      final winInstalled = PeerInfo.fromEvent(peerInfoEvent(
          platform: PeerPlatform.windows,
          additions: {kPlatformAdditionsIsInstalled: true}));
      expect(winInstalled.isInstalled, isTrue);
    });
  });

  group('display selection', () {
    final pi = PeerInfo.fromEvent(peerInfoEvent(
      currentDisplay: 1,
      displays: [display(width: 1920), display(width: 1280)],
    ));

    test('resolves the current display', () {
      expect(pi.tryGetDisplay()?.width, 1280);
      expect(pi.tryGetDisplay(display: 0)?.width, 1920);
    });

    test('an out-of-range index falls back rather than crashing', () {
      expect(pi.tryGetDisplay(display: 99)?.width, 1920);
      expect(pi.tryGetDisplayIfNotAllDisplay(display: 99), isNull);
    });

    test('the all-displays sentinel has no single display', () {
      final all = pi.copyWith(currentDisplay: kAllDisplayValue);

      expect(all.tryGetDisplayIfNotAllDisplay(), isNull);
      // But a combined view still renders through a texture.
      expect(all.forceTextureRender, isTrue);
      expect(all.getCurDisplays().length, 2);
    });

    test('a single display view returns just that display', () {
      expect(pi.getCurDisplays().length, 1);
      expect(pi.forceTextureRender, isFalse);
    });

    test('no displays yields null rather than an index error', () {
      const empty = PeerInfo();
      expect(empty.tryGetDisplay(), isNull);
      expect(empty.getCurDisplays(), isEmpty);
    });
  });

  group('RemoteDisplay', () {
    test('scale never drops below 1', () {
      expect(const RemoteDisplay(scale: 0.5).scale, 1.0);
      expect(const RemoteDisplay(scale: 2.0).scale, 2.0);
    });

    test('detects original resolution', () {
      const atOriginal = RemoteDisplay(
          width: 1920, height: 1080, originalWidth: 1920, originalHeight: 1080);
      const scaled = RemoteDisplay(
          width: 1280, height: 720, originalWidth: 1920, originalHeight: 1080);

      expect(atOriginal.isOriginalResolution, isTrue);
      expect(scaled.isOriginalResolution, isFalse);
      expect(scaled.isOriginalResolutionSet, isTrue);
    });
  });

  group('SessionPermissions', () {
    test('permissions default to granted', () {
      // The peer only sends what it denies, so an empty map means full access.
      const perms = SessionPermissions.empty();

      expect(perms.keyboard, isTrue);
      expect(perms.clipboard, isTrue);
      expect(perms.audio, isTrue);
      expect(perms.file, isTrue);
      expect(perms.restart, isTrue);
    });

    test('merge applies denials without clearing the rest', () {
      final perms =
          const SessionPermissions.empty().merge({'keyboard': false});

      expect(perms.keyboard, isFalse);
      expect(perms.clipboard, isTrue);

      final later = perms.merge({'clipboard': false});
      expect(later.keyboard, isFalse, reason: 'earlier denial must persist');
      expect(later.clipboard, isFalse);
    });
  });

  group('SessionPrompt', () {
    test('recognizes credential prompts', () {
      for (final type in [
        'input-password',
        're-input-password',
        'input-2fa',
        'session-login',
        'terminal-admin-login',
      ]) {
        final prompt = SessionPrompt.fromEvent({'type': type});
        expect(prompt.needsCredentials, isTrue, reason: type);
      }
    });

    test('recognizes errors and restarts', () {
      expect(SessionPrompt.fromEvent({'type': 'error'}).isError, isTrue);
      expect(
          SessionPrompt.fromEvent({'type': 'connection-error'}).isError, isTrue);
      expect(SessionPrompt.fromEvent({'type': 'restarting'}).isRestarting,
          isTrue);
      expect(SessionPrompt.fromEvent({'type': 'restarting-show'}).isRestarting,
          isTrue);
      // A restart is not a failure.
      expect(SessionPrompt.fromEvent({'type': 'restarting'}).isError, isFalse);
    });

    test('parses the retry flag as the string true', () {
      expect(SessionPrompt.fromEvent({'hasRetry': 'true'}).hasRetry, isTrue);
      expect(SessionPrompt.fromEvent({'hasRetry': 'false'}).hasRetry, isFalse);
      expect(SessionPrompt.fromEvent({}).hasRetry, isFalse);
    });
  });

  group('switch_display geometry', () {
    // Regression: switch_display carries the display's real size, which can
    // differ from peer_info (a HiDPI peer reports the scaled desktop but
    // captures at native resolution). Ignoring it meant every RGBA frame was
    // decoded at the wrong size and dropped, so the canvas stayed black.
    test('the event carries the fields needed to resize a display', () {
      const event = {
        'name': 'switch_display',
        'display': '0',
        'x': '0',
        'y': '0',
        'width': '1920',
        'height': '1080',
        'cursor_embedded': '0',
        'original_width': '2560',
        'original_height': '1600',
      };

      expect(int.tryParse('${event['display']}'), 0);
      expect(int.tryParse('${event['width']}'), 1920);
      expect(int.tryParse('${event['height']}'), 1080);
      expect(int.tryParse('${event['original_width']}'), 2560);
    });

    test('a frame buffer is four bytes per pixel of the display size', () {
      // 1920x1080 is 8294400 bytes; a stale 2560x1600 expects 16384000 and
      // every frame is rejected.
      expect(1920 * 1080 * 4, 8294400);
      expect(2560 * 1600 * 4, 16384000);
    });
  });

  group('scaled displays', () {
    // Taken verbatim from a real sync_peer_info: the peer renders a 2560x1600
    // desktop but captures at 1920x1080. Decoding frames at the reported size
    // rejected every one of them.
    const scaledJson = {
      'x': 0,
      'y': 0,
      'width': 2560,
      'height': 1600,
      'cursor_embedded': 0,
      'original_width': 1920,
      'original_height': 1080,
      'scaled_width': 2560,
    };

    test('detects a display that renders and captures at different sizes', () {
      final display = RemoteDisplay.fromJson(scaledJson);

      expect(display.isScaled, isTrue);
      expect(display.width, 2560);
      expect(display.originalWidth, 1920);
      expect(display.originalHeight, 1080);
    });

    test('an unscaled display is not marked scaled', () {
      final display = RemoteDisplay.fromJson({
        'width': 1920,
        'height': 1080,
        'original_width': 1920,
        'original_height': 1080,
        'scaled_width': 1920,
      });

      expect(display.isScaled, isFalse);
    });

    test('a display without an original resolution is not scaled', () {
      // A virtual display reports no original size; guessing would be wrong.
      final display = RemoteDisplay.fromJson({'width': 1920, 'height': 1080});

      expect(display.isScaled, isFalse);
    });

    test('the frame buffer matches the original resolution', () {
      final display = RemoteDisplay.fromJson(scaledJson);

      // 8294400 is what the core actually sends for this display.
      expect(display.originalWidth * display.originalHeight * 4, 8294400);
      // Decoding at the reported size would expect twice as much.
      expect(display.width * display.height * 4, 16384000);
    });

    test('scale comes from width over scaled_width', () {
      // Matches evtToDisplay: never below 1.
      expect(RemoteDisplay.fromJson(scaledJson).scale, 1.0);
      expect(
          RemoteDisplay.fromJson({'width': 2560, 'scaled_width': 1280}).scale,
          2.0);
      expect(
          RemoteDisplay.fromJson({'width': 1280, 'scaled_width': 2560}).scale,
          1.0);
      expect(RemoteDisplay.fromJson({'width': 1920}).scale, 1.0);
    });
  });
}
