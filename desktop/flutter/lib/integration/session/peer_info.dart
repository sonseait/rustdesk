import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';

/// Sentinel display index meaning "every display at once".
const int kAllDisplayValue = -1;

/// Sentinel for an unknown display index.
const int kInvalidDisplayIndex = -1;

const int kInvalidResolutionValue = -1;

const int kDesktopDefaultDisplayWidth = 1080;
const int kDesktopDefaultDisplayHeight = 720;
const int kMobileDefaultDisplayWidth = 720;
const int kMobileDefaultDisplayHeight = 1280;

/// Keys inside the peer's `platform_additions` map.
const String kPlatformAdditionsIsWayland = 'is_wayland';
const String kPlatformAdditionsHeadless = 'headless';
const String kPlatformAdditionsIsInstalled = 'is_installed';
const String kPlatformAdditionsIddImpl = 'idd_impl';
const String kPlatformAdditionsRustDeskVirtualDisplays =
    'rustdesk_virtual_displays';
const String kPlatformAdditionsAmyuniVirtualDisplays =
    'amyuni_virtual_displays';
const String kPlatformAdditionsHasFileClipboard = 'has_file_clipboard';
const String kPlatformAdditionsSupportedPrivacyModeImpl =
    'supported_privacy_mode_impl';

/// A remote display.
///
/// Ported from `Display` in `flutter_legacy/lib/models/model.dart`.
@immutable
class RemoteDisplay {
  const RemoteDisplay({
    this.x = 0,
    this.y = 0,
    this.width = kDesktopDefaultDisplayWidth,
    this.height = kDesktopDefaultDisplayHeight,
    this.cursorEmbedded = false,
    this.originalWidth = kInvalidResolutionValue,
    this.originalHeight = kInvalidResolutionValue,
    this.scaledWidth = 0,
    double scale = 1.0,
  }) : _scale = scale;

  RemoteDisplay.fromJson(Map<String, dynamic> json)
      : x = (json['x'] as num?)?.toDouble() ?? 0,
        y = (json['y'] as num?)?.toDouble() ?? 0,
        width = json['width'] as int? ?? kDesktopDefaultDisplayWidth,
        height = json['height'] as int? ?? kDesktopDefaultDisplayHeight,
        cursorEmbedded = json['cursor_embedded'] == true,
        originalWidth =
            json['original_width'] as int? ?? kInvalidResolutionValue,
        originalHeight =
            json['original_height'] as int? ?? kInvalidResolutionValue,
        scaledWidth = json['scaled_width'] as int? ?? 0,
        _scale = _scaleOf(
            json['width'] as int?, json['scaled_width'] as int?);

  final double x;
  final double y;
  final int width;
  final int height;
  final bool cursorEmbedded;

  /// The display's native resolution, when the peer reported it.
  final int originalWidth;
  final int originalHeight;

  /// The logical width the peer scales this display to, or 0 when it is not
  /// scaled. Reported alongside `width` on a HiDPI peer.
  final int scaledWidth;

  final double _scale;

  /// Scale is never below 1.
  double get scale => _scale > 1.0 ? _scale : 1.0;

  /// True when the peer renders at one size and captures at another.
  ///
  /// Such a display reports `width`/`height` as the logical desktop but sends
  /// frames at `original_width`/`original_height`.
  bool get isScaled =>
      isOriginalResolutionSet &&
      (originalWidth != width || originalHeight != height);

  /// Scale from the reported and scaled widths, matching `evtToDisplay`.
  static double _scaleOf(int? width, int? scaledWidth) {
    if (width == null || scaledWidth == null || scaledWidth <= 0 ||
        width <= 0) {
      return 1.0;
    }
    final ratio = width / scaledWidth;
    return ratio > 1.0 ? ratio : 1.0;
  }

  bool get isOriginalResolutionSet =>
      originalWidth != kInvalidResolutionValue &&
      originalHeight != kInvalidResolutionValue;

  bool get isOriginalResolution =>
      width == originalWidth && height == originalHeight;

  /// A virtual display reports a 1920x1080 original resolution.
  bool get isVirtualDisplayResolution =>
      originalWidth == kInvalidResolutionValue &&
      originalHeight == kInvalidResolutionValue;

  @override
  bool operator ==(Object other) =>
      other is RemoteDisplay &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.cursorEmbedded == cursorEmbedded &&
      other.originalWidth == originalWidth &&
      other.originalHeight == originalHeight;

  @override
  int get hashCode => Object.hash(x, y, width, height, cursorEmbedded,
      originalWidth, originalHeight);

