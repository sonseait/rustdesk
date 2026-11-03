import 'dart:js_interop';

import 'package:flutter_hbb/integration/adapters/peer.dart';

/// Host platform facts on the web target.
///
/// Mirrors `flutter_legacy/lib/web/common.dart`. The values come from the page
/// that hosts the app: the browser cannot tell Flutter what it is running on,
/// so `main.js` publishes it and this reads it back.
///
/// Only reachable through the conditional import in `host_platform.dart`, so
/// it is never compiled into a native build.
@JS('isMobile')
external JSBoolean _isMobile();

@JS('getByName')
external JSString _getByName(JSString name, [JSString value]);

final isAndroid_ = false;
final isIOS_ = false;
final isWindows_ = false;
final isMacOS_ = false;
final isLinux_ = false;

final isWeb_ = true;

/// A browser on a desktop machine. The page reports this, because a phone
/// browser and a desktop browser need different controls.
final isWebDesktop_ = !_isMobile().toDart;

final isDesktop_ = false;

String get screenInfo_ => _getByName('screen_info'.toJS).toDart;

/// Which OS the browser is running on.
///
/// This is what the page detected, not what the core reports: on the web the
/// core runs on the other end of the connection.
final String _localOs = _getByName('local_os'.toJS, ''.toJS).toDart;

final isWebOnWindows_ = _localOs == PeerPlatform.windows;
final isWebOnLinux_ = _localOs == PeerPlatform.linux;
final isWebOnMacOS_ = _localOs == PeerPlatform.macOS;
