import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/android_permissions.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// A message the Android host pushed that the UI has to act on.
enum AndroidHostEvent {
  /// Screen capture started; any permission dialog can be dismissed.
  captureStarted,

  /// The user cancelled the media-projection prompt, so sharing is not on.
  captureCancelled,

  /// The host asked for the service to stop.
  serviceStopped,
}

/// The single handler for calls the Android host makes into Flutter.
///
/// `MethodChannel.setMethodCallHandler` keeps only the last handler, so every
/// consumer registers here rather than installing its own and silently
/// replacing another's.
///
/// Ported from `androidChannelInit` in
/// `flutter_legacy/lib/mobile/pages/server_page.dart`. The method names and
/// argument keys are the native contract.
class AndroidHostChannel {
  AndroidHostChannel({AndroidPermissions? permissions})
      : _permissions = permissions ?? AndroidPermissions.instance;

  static final AndroidHostChannel instance = AndroidHostChannel();

  final AndroidPermissions _permissions;

  final List<void Function(AndroidHostEvent)> _eventListeners = [];
  final List<void Function(String name, bool value)> _stateListeners = [];
  final List<void Function(AndroidMessageBox)> _messageListeners = [];

  var _installed = false;

  /// Start listening. Safe to call more than once, and a no-op off Android.
  void install() {
    if (_installed || !isAndroid) return;
    _installed = true;
    platformFFI.setMethodCallHandler(_handle);
  }

  void addEventListener(void Function(AndroidHostEvent) listener) =>
      _eventListeners.add(listener);

  void removeEventListener(void Function(AndroidHostEvent) listener) =>
      _eventListeners.remove(listener);

  /// Listen for a named service flag flipping, e.g. audio or file transfer.
  void addStateListener(void Function(String name, bool value) listener) =>
      _stateListeners.add(listener);

  void removeStateListener(void Function(String name, bool value) listener) =>
      _stateListeners.remove(listener);

  void addMessageListener(void Function(AndroidMessageBox) listener) =>
      _messageListeners.add(listener);

  void removeMessageListener(void Function(AndroidMessageBox) listener) =>
      _messageListeners.remove(listener);

  /// Dispatch one host call. Exposed so a test can drive it without a device.
  @visibleForTesting
  String handle(String method, dynamic arguments) =>
      _handle(method, arguments);

  String _handle(String method, dynamic arguments) {
    try {
      switch (method) {
        case 'start_capture':
          _emit(AndroidHostEvent.captureStarted);
        case 'on_media_projection_canceled':
          _emit(AndroidHostEvent.captureCancelled);
        case 'stop_service':
          _emit(AndroidHostEvent.serviceStopped);
        case 'on_state_changed':
          final name = _stringOf(arguments, 'name');
          // The host sends the flag as the string "true"/"false".
          final value = _stringOf(arguments, 'value') == 'true';
          if (name.isNotEmpty) {
            for (final listener in List.of(_stateListeners)) {
              listener(name, value);
            }
          }
        case 'on_android_permission_result':
          final type = _stringOf(arguments, 'type');
          final result = arguments is Map ? arguments['result'] == true : false;
          _permissions.complete(type, result);
        case 'msgbox':
          final message = AndroidMessageBox(
            type: _stringOf(arguments, 'type'),
            title: _stringOf(arguments, 'title'),
            text: _stringOf(arguments, 'text'),
            link: _stringOf(arguments, 'link'),
          );
          for (final listener in List.of(_messageListeners)) {
            listener(message);
          }
        default:
          debugPrint('unhandled Android host call: $method');
      }
    } catch (e) {
      // A malformed call must not take the channel down; the host would then
      // get no answer to anything.
      debugPrint('failed to handle the Android host call $method: $e');
    }
    // The legacy handler answers every call with an empty string.
    return '';
  }

  void _emit(AndroidHostEvent event) {
    for (final listener in List.of(_eventListeners)) {
      listener(event);
    }
  }

  static String _stringOf(dynamic arguments, String key) {
    if (arguments is! Map) return '';
    return arguments[key]?.toString() ?? '';
  }

  /// Test-only: drop every listener and allow reinstalling.
  @visibleForTesting
  void resetForTest() {
    _eventListeners.clear();
    _stateListeners.clear();
    _messageListeners.clear();
    _installed = false;
  }
}

/// A message the host asked to show.
@immutable
class AndroidMessageBox {
  const AndroidMessageBox({
    required this.type,
    required this.title,
    required this.text,
    this.link = '',
  });

  final String type;
  final String title;
  final String text;
  final String link;
}

/// The process-wide Android host channel.
AndroidHostChannel get androidHost => AndroidHostChannel.instance;
