import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// Requests and checks Android runtime permissions.
///
/// Ported from `AndroidPermissionManager` in `flutter_legacy/lib/common.dart`.
/// The host does not answer a request on the channel; it calls back on
/// `on_android_permission_result` once the user has decided, so a request is a
/// future completed by [complete] rather than by the invoke.
///
/// On every other platform a permission is always granted, so callers do not
/// need to branch on the platform themselves.
class AndroidPermissions {
  AndroidPermissions();

  static final AndroidPermissions instance = AndroidPermissions();

  /// How long to wait for the user before giving up on a request.
  ///
  /// A user who leaves the permission dialog open, or is sent to a settings
  /// screen and never returns, would otherwise leave the caller waiting
  /// forever.
  static const requestTimeout = Duration(seconds: 120);

  Completer<bool>? _pending;
  Timer? _timer;
  var _current = '';

  /// The permission being requested, or empty when none is.
  String get pendingPermission => _current;

  /// Whether storage access is being waited on, which the file surfaces use to
  /// show a waiting state rather than an empty folder.
  bool get isWaitingForStorage =>
      _pending?.isCompleted == false && _current == kManageExternalStorage;

  /// Whether [permission] is already granted.
  Future<bool> check(String permission) async {
    if (!isAndroid) return true;
    try {
      final granted =
          await platformFFI.invokeMethod(AndroidChannel.kCheckPermission, permission);
      return granted == true;
    } catch (e) {
      debugPrint('failed to check $permission: $e');
      return false;
    }
  }

  /// Ask for [permission], resolving once the user has answered.
  ///
  /// A second request supersedes the first: the earlier one resolves false, so
  /// nobody is left waiting on a dialog that is no longer on screen.
  Future<bool> request(String permission) async {
    if (!isAndroid) return true;

    if (_pending?.isCompleted == false) _pending?.complete(false);
    _timer?.cancel();

    final completer = Completer<bool>();
    _pending = completer;
    _current = permission;
    _timer = Timer(requestTimeout, () {
      if (!completer.isCompleted) completer.complete(false);
      if (identical(_pending, completer)) {
        _pending = null;
        _current = '';
      }
    });

    try {
      await platformFFI.invokeMethod(
          AndroidChannel.kRequestPermission, permission);
    } catch (e) {
      debugPrint('failed to request $permission: $e');
      _timer?.cancel();
      if (!completer.isCompleted) completer.complete(false);
      _pending = null;
      _current = '';
      return false;
    }

    return completer.future;
  }

  /// Check [permission], asking for it only if it is not already granted.
  Future<bool> ensure(String permission) async {
    if (await check(permission)) return true;
    return request(permission);
  }

  /// The host's answer to a request.
  ///
  /// A result for a permission we are no longer waiting on is treated as a
  /// refusal: it belongs to a superseded request, and granting on it would
  /// resolve the wrong future.
  void complete(String permission, bool granted) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _timer?.cancel();
    _timer = null;
    pending.complete(permission == _current && granted);
    _pending = null;
    _current = '';
  }

  /// Send the user to an Android settings screen, for permissions that cannot
  /// be granted from a dialog.
  Future<void> openSettings(String action) async {
    if (!isAndroid) return;
    try {
      await platformFFI.invokeMethod(AndroidChannel.kStartAction, action);
    } catch (e) {
      debugPrint('failed to open $action: $e');
    }
  }

  /// Test-only: drop any pending request.
  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    if (_pending?.isCompleted == false) _pending?.complete(false);
    _pending = null;
    _current = '';
  }
}

/// The process-wide Android permission manager.
AndroidPermissions get androidPermissions => AndroidPermissions.instance;