  @override
  String toString() => 'RemoteDisplay(${width}x$height @ $x,$y)';
}

/// A resolution the remote display supports.
@immutable
class Resolution {
  const Resolution(this.width, this.height);

  Resolution.fromJson(Map<String, dynamic> json)
      : width = json['width'] as int? ?? 0,
        height = json['height'] as int? ?? 0;

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is Resolution && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// Optional capabilities the peer advertises.
@immutable
class PeerFeatures {
  const PeerFeatures({this.privacyMode = false});

  PeerFeatures.fromJson(Map<String, dynamic> json)
      : privacyMode = json['privacy_mode'] == true;

  final bool privacyMode;
}

/// Everything the peer told us about itself.
///
/// Ported from `PeerInfo` in `flutter_legacy/lib/models/model.dart`. The JSON
/// keys are the Rust `peer_info` event contract.
@immutable
class PeerInfo {
  const PeerInfo({
    this.version = '',
    this.username = '',
    this.hostname = '',
    this.platform = '',
    this.sasEnabled = false,
    this.isSupportMultiUiSession = false,
    this.currentDisplay = 0,
    this.primaryDisplay = kInvalidDisplayIndex,
    this.displays = const [],
    this.features = const PeerFeatures(),
    this.resolutions = const [],
    this.platformAdditions = const {},
    this.isSet = false,
  });

  factory PeerInfo.fromEvent(Map<String, dynamic> evt) {
    final displays = <RemoteDisplay>[];
    final rawDisplays = evt['displays'];
    if (rawDisplays is String && rawDisplays.isNotEmpty) {
      try {
        for (final d in jsonDecode(rawDisplays) as List<dynamic>) {
          if (d is Map<String, dynamic>) displays.add(RemoteDisplay.fromJson(d));
        }
      } catch (e) {
        debugPrint('failed to decode displays: $e');
      }
    }

    final resolutions = <Resolution>[];
    final rawResolutions = evt['resolutions'];
    if (rawResolutions is String && rawResolutions.isNotEmpty) {
      try {
        for (final r in jsonDecode(rawResolutions) as List<dynamic>) {
          if (r is Map<String, dynamic>) resolutions.add(Resolution.fromJson(r));
        }
      } catch (e) {
        debugPrint('failed to decode resolutions: $e');
      }
    }

    var additions = <String, dynamic>{};
    final rawAdditions = evt['platform_additions'];
    if (rawAdditions is String && rawAdditions.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawAdditions);
        if (decoded is Map<String, dynamic>) additions = decoded;
      } catch (e) {
        debugPrint('failed to decode platform additions: $e');
      }
    }

