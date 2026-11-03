import 'package:flutter_hbb/integration/platform/native_platform.dart'
    if (dart.library.js_interop) 'package:flutter_hbb/integration/platform/web_platform.dart';

/// Host platform detection.
///
/// Mirrors `flutter_legacy/lib/common.dart`. The facts come from whichever
/// variant the conditional import above selected, so a web build never links
/// `dart:io` and a native build never links the browser interop.
final isAndroid = isAndroid_;
final isIOS = isIOS_;
final isWindows = isWindows_;
final isMacOS = isMacOS_;
final isLinux = isLinux_;

final isWeb = isWeb_;

/// A browser on a desktop machine, which gets the desktop layout even though
/// it is not a desktop build.
final isWebDesktop = isWebDesktop_;

/// What the browser is running on. Native builds report false for all three:
/// they know their own platform through [isWindows] and friends.
final isWebOnWindows = isWebOnWindows_;
final isWebOnLinux = isWebOnLinux_;
final isWebOnMacOS = isWebOnMacOS_;

final isDesktop = isDesktop_;
final isMobile = isAndroid || isIOS;

/// True where the UI should use the desktop layout, browser included.
bool get usesDesktopLayout => isDesktop || isWebDesktop;

/// The browser's screen description, empty on a native build.
String get screenInfo => screenInfo_;

/// Windows build number, populated during [PlatformFFI.init] on Windows only.
int windowsBuildNumber = 0;

/// Android SDK int, populated during [PlatformFFI.init] on Android only.
int androidVersion = 0;

/// App version, populated during [PlatformFFI.init].
String version = '';

/// The windows targets in publish-time order. Preserved from the legacy
/// `consts.dart` because option/compat checks compare against these names.
enum WindowsTarget { naw, xp, vista, w7, w8, w8_1, w10, w11 }

extension WindowsTargetExt on int {
  WindowsTarget get windowsVersion => getWindowsTarget(this);
}

WindowsTarget getWindowsTarget(int buildNumber) {
  if (!isWindows) return WindowsTarget.naw;
  if (buildNumber >= 22000) return WindowsTarget.w11;
  if (buildNumber >= 10240) return WindowsTarget.w10;
  if (buildNumber >= 9600) return WindowsTarget.w8_1;
  if (buildNumber >= 9200) return WindowsTarget.w8;
  if (buildNumber >= 7601) return WindowsTarget.w7;
  if (buildNumber >= 6002) return WindowsTarget.vista;
  return WindowsTarget.xp;
}

/// Windows 7 overflows a frameless window, so it keeps the native title bar.
bool get kUseCompatibleUiMode =>
    isWindows && windowsBuildNumber.windowsVersion == WindowsTarget.w7;

bool get isWin10 => windowsBuildNumber.windowsVersion == WindowsTarget.w10;
