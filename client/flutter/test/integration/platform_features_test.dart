import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/platform/host_platform.dart' as host;
import 'package:flutter_hbb/integration/platform/platform_features.dart';

/// These run on the host, so they assert the rules rather than a fixed
/// answer: a value hard-coded for macOS would be wrong in CI on Linux.
void main() {
  group('platform detection', () {
    test('exactly one host platform is reported', () {
      final flags = <bool>[
        host.isAndroid,
        host.isIOS,
        host.isWindows,
        host.isMacOS,
        host.isLinux,
        host.isWeb
      ];

      expect(flags.where((flag) => flag).length, 1,
          reason: 'the build must know exactly what it is running on');
    });

    test('desktop and mobile are exclusive', () {
      expect(host.isDesktop && host.isMobile, isFalse);
    });

    test('a native build is not a web build', () {
      // The conditional import decides this; a native build linking the web
      // variant would try to call into a browser that is not there.
      expect(host.isWeb, isFalse);
      expect(host.isWebDesktop, isFalse);
      expect(host.screenInfo, isEmpty);
    });

    test('the web-host flags are all false off the web', () {
      expect(host.isWebOnWindows, isFalse);
      expect(host.isWebOnLinux, isFalse);
      expect(host.isWebOnMacOS, isFalse);
    });

    test('the desktop layout follows the desktop build here', () {
      // On the web this is true for a desktop browser instead.
      expect(host.usesDesktopLayout, host.isDesktop);
    });
  });

  group('feature gates', () {
    test('a build that can be controlled has a service to run', () {
      // Being controllable and hosting the service are the same capability;
      // splitting them would let the UI offer one without the other.
      expect(PlatformFeatures.canBeControlled, PlatformFeatures.hasService);
    });

    test('every capability the web lacks is available on a native build', () {
      expect(PlatformFeatures.canBeControlled, !host.isWeb);
      expect(PlatformFeatures.hasFileTransfer, !host.isWeb);
      expect(PlatformFeatures.hasTerminal, !host.isWeb);
      expect(PlatformFeatures.hasRecording, !host.isWeb);
      expect(PlatformFeatures.hasPlugins, !host.isWeb);
      expect(PlatformFeatures.hasDeepLinks, !host.isWeb);
    });

    test('port forwarding needs a local listening socket', () {
      // A browser cannot open one, and a phone has nothing to forward to.
      expect(PlatformFeatures.hasPortForward, host.isDesktop);
    });

    test('only desktop opens sessions in their own windows', () {
      expect(PlatformFeatures.hasMultipleWindows, host.isDesktop);
      expect(PlatformFeatures.remembersWindowFrame, host.isDesktop);
    });

    test('the virtual printer is Windows only', () {
      expect(PlatformFeatures.hasRemotePrinter, host.isWindows);
    });

    test('Wayland settings are Linux only', () {
      expect(PlatformFeatures.hasWaylandSettings, host.isLinux);
    });

    test('touch-only helpers are mobile only', () {
      expect(PlatformFeatures.hasQrScanner, host.isMobile);
      expect(PlatformFeatures.hasVirtualMouse, host.isMobile);
    });

    test('runtime permissions are an Android concern', () {
      expect(PlatformFeatures.needsRuntimePermissions, host.isAndroid);
    });

    test('peers can be renamed wherever a peer list is shown', () {
      expect(PlatformFeatures.canRenamePeers,
          host.isMobile || host.usesDesktopLayout);
    });
  });
}
