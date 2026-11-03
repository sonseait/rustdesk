import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/platform/android_host_channel.dart';
import 'package:flutter_hbb/integration/platform/android_permissions.dart';

/// Permissions that record completions instead of talking to a device.
class _RecordingPermissions extends AndroidPermissions {
  final List<(String, bool)> completed = [];

  @override
  void complete(String permission, bool granted) =>
      completed.add((permission, granted));
}

void main() {
  group('permission names', () {
    // These strings reach XXPermissions on the native side unchanged, so they
    // must stay exactly as the Android framework names them.
    test('are the Android framework names', () {
      expect(kRecordAudio, 'android.permission.RECORD_AUDIO');
      expect(kManageExternalStorage,
          'android.permission.MANAGE_EXTERNAL_STORAGE');
      expect(kSystemAlertWindow, 'android.permission.SYSTEM_ALERT_WINDOW');
      expect(kAndroid13Notification, 'android.permission.POST_NOTIFICATIONS');
      expect(kRequestIgnoreBatteryOptimizations,
          'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS');
    });

    test('the channel methods are the names the host answers to', () {
      expect(AndroidChannel.kCheckPermission, 'check_permission');
      expect(AndroidChannel.kRequestPermission, 'request_permission');
      expect(AndroidChannel.kStartAction, 'start_action');
    });
  });

  group('host calls', () {
    late AndroidHostChannel channel;
    late _RecordingPermissions permissions;

    setUp(() {
      permissions = _RecordingPermissions();
      channel = AndroidHostChannel(permissions: permissions);
    });

    test('capture start and cancel are distinct events', () {
      final events = <AndroidHostEvent>[];
      channel.addEventListener(events.add);

      channel.handle('start_capture', null);
      channel.handle('on_media_projection_canceled', null);
      channel.handle('stop_service', null);

      expect(events, [
        AndroidHostEvent.captureStarted,
        AndroidHostEvent.captureCancelled,
        AndroidHostEvent.serviceStopped,
      ]);
    });

    test('a state change carries the flag as a bool', () {
      // The host sends the value as the string "true"/"false"; taking it as a
      // bool directly would read every change as false.
      final changes = <(String, bool)>[];
      channel.addStateListener((name, value) => changes.add((name, value)));

      channel.handle('on_state_changed', {'name': 'audio', 'value': 'true'});
      channel.handle('on_state_changed', {'name': 'file', 'value': 'false'});

      expect(changes, [('audio', true), ('file', false)]);
    });

    test('a state change with no name is ignored', () {
      final changes = <String>[];
      channel.addStateListener((name, _) => changes.add(name));

      channel.handle('on_state_changed', {'value': 'true'});

      expect(changes, isEmpty);
    });

    test('a permission result reaches the permission manager', () {
      channel.handle('on_android_permission_result',
          {'type': kRecordAudio, 'result': true});

      expect(permissions.completed, [(kRecordAudio, true)]);
    });

    test('a message box is passed on with its link', () {
      final messages = <AndroidMessageBox>[];
      channel.addMessageListener(messages.add);

      channel.handle('msgbox', {
        'type': 'error',
        'title': 'Connection failed',
        'text': 'The device refused the connection',
        'link': 'https://rustdesk.com/docs',
      });

      expect(messages.single.title, 'Connection failed');
      expect(messages.single.link, 'https://rustdesk.com/docs');
    });

    test('a message box with no link is still delivered', () {
      final messages = <AndroidMessageBox>[];
      channel.addMessageListener(messages.add);

      channel.handle('msgbox', {'type': 'info', 'title': 'a', 'text': 'b'});

      expect(messages.single.link, isEmpty);
    });

    test('a malformed call does not take the channel down', () {
      final events = <AndroidHostEvent>[];
      channel.addEventListener(events.add);

      // Arguments of the wrong shape must not throw: the host would then get
      // no answer to anything that follows.
      expect(() => channel.handle('on_state_changed', 'not a map'),
          returnsNormally);
      channel.handle('start_capture', null);

      expect(events, [AndroidHostEvent.captureStarted]);
    });

    test('an unknown call is ignored rather than throwing', () {
      expect(() => channel.handle('something_new', null), returnsNormally);
    });

    test('a removed listener stops hearing events', () {
      final events = <AndroidHostEvent>[];
      void listener(AndroidHostEvent event) => events.add(event);
      channel.addEventListener(listener);

      channel.handle('start_capture', null);
      channel.removeEventListener(listener);
      channel.handle('stop_service', null);

      expect(events, [AndroidHostEvent.captureStarted]);
    });
  });

  group('permission requests off Android', () {
    // Every other platform grants permissions implicitly, so callers do not
    // have to branch on the platform themselves.
    test('check and request both succeed', () async {
      final permissions = AndroidPermissions();

      expect(await permissions.check(kRecordAudio), isTrue);
      expect(await permissions.request(kRecordAudio), isTrue);
      expect(await permissions.ensure(kRecordAudio), isTrue);
    });

    test('nothing is left pending', () {
      final permissions = AndroidPermissions();

      expect(permissions.pendingPermission, isEmpty);
      expect(permissions.isWaitingForStorage, isFalse);
    });
  });
}
