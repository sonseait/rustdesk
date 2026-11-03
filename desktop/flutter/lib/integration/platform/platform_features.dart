import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// What this build can actually do.
///
/// The web build shares almost all of Aurora's code but cannot host a session,
/// capture a screen, or reach the filesystem the way a native build can. The
/// legacy UI expressed that as `if (!isWeb)` scattered across the settings
/// page, the peer menu, and the toolbar; gathering it here means a surface
/// asks what is supported rather than re-deriving it, and a gate that is
/// wrong is wrong in one place.
///
/// These are build/platform capabilities only. Whether a deployment *allows*
/// something is a separate question, answered by the option repository.
class PlatformFeatures {
  const PlatformFeatures._();

  // ------------------------------------------------------------- being shared

  /// Whether this device can accept incoming connections.
  ///
  /// The browser has no screen to capture and no service to run, so a web
  /// build is outgoing-only by nature.
  static bool get canBeControlled => !isWeb;

  /// Whether the background service exists to be started or stopped.
  static bool get hasService => !isWeb;

  /// Whether the user starts and stops sharing from a page of their own.
  ///
  /// A phone has one screen and shares it deliberately; a desktop runs the
  /// service in the background and controls it from settings.
  static bool get sharesOwnScreen => isMobile;

  /// Whether this device can be found on the local network.
  static bool get hasLanDiscovery => !isWeb;

  // ------------------------------------------------------------ session tools

  /// Whether a session can transfer files.
  static bool get hasFileTransfer => !isWeb;

  /// Whether a session can open a remote shell.
  static bool get hasTerminal => !isWeb;

  /// Whether TCP tunnelling and RDP are available.
  ///
  /// Both need a local listening socket, which a browser cannot open.
  static bool get hasPortForward => isDesktop;

  /// Whether a session can be recorded to disk.
  static bool get hasRecording => !isWeb;

  /// Whether the hardware codec settings apply.
  static bool get hasHardwareCodec => !isWeb;

  /// Whether audio can be captured from this device.
  static bool get hasAudioCapture => !isWeb;

  /// Whether more than one display can be enumerated locally.
  static bool get hasMultipleScreens => !isWeb;

  // ---------------------------------------------------------------- settings

  /// Whether plugins can be installed.
  static bool get hasPlugins => !isWeb;

  /// Whether the remote printer settings apply. The virtual printer driver is
  /// Windows-only.
  static bool get hasRemotePrinter => isWindows;

  /// Whether Wayland-specific settings are worth showing.
  static bool get hasWaylandSettings => isLinux;

  /// Whether a peer can be pinned to always relay.
  static bool get hasForceAlwaysRelay => !isWeb;

  /// Whether a desktop shortcut can be created for a peer.
  static bool get hasDesktopShortcuts => isWindows;

  /// Whether Wake-on-LAN can be sent to a peer.
  static bool get hasWakeOnLan => !isWeb;

  /// Whether a peer can be renamed. Available everywhere a peer list is.
  static bool get canRenamePeers => isMobile || usesDesktopLayout;

  // ----------------------------------------------------------------- windows

  /// Whether sessions open in their own OS windows.
  ///
  /// A browser tab cannot spawn one, so the web build shows sessions in the
  /// page instead.
  static bool get hasMultipleWindows => isDesktop;

  /// Whether `rustdesk://` links reach this build.
  static bool get hasDeepLinks => !isWeb;

  /// Whether the window's size and position are worth remembering.
  static bool get remembersWindowFrame => isDesktop;

  // ------------------------------------------------------------------ mobile

  /// Whether the QR scanner is available for pairing.
  static bool get hasQrScanner => isMobile;

  /// Whether a floating on-screen cursor helps. Only a touch device needs one.
  static bool get hasVirtualMouse => isMobile;

  /// Whether Android runtime permissions have to be asked for.
  static bool get needsRuntimePermissions => isAndroid;
}