    var features = const PeerFeatures();
    final rawFeatures = evt['features'];
    if (rawFeatures is String && rawFeatures.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawFeatures);
        if (decoded is Map<String, dynamic>) {
          features = PeerFeatures.fromJson(decoded);
        }
      } catch (e) {
        debugPrint('failed to decode features: $e');
      }
    }

    return PeerInfo(
      version: evt['version']?.toString() ?? '',
      username: evt['username']?.toString() ?? '',
      hostname: evt['hostname']?.toString() ?? '',
      platform: evt['platform']?.toString() ?? '',
      sasEnabled: evt['sas_enabled'] == 'true' || evt['sas_enabled'] == true,
      isSupportMultiUiSession:
          evt['is_support_multi_ui_session'] == 'true' ||
              evt['is_support_multi_ui_session'] == true,
      currentDisplay: int.tryParse('${evt['current_display']}') ?? 0,
      primaryDisplay:
          int.tryParse('${evt['primary_display']}') ?? kInvalidDisplayIndex,
      displays: displays,
      features: features,
      resolutions: resolutions,
      platformAdditions: additions,
      isSet: true,
    );
  }

  final String version;
  final String username;
  final String hostname;
  final String platform;
  final bool sasEnabled;
  final bool isSupportMultiUiSession;
  final int currentDisplay;
  final int primaryDisplay;
  final List<RemoteDisplay> displays;
  final PeerFeatures features;
  final List<Resolution> resolutions;
  final Map<String, dynamic> platformAdditions;

  /// False until the peer_info event has arrived.
  final bool isSet;

  int get displaysCount => displays.length;

  bool get isWayland => platformAdditions[kPlatformAdditionsIsWayland] == true;

  bool get isHeadless => platformAdditions[kPlatformAdditionsHeadless] == true;

  /// Non-Windows peers are always "installed"; Windows reports it.
  bool get isInstalled =>
      platform != PeerPlatform.windows ||
      platformAdditions[kPlatformAdditionsIsInstalled] == true;

  bool get hasFileClipboard =>
      platformAdditions[kPlatformAdditionsHasFileClipboard] == true;

  List<int> get rustDeskVirtualDisplays => List<int>.from(
      platformAdditions[kPlatformAdditionsRustDeskVirtualDisplays] ?? const []);

  int get amyuniVirtualDisplayCount =>
      platformAdditions[kPlatformAdditionsAmyuniVirtualDisplays] as int? ?? 0;

  bool get isRustDeskIdd =>
      platformAdditions[kPlatformAdditionsIddImpl] == 'rustdesk_idd';

  bool get isAmyuniIdd =>
      platformAdditions[kPlatformAdditionsIddImpl] == 'amyuni_idd';

  bool get isPeerAndroid => platform == PeerPlatform.android;

  bool get isPeerLinux => platform == PeerPlatform.linux;

  bool get isPeerWindows => platform == PeerPlatform.windows;

  bool get isPeerMacOS => platform == PeerPlatform.macOS;

  /// Multi-display requires the peer to support multiple UI sessions.
  bool get isSupportMultiDisplay => isSupportMultiUiSession;

  /// Showing every display at once always goes through a texture.
  bool get forceTextureRender => currentDisplay == kAllDisplayValue;

  bool get cursorEmbedded => tryGetDisplay()?.cursorEmbedded ?? false;

  /// The display at [display], or the current one. Null when none are known.
  RemoteDisplay? tryGetDisplay({int? display}) {
    if (displays.isEmpty) return null;
    final index = display ?? currentDisplay;
    if (index == kAllDisplayValue) return displays.first;
    if (index < 0 || index >= displays.length) return displays.first;
    return displays[index];
  }

  /// The current display, but null when showing all of them — callers that
  /// need one concrete display must handle the combined case separately.
  RemoteDisplay? tryGetDisplayIfNotAllDisplay({int? display}) {
    if (displays.isEmpty) return null;
    final index = display ?? currentDisplay;
    if (index == kAllDisplayValue) return null;
    if (index < 0 || index >= displays.length) return null;
    return displays[index];
  }

  /// The displays currently being shown.
  List<RemoteDisplay> getCurDisplays() {
    if (currentDisplay == kAllDisplayValue) return displays;
    final one = tryGetDisplayIfNotAllDisplay();
    return one == null ? const [] : [one];
  }

  PeerInfo copyWith({
    int? currentDisplay,
    List<RemoteDisplay>? displays,
    List<Resolution>? resolutions,
    Map<String, dynamic>? platformAdditions,
  }) =>
      PeerInfo(
        version: version,
        username: username,
        hostname: hostname,
        platform: platform,
        sasEnabled: sasEnabled,
        isSupportMultiUiSession: isSupportMultiUiSession,
        currentDisplay: currentDisplay ?? this.currentDisplay,
        primaryDisplay: primaryDisplay,
        displays: displays ?? this.displays,
        features: features,
        resolutions: resolutions ?? this.resolutions,
        platformAdditions: platformAdditions ?? this.platformAdditions,
        isSet: isSet,
      );

  @override
  String toString() =>
      'PeerInfo($hostname, $platform, displays: ${displays.length}, '
      'current: $currentDisplay)';
}

/// Permissions the peer granted for this session.
///
/// The keys are the Rust permission names sent in the `permissions` event.
@immutable
class SessionPermissions {
  const SessionPermissions(this._values);

  const SessionPermissions.empty() : _values = const {};

  final Map<String, bool> _values;

  Map<String, bool> get values => Map.unmodifiable(_values);

  /// Permissions default to granted: the peer only sends the ones it denies.
  bool _get(String key) => _values[key] ?? true;

  bool get keyboard => _get('keyboard');
  bool get clipboard => _get('clipboard');
  bool get audio => _get('audio');
  bool get file => _get('file');
  bool get restart => _get('restart');
  bool get recording => _get('recording');
  bool get blockInput => _get('block_input');

  SessionPermissions merge(Map<String, bool> updates) =>
      SessionPermissions({..._values, ...updates});

  @override
  bool operator ==(Object other) =>
      other is SessionPermissions && mapEquals(other._values, _values);

  @override
  int get hashCode => Object.hashAll(
      _values.entries.map((e) => Object.hash(e.key, e.value)));
}

/// Option keys used by a running session, kept with the rest of the option
/// contract in [kOptionViewStyle] and friends.
const List<String> kSessionDisplayOptions = [
  kOptionViewStyle,
  kOptionScrollStyle,
  kOptionImageQuality,
  kOptionCodecPreference,
];
