import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/boot_config.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/android_host_channel.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/routing/route_coordinator.dart';

/// Outcome of bringing up the native bridge.
enum BootstrapStatus { pending, ready, failed }

/// Owns application bootstrap: parse launch args, initialize the native
/// bridge, and expose the result as observable state.
///
/// Failure is a first-class state. If the Rust core cannot be loaded the app
/// must show that, not an empty-but-healthy looking workspace.
class AppBootstrap extends ChangeNotifier {
  AppBootstrap._();

  static final AppBootstrap instance = AppBootstrap._();

  BootstrapStatus _status = BootstrapStatus.pending;
  Object? _error;
  StackTrace? _stackTrace;
  BootConfig? _config;
  bool _launchHandledByLink = false;
  String? _softwareUpdateUrl;

  BootstrapStatus get status => _status;

  bool get isReady => _status == BootstrapStatus.ready;

  /// The bridge failure, when [status] is [BootstrapStatus.failed].
  Object? get error => _error;

  StackTrace? get stackTrace => _stackTrace;

  /// The parsed launch configuration. Available as soon as [start] is called.
  BootConfig? get config => _config;

  /// True when the launch arguments carried a link that opened a session. The
  /// desktop shell uses this to keep the main window hidden on startup.
  bool get launchHandledByLink => _launchHandledByLink;

  /// The download URL reported by the core's automatic update check.
  String? get softwareUpdateUrl => _softwareUpdateUrl;

  /// Parse [args] and initialize the native bridge.
  ///
  /// Safe to call once per process. Returns true when the bridge is usable.
  Future<bool> start(List<String> args) async {
    if (_status == BootstrapStatus.ready) return true;

    final config = BootConfig.parse(args);
    _config = config;
    debugPrint('launch args: $args -> $config');

    try {
      await platformFFI.init(
        config.appType,
        desktopType: config.desktopType,
        windowId: config.windowId,
      );
      // Start the rendezvous connection status updater. Without this the core
      // never publishes a status and `mainGetConnectStatus` stays at 0.
      await bind.mainCheckConnectStatus();
      _startSoftwareUpdateCheck();

      // Take the Android host channel before any surface exists: the host can
      // push a permission result or a stop request at any time, and only one
      // handler can be installed.
      AndroidHostChannel.instance.install();

      _status = BootstrapStatus.ready;
      _error = null;
      _stackTrace = null;
      // Consume any link the process was launched with. The request is queued
      // until a surface attaches, so a cold-start deep link is not lost.
      _launchHandledByLink = await RouteCoordinator.instance.handleLaunch(
        config,
      );
    } catch (e, s) {
      debugPrint('failed to initialize the native bridge: $e');
      debugPrintStack(stackTrace: s);
      _status = BootstrapStatus.failed;
      _error = e;
      _stackTrace = s;
    }
    notifyListeners();
    return _status == BootstrapStatus.ready;
  }

  void _startSoftwareUpdateCheck() {
    if (isWeb || bind.isCustomClient()) return;
    platformFFI.registerEventHandler(
      kCheckSoftwareUpdateFinish,
      kCheckSoftwareUpdateFinish,
      (event) async {
        final url = event['url'];
        if (url is String && url.isNotEmpty) {
          _softwareUpdateUrl = url;
          notifyListeners();
        }
      },
      replace: true,
    );
    Timer(const Duration(seconds: 1), () {
      unawaited(bind.mainGetSoftwareUpdateUrl());
    });
  }

  /// Reset to the pre-bootstrap state. Test-only.
  @visibleForTesting
  void resetForTest() {
    _status = BootstrapStatus.pending;
    _error = null;
    _stackTrace = null;
    _config = null;
    _launchHandledByLink = false;
    _softwareUpdateUrl = null;
  }
}
