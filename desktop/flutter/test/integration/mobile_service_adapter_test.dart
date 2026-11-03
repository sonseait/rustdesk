import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/adapters/mobile_service_adapter.dart';
import 'package:flutter_hbb/integration/platform/android_host_channel.dart';

void main() {
  group('service state', () {
    test('a fresh adapter is not sharing anything', () {
      final adapter = MobileServiceAdapter();

      expect(adapter.isRunning, isFalse);
      expect(adapter.state.canCaptureScreen, isFalse);
    });

    test('a running service with no projection is called out', () {
      // Android grants the projection separately, so a service can be up
      // while nothing is actually shared. Reporting that as working would
      // tell the user they are sharing when they are not.
      final adapter = MobileServiceAdapter()
        ..setStateForTest(const MobileServiceState(isRunning: true));

      expect(adapter.isRunningWithoutCapture, isTrue);
    });

    test('once the projection lands it is sharing properly', () {
      final adapter = MobileServiceAdapter()
        ..setStateForTest(const MobileServiceState(
            isRunning: true, canCaptureScreen: true));

      expect(adapter.isRunningWithoutCapture, isFalse);
    });
  });

  group('MobileServiceState', () {
    test('copyWith replaces one flag', () {
      const state = MobileServiceState(isRunning: true);

      final next = state.copyWith(canShareAudio: true);

      expect(next.isRunning, isTrue);
      expect(next.canShareAudio, isTrue);
      expect(next.canCaptureScreen, isFalse);
    });

    test('two states with the same flags are equal', () {
      expect(const MobileServiceState(isRunning: true),
          const MobileServiceState(isRunning: true));
      expect(const MobileServiceState(isRunning: true),
          isNot(const MobileServiceState()));
    });
  });

  group('host contract', () {
    test('the native method names are what the host answers to', () {
      expect(MobileServiceAdapter.initServiceMethod, 'init_service');
      expect(MobileServiceAdapter.stopServiceMethod, 'stop_service');
    });

    test('the SDK thresholds match when Android added each permission', () {
      // Asking below these versions fails, and skipping the check above them
      // starts a service Android kills moments later.
      expect(MobileServiceAdapter.notificationPermissionSdk, 33);
      expect(MobileServiceAdapter.overlayPermissionSdk, 23);
      expect(MobileServiceAdapter.audioCaptureSdk, 30);
    });
  });

  group('ServicePermission', () {
    test('records whether the service can start without it', () {
      const required = ServicePermission(
          permission: 'a', granted: false, required: true);
      const optional = ServicePermission(
          permission: 'b', granted: false, required: false);

      expect(required.required, isTrue);
      expect(optional.required, isFalse);
    });
  });

  group('off Android', () {
    // The adapter is only meaningful on Android; everywhere else it must be
    // inert rather than throwing when a shared surface touches it.
    test('there are no permissions to ask for', () async {
      expect(await MobileServiceAdapter().permissions(), isEmpty);
    });

    test('requesting permissions succeeds trivially', () async {
      expect(await MobileServiceAdapter().requestServicePermissions(), isTrue);
    });

    test('syncing permissions does nothing', () async {
      final adapter = MobileServiceAdapter();

      await adapter.syncPermissions();

      expect(adapter.state, const MobileServiceState());
    });

    test('start does not begin listening to the host', () {
      final adapter = MobileServiceAdapter();

      adapter.start();

      // Nothing to dispose means dispose must still be safe.
      expect(adapter.dispose, returnsNormally);
    });
  });

  group('host events', () {
    late AndroidHostChannel host;
    late MobileServiceAdapter adapter;

    setUp(() {
      host = AndroidHostChannel();
      adapter = MobileServiceAdapter(host: host);
      // start() is a no-op off Android, so the listeners are wired directly
      // to exercise the event handling itself.
      host.addEventListener(adapter.handleHostEventForTest);
    });

    test('capture starting means it is really sharing', () {
      host.handle('start_capture', null);

      expect(adapter.state.isRunning, isTrue);
      expect(adapter.state.canCaptureScreen, isTrue);
    });

    test('a cancelled projection leaves nothing running', () {
      adapter.setStateForTest(
          const MobileServiceState(isRunning: true, canCaptureScreen: true));

      host.handle('on_media_projection_canceled', null);

      expect(adapter.state.isRunning, isFalse);
      expect(adapter.state.canCaptureScreen, isFalse);
    });

    test('the host stopping the service clears every flag', () {
      adapter.setStateForTest(const MobileServiceState(
          isRunning: true, canCaptureScreen: true, canShareAudio: true));

      host.handle('stop_service', null);

      expect(adapter.state, const MobileServiceState());
    });
  });
}
