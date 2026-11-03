import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/window_coordinator.dart';

/// Why a connect attempt did not open a session.
enum ConnectFailure {
  /// The peer id was empty after normalization.
  emptyId,

  /// The bridge is not initialized.
  bridgeNotReady,

  /// The core or the window layer raised an error.
  failed,
}

/// The outcome of a connect attempt.
@immutable
class ConnectResult {
  const ConnectResult.success(this.peerId, {this.windowId})
      : failure = null,
        error = null;

  const ConnectResult.failure(this.peerId, this.failure, {this.error})
      : windowId = null;

  /// The normalized peer id the attempt used.
  final String peerId;

  /// The window the session opened in, when known.
  final int? windowId;

  final ConnectFailure? failure;
  final Object? error;

  bool get isSuccess => failure == null;
}

/// Opens sessions through the existing connection path.
///
/// Ported from `connect()` / `connectMainDesktop()` in
/// `flutter_legacy/lib/common.dart`. Two behaviors here are load-bearing and
/// easy to lose:
///
/// - Spaces are stripped from the id before anything else, so a pasted
///   `847 293 160` connects.
/// - `mainHandleRelayId` may rewrite the id. When it does, relay is forced
///   even if the caller did not ask for it.
class ConnectAdapter {
  ConnectAdapter({WindowCoordinator? windowCoordinator})
      : _windows = windowCoordinator ?? WindowCoordinator.instance;

  static final ConnectAdapter instance = ConnectAdapter();

  final WindowCoordinator _windows;

  /// Normalize a peer id the way the core expects: no spaces.
  static String normalizeId(String id) => id.replaceAll(' ', '');

  /// Open a session with [peerId].
  ///
  /// On desktop this creates or reuses the appropriate window. On mobile the
  /// caller is responsible for pushing the session route; the returned result
  /// carries the resolved id and relay preference to hand to it.
  Future<ConnectResult> connect(
    String peerId, {
    ConnectionKind kind = ConnectionKind.remoteDesktop,
    String? password,
    bool? isSharedPassword,
    String? switchUuid,
    bool forceRelay = false,
    String? connToken,
  }) async {
    final id = normalizeId(peerId);
    if (id.isEmpty) {
      return const ConnectResult.failure('', ConnectFailure.emptyId);
    }
    if (!platformFFI.isInitialized) {
      return ConnectResult.failure(id, ConnectFailure.bridgeNotReady);
    }

    try {
      // The core may rewrite the id (e.g. an `id@relay` form). A rewrite
      // means the connection must go through a relay.
      final resolvedId = await bind.mainHandleRelayId(id: id);
      final relay = forceRelay || resolvedId != id;

      final request = ConnectionRequest(
        kind: kind,
        peerId: resolvedId,
        password: password,
        isSharedPassword: isSharedPassword,
        switchUuid: switchUuid,
        forceRelay: relay,
        connToken: connToken,
      );

      if (!isDesktop) {
        // Mobile opens the session in-app; there is no window to create.
        return ConnectResult.success(resolvedId);
      }

      // A sub window cannot create sessions itself: it asks the main window.
      if (platformFFI.desktopType != DesktopType.main) {
        await _windows.call(WindowType.Main, kWindowConnect, {
          'id': resolvedId,
          'isFileTransfer': kind == ConnectionKind.fileTransfer,
          'isViewCamera': kind == ConnectionKind.viewCamera,
          'isTerminal': kind == ConnectionKind.terminal,
          'isTcpTunneling': kind == ConnectionKind.portForward,
          'isRDP': kind == ConnectionKind.rdp,
          'password': password,
          'isSharedPassword': isSharedPassword,
          'forceRelay': relay,
          'connToken': connToken,
          'switch_uuid': switchUuid,
        });
        return ConnectResult.success(resolvedId);
      }

      final call = await _windows.open(request);
      return ConnectResult.success(resolvedId, windowId: call.windowId);
    } catch (e, s) {
      debugPrint('failed to connect to $id: $e');
      debugPrintStack(stackTrace: s);
      return ConnectResult.failure(id, ConnectFailure.failed, error: e);
    }
  }
}

/// The process-wide connect adapter.
ConnectAdapter get connector => ConnectAdapter.instance;
