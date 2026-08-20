import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// Which surface the process was launched to render.
enum LaunchMode {
  /// Desktop main window, or the whole mobile app.
  main,

  /// A `multi_window` sub window (remote, file transfer, camera, port
  /// forward, terminal).
  subWindow,

  /// The connection manager (`--cm`).
  connectionManager,

  /// The installer page (`--install`).
  install,
}

/// The launch decision derived from process arguments.
///
/// This is a pure parse of the argument contract used by the Rust side and by
/// `desktop_multi_window`; it performs no IO so it can be unit tested. The
/// contract matches `flutter_legacy/lib/main.dart`.
@immutable
class BootConfig {
  const BootConfig({
    required this.args,
    required this.mode,
    required this.appType,
    required this.desktopType,
    this.windowId,
    this.windowType,
    this.windowArgs = const <String, dynamic>{},
  });

  /// Parse process launch arguments.
  ///
  /// [desktop] is injectable so tests can exercise the desktop branches on any
  /// host; it defaults to the real platform.
  factory BootConfig.parse(List<String> args, {bool? desktop}) {
    final isDesktopHost = desktop ?? isDesktop;
    if (!isDesktopHost) {
      return BootConfig(
        args: List.unmodifiable(args),
        mode: LaunchMode.main,
        appType: kAppTypeMain,
        desktopType: DesktopType.main,
      );
    }

    if (args.isNotEmpty && args.first == 'multi_window') {
      return _parseSubWindow(args);
    }
    if (args.isNotEmpty && args.first == '--cm') {
      return BootConfig(
        args: List.unmodifiable(args),
        mode: LaunchMode.connectionManager,
        appType: kAppTypeConnectionManager,
        desktopType: DesktopType.cm,
      );
    }
    if (args.contains('--install')) {
      return BootConfig(
        args: List.unmodifiable(args),
        mode: LaunchMode.install,
        appType: kAppTypeMain,
        desktopType: DesktopType.main,
      );
    }
    return BootConfig(
      args: List.unmodifiable(args),
      mode: LaunchMode.main,
      appType: kAppTypeMain,
      desktopType: DesktopType.main,
    );
  }

  static BootConfig _parseSubWindow(List<String> args) {
    // Contract: ['multi_window', '<windowId>', '<jsonArgs>'].
    final windowId = args.length > 1 ? int.tryParse(args[1]) : null;
    if (windowId == null) {
      debugPrint('multi_window launch without a window id: $args');
      return BootConfig(
        args: List.unmodifiable(args),
        mode: LaunchMode.main,
        appType: kAppTypeMain,
        desktopType: DesktopType.main,
      );
    }

    var windowArgs = <String, dynamic>{};
    final raw = args.length > 2 ? args[2] : '';
    if (raw.isNotEmpty) {
      try {
        windowArgs = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (e) {
        debugPrint('failed to decode multi_window arguments: $e');
      }
    }
    // The legacy bootstrap injects the window id into the argument map before
    // handing it to the screen widgets; keep that contract.
    windowArgs['windowId'] = windowId;

    final type = (windowArgs['type'] as int?) ?? -1;
    final windowType = type.windowType;
    return BootConfig(
      args: List.unmodifiable(args),
      mode: LaunchMode.subWindow,
      appType: appTypeOf(windowType),
      desktopType: desktopTypeOf(windowType),
      windowId: windowId,
      windowType: windowType,
      windowArgs: Map.unmodifiable(windowArgs),
    );
  }

  final List<String> args;
  final LaunchMode mode;

  /// The app type string handed to the Rust global event stream.
  final String appType;

  /// The desktop surface this process renders.
  final DesktopType desktopType;

  /// The `desktop_multi_window` window id, when [mode] is
  /// [LaunchMode.subWindow].
  final int? windowId;

  /// The sub window type, when [mode] is [LaunchMode.subWindow].
  final WindowType? windowType;

  /// Decoded sub window arguments (peer id, display, screen_rect, ...).
  final Map<String, dynamic> windowArgs;

  /// Peer id carried by a sub window launch, when present.
  String? get peerId => windowArgs['id'] as String?;

  /// Display index carried by a sub window launch, when present.
  int? get display => windowArgs['display'] as int?;

  bool get isMainWindow => mode == LaunchMode.main;

  @override
  String toString() => 'BootConfig(mode: $mode, appType: $appType, '
      'desktopType: $desktopType, windowId: $windowId, '
      'windowType: $windowType)';
}
