import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';

/// Session options the toolbar toggles.
///
/// The values are the Rust `keys::OPTION_*` strings; several use underscores
/// rather than dashes and must not be "normalized".
enum SessionToggle {
  /// Mute the peer's audio. Stored inverted: on means audio is *off*.
  disableAudio(kOptionDisableAudio, inverted: true),

  /// Stop sharing the clipboard. Also stored inverted.
  disableClipboard(kOptionDisableClipboard, inverted: true),

  /// Allow copying files through the clipboard.
  fileCopyPaste(kOptionEnableFileCopyPaste),

  /// Blank the peer's screen while controlling it.
  privacyMode(kOptionPrivacyMode),

  /// Lock the peer's session when this one ends.
  lockAfterSessionEnd(kOptionLockAfterSessionEnd),

  /// Draw the peer's cursor on the canvas.
  showRemoteCursor(kOptionShowRemoteCursor),

  /// Send input without moving the peer's real cursor.
  showMyCursor(kOptionToggleShowMyCursor),

  /// Watch without sending any input.
  viewOnly(kOptionToggleViewOnly),

  /// Invert scroll direction.
  reverseMouseWheel(kKeyReverseMouseWheel),

  /// Swap the primary and secondary mouse buttons.
  swapLeftRightMouse(kOptionSwapLeftRightMouse);

  const SessionToggle(this.key, {this.inverted = false});

  /// The persisted option key.
  final String key;

  /// True when the stored option means the opposite of what the UI shows.
  ///
  /// `disable_audio` is stored as "audio is off", but the toolbar shows
  /// "Audio". Without this the switches read backwards.
  final bool inverted;
}

/// Reads and writes the options of one live session.
///
/// `sessionToggleOption` flips a value rather than setting it, so the current
/// state has to be read back after every write — that is the contract the core
/// exposes, and assuming otherwise makes switches drift out of sync.
class SessionOptions extends ChangeNotifier {
  SessionOptions({required this.sessionId, RustdeskImpl? bindOverride})
      : _bindOverride = bindOverride;

  final UuidValue sessionId;
  final RustdeskImpl? _bindOverride;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  final Map<SessionToggle, bool> _cache = {};
  bool _isRecording = false;

  /// Whether the session is being recorded.
  bool get isRecording => _isRecording;

  /// The current value of [toggle] as the UI should show it.
  bool isEnabled(SessionToggle toggle) {
    final stored = _cache[toggle];
    if (stored == null) return _readStored(toggle);
    return stored;
  }

  bool _readStored(SessionToggle toggle) {
    try {
      final raw =
          _bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: toggle.key);
      // An inverted option stores the opposite of what the UI shows.
      final value = toggle.inverted ? !raw : raw;
      _cache[toggle] = value;
      return value;
    } catch (e) {
      debugPrint('failed to read ${toggle.key}: $e');
      return false;
    }
  }

  /// Read every toggle from the core.
  void refresh() {
    for (final toggle in SessionToggle.values) {
      _cache.remove(toggle);
      _readStored(toggle);
    }
    _refreshRecording();
    notifyListeners();
  }

  void _refreshRecording() {
    try {
      _isRecording = _bind.sessionGetIsRecording(sessionId: sessionId);
    } catch (e) {
      debugPrint('failed to read the recording state: $e');
      _isRecording = false;
    }
  }

  /// Flip [toggle] and read back what the core actually stored.
  Future<void> toggle(SessionToggle option) async {
    try {
      await _bind.sessionToggleOption(
          sessionId: sessionId, value: option.key);
      // The core owns the value; re-read rather than assuming it flipped.
      _cache.remove(option);
      _readStored(option);
      notifyListeners();
    } catch (e) {
      debugPrint('failed to toggle ${option.key}: $e');
    }
  }

  /// Start or stop recording the session.
  Future<void> setRecording(bool start) async {
    try {
      await _bind.sessionRecordScreen(sessionId: sessionId, start: start);
      _refreshRecording();
      notifyListeners();
    } catch (e) {
      debugPrint('failed to change the recording state: $e');
    }
  }

  /// The current image quality preset.
  Future<String> imageQuality() async {
    try {
      return await _bind.sessionGetImageQuality(sessionId: sessionId) ??
          kRemoteImageQualityBalanced;
    } catch (e) {
      debugPrint('failed to read the image quality: $e');
      return kRemoteImageQualityBalanced;
    }
  }

  Future<void> setImageQuality(String value) async {
    await _bind.sessionSetImageQuality(sessionId: sessionId, value: value);
    notifyListeners();
  }

  /// Ask the peer to change a display's resolution.
  Future<void> setResolution({
    required int display,
    required int width,
    required int height,
  }) async {
    await _bind.sessionChangeResolution(
      sessionId: sessionId,
      display: display,
      width: width,
      height: height,
    );
  }
}

/// The image quality presets, in the order the menu shows them.
const List<(String, String)> kImageQualityPresets = [
  (kRemoteImageQualityBest, 'Best quality'),
  (kRemoteImageQualityBalanced, 'Balanced'),
  (kRemoteImageQualityLow, 'Best speed'),
];
