import 'dart:io';

/// Host platform facts on a native target.
///
/// Mirrors `flutter_legacy/lib/native/common.dart`. The web build swaps this
/// for `web_platform.dart` through the conditional import in
/// `host_platform.dart`, so the two files must expose the same names.
final isAndroid_ = Platform.isAndroid;
final isIOS_ = Platform.isIOS;
final isWindows_ = Platform.isWindows;
final isMacOS_ = Platform.isMacOS;
final isLinux_ = Platform.isLinux;

final isWeb_ = false;
final isWebDesktop_ = false;
final isWebOnWindows_ = false;
final isWebOnLinux_ = false;
final isWebOnMacOS_ = false;

final isDesktop_ =
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Only the web build reports the browser's screen; a native build reads the
/// display through the core instead.
String get screenInfo_ => '';
