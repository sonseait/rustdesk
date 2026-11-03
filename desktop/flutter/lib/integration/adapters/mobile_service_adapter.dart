import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';
import 'package:flutter_hbb/integration/platform/android_host_channel.dart';
import 'package:flutter_hbb/integration/platform/android_permissions.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// A permission the sharing service wants, and whether it has it.
@immutable
class ServicePermission {
  const ServicePermission({
    required this.permission,
    required this.granted,
    required this.required,
  });

  final String permission;
  final bool granted;

  /// False when the service still starts without it, losing only a feature.
  final bool required;
}

/// What the sharing service can currently do.
///
/// The Android host owns these: it flips them as the user grants a permission
/// or the media projection starts, and pushes each change on the host channel.
@immutable
class MobileServiceState {
  const MobileServiceState({
    this.isRunning = false,
    this.canCaptureScreen = false,
    this.canReceiveInput = false,
    this.canShareAudio = false,
    this.canTransferFiles = false,
    this.canShareClipboard = false,
  });

  final bool isRunning;

  /// Whether the media projection was granted. Without it there is nothing to
  /// share, so the service is running but useless.
  final bool canCaptureScreen;

  final bool canReceiveInput;
  final bool canShareAudio;
  final bool canTransferFiles;
  final bool canShareClipboard;

  MobileServiceState copyWith({
    bool? isRunning,
    bool? canCaptureScreen,
    bool? canReceiveInput,
    bool? canShareAudio,
    bool? canTransferFiles,
    bool? canShareClipboard,
  }) =>
      MobileServiceState(
        isRunning: isRunning ?? this.isRunning,
        canCaptureScreen: canCaptureScreen ?? this.canCaptureScreen,
        canReceiveInput: canReceiveInput ?? this.canReceiveInput,
        canShareAudio: canShareAudio ?? this.canShareAudio,
        canTransferFiles: canTransferFiles ?? this.canTransferFiles,
        canShareClipboard: canShareClipboard ?? this.canShareClipboard,
      );

  @override
  bool operator ==(Object other) =>
      other is MobileServiceState &&
      other.isRunning == isRunning &&
      other.canCaptureScreen == canCaptureScreen &&
      other.canReceiveInput == canReceiveInput &&
      other.canShareAudio == canShareAudio &&
      other.canTransferFiles == canTransferFiles &&
      other.canShareClipboard == canShareClipboard;

  @override
  int get hashCode => Object.hash(isRunning, canCaptureScreen, canReceiveInput,
      canShareAudio, canTransferFiles, canShareClipboard);
}

/// Someone connected to this device right now.
///
/// Ported from `Client` in `flutter_legacy/lib/models/server_model.dart`. The
/// JSON keys are the core's connection-manager contract.
@immutable
class ConnectedClient {
  const ConnectedClient({
    required this.id,
    required this.peerId,
    required this.name,
    this.authorized = false,
    this.isFileTransfer = false,
    this.isViewCamera = false,
    this.isTerminal = false,
    this.portForward = '',
    this.keyboard = false,
    this.clipboard = false,
    this.audio = false,
    this.file = false,
    this.recording = false,
    this.disconnected = false,
  });

  factory ConnectedClient.fromJson(Map<String, dynamic> json) =>
      ConnectedClient(
        id: json['id'] as int? ?? 0,
        peerId: json['peer_id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        authorized: json['authorized'] == true,
        isFileTransfer: json['is_file_transfer'] == true,
        isViewCamera: json['is_view_camera'] == true,
        isTerminal: json['is_terminal'] == true,
        portForward: json['port_forward']?.toString() ?? '',
        keyboard: json['keyboard'] == true,
        clipboard: json['clipboard'] == true,
        audio: json['audio'] == true,
        file: json['file'] == true,
        recording: json['recording'] == true,
        disconnected: json['disconnected'] == true,
      );

  /// The connection's inner id, which is what accepting or closing it needs.
  final int id;

  /// The connecting device's RustDesk id.
  final String peerId;

  final String name;

  /// False while the connection is still waiting to be accepted.
  final bool authorized;

  final bool isFileTransfer;
  final bool isViewCamera;
  final bool isTerminal;
  final String portForward;
  final bool keyboard;
  final bool clipboard;
  final bool audio;
  final bool file;
  final bool recording;
  final bool disconnected;

  /// What this connection is doing, for a one-line label.
  String get toolLabel {
    if (isFileTransfer) return 'File transfer';
    if (isViewCamera) return 'Camera';
    if (isTerminal) return 'Terminal';
    if (portForward.isNotEmpty) return 'Port forward';
    return 'Screen sharing';
  }

  /// A name to show, falling back to the id when the peer sent none.
  String get displayName => name.isEmpty ? peerId : name;
}

/// Starting and stopping screen sharing on a mobile device.
///
/// Ported from `ServerModel` in `flutter_legacy/lib/models/server_model.dart`.
/// Starting is a negotiation rather than a call: several Android permissions
/// are asked for first, and the host confirms the media projection separately,
/// so the service is only really on once `start_capture` arrives.
///
/// The native method names (`init_service`, `stop_service`) are the existing
/// host contract.
class MobileServiceAdapter extends ChangeNotifier {
  MobileServiceAdapter({
    OptionRepository? options,
    AndroidPermissions? permissions,
    AndroidHostChannel? host,
  })  : _options = options ?? OptionRepository.instance,
        _permissions = permissions ?? AndroidPermissions.instance,
        _host = host ?? AndroidHostChannel.instance;

  static final MobileServiceAdapter instance = MobileServiceAdapter();

  final OptionRepository _options;
  final AndroidPermissions _permissions;
  final AndroidHostChannel _host;

  /// Host methods that start and stop the foreground service.
  static const String initServiceMethod = 'init_service';
  static const String stopServiceMethod = 'stop_service';

  /// Android 13 introduced the notification permission; earlier versions
  /// grant it at install time.
  static const int notificationPermissionSdk = 33;

  /// Overlay windows arrived in Android 6.
  static const int overlayPermissionSdk = 23;

  /// Audio capture from the projection needs Android 11.
  static const int audioCaptureSdk = 30;

  MobileServiceState _state = const MobileServiceState();
  var _listening = false;
  List<ConnectedClient> _clients = const [];

  MobileServiceState get state => _state;

  /// Who is connected right now, waiting-for-approval connections included.
  List<ConnectedClient> get clients => List.unmodifiable(_clients);

  /// Connections still waiting to be accepted.
  List<ConnectedClient> get pendingClients =>
      [for (final client in _clients) if (!client.authorized) client];

  bool get isRunning => _state.isRunning;

  /// Whether the service is on but has no screen to share, which reads as
  /// working while nothing is actually shared.
  bool get isRunningWithoutCapture =>
      _state.isRunning && !_state.canCaptureScreen;

  /// Begin tracking the host's service state. Safe to call more than once.
  void start() {
    if (_listening || !isAndroid) return;
    _listening = true;
    _host.addStateListener(_onStateChanged);
    _host.addEventListener(_onHostEvent);
  }

  @override
  void dispose() {
    if (_listening) {
      _host.removeStateListener(_onStateChanged);
      _host.removeEventListener(_onHostEvent);
      _listening = false;
    }
    super.dispose();
  }

  void _onStateChanged(String name, bool value) {
    switch (name) {
      case 'media':
        _state = _state.copyWith(canCaptureScreen: value);
        // The host grants the projection after the service starts, so this
        // is what turns a started service into a working one.
        if (value && !_state.isRunning) {
          _state = _state.copyWith(isRunning: true);
        }
      case 'input':
        // The core's permission has to follow the host's, or the UI would
        // show input allowed while Android refuses it.
        _writeOption(kOptionEnableKeyboard, value);
        _state = _state.copyWith(canReceiveInput: value);
      default:
        debugPrint('unhandled service state: $name');
        return;
    }
    notifyListeners();
  }

  /// Feed the adapter a host event, as the channel would. [start] is a no-op
  /// off Android, so a test wires this up directly.
  @visibleForTesting
  void handleHostEventForTest(AndroidHostEvent event) => _onHostEvent(event);

  void _onHostEvent(AndroidHostEvent event) {
    switch (event) {
      case AndroidHostEvent.captureStarted:
        _state = _state.copyWith(isRunning: true, canCaptureScreen: true);
      case AndroidHostEvent.captureCancelled:
        // The user dismissed the projection prompt, so nothing is shared.
        _state =
            _state.copyWith(isRunning: false, canCaptureScreen: false);
      case AndroidHostEvent.serviceStopped:
        _state = const MobileServiceState();
    }
    notifyListeners();
  }

  /// Write an option without waiting.
  ///
  /// The host pushes state changes synchronously, so this cannot await; a
  /// failure is logged rather than left to become an unhandled rejection.
  void _writeOption(String key, bool value) {
    _options.setBool(key, value).catchError(
        (Object e) => debugPrint('failed to write $key: $e'));
  }

  // ------------------------------------------------------------- permissions

  /// The permissions sharing wants, and whether Android has granted them.
  ///
  /// Only the notification permission is required: without it Android kills a
  /// foreground service. The rest each cost one feature.
  Future<List<ServicePermission>> permissions() async {
    if (!isAndroid) return const [];
    return [
      if (androidVersion >= notificationPermissionSdk)
        ServicePermission(
          permission: kAndroid13Notification,
          granted: await _permissions.check(kAndroid13Notification),
          required: true,
        ),
      if (androidVersion >= overlayPermissionSdk && !isFloatingWindowDisabled)
        ServicePermission(
          permission: kSystemAlertWindow,
          granted: await _permissions.check(kSystemAlertWindow),
          required: false,
        ),
      if (androidVersion >= audioCaptureSdk)
        ServicePermission(
          permission: kRecordAudio,
          granted: await _permissions.check(kRecordAudio),
          required: false,
        ),
      ServicePermission(
        permission: kManageExternalStorage,
        granted: await _permissions.check(kManageExternalStorage),
        required: false,
      ),
    ];
  }

  /// Whether the deployment turned the floating window off, in which case its
  /// overlay permission is not worth asking for.
  bool get isFloatingWindowDisabled =>
      _options.getLocalBool(kOptionDisableFloatingWindow);

  Future<bool> requestPermission(String permission) =>
      _permissions.request(permission);

  /// Reconcile the core's permissions with what Android actually allows.
  ///
  /// A revoked Android permission must switch the core's option off, or the
  /// UI would offer a feature the OS refuses.
  Future<void> syncPermissions() async {
    if (!isAndroid) return;

    final canRecord = androidVersion >= audioCaptureSdk &&
        await _permissions.check(kRecordAudio);
    if (!canRecord) await _options.setBool(kOptionEnableAudio, false);

    final canReadFiles = await _permissions.check(kManageExternalStorage);
    if (!canReadFiles) {
      await _options.setBool(kOptionEnableFileTransfer, false);
    }

    _state = _state.copyWith(
      canShareAudio: canRecord && _options.getBool(kOptionEnableAudio),
      canTransferFiles:
          canReadFiles && _options.getBool(kOptionEnableFileTransfer),
      canShareClipboard: _options.getBool(kOptionEnableClipboard),
    );
    notifyListeners();
  }

  // ---------------------------------------------------------------- starting

  /// Ask for what sharing needs, and report whether the required parts were
  /// granted.
  ///
  /// The optional permissions are asked for too, but a refusal only costs the
  /// feature: the service still starts and shares the screen.
  Future<bool> requestServicePermissions() async {
    if (!isAndroid) return true;

    if (androidVersion >= notificationPermissionSdk &&
        !await _permissions.ensure(kAndroid13Notification)) {
      // Android kills a foreground service with no notification, so starting
      // without this would stop on its own moments later.
      return false;
    }
    if (androidVersion >= overlayPermissionSdk && !isFloatingWindowDisabled) {
      await _permissions.ensure(kSystemAlertWindow);
    }
    await _permissions.ensure(kManageExternalStorage);
    return true;
  }

  /// Start sharing.
  ///
  /// Returns false when a required permission was refused. The screen is not
  /// shared until Android grants the projection, which arrives separately as
  /// [AndroidHostEvent.captureStarted].
  Future<bool> startService() async {
    if (!await requestServicePermissions()) return false;
    try {
      await platformFFI.invokeMethod(initServiceMethod);
      await bind.mainStartService();
    } catch (e) {
      debugPrint('failed to start the sharing service: $e');
      return false;
    }
    // Not canCaptureScreen: the projection is a separate grant, and claiming
    // it here would show sharing as working before it is.
    _state = _state.copyWith(isRunning: true);
    notifyListeners();
    await syncPermissions();
    return true;
  }

  Future<void> stopService() async {
    try {
      await platformFFI.invokeMethod(stopServiceMethod);
      await bind.mainStopService();
    } catch (e) {
      debugPrint('failed to stop the sharing service: $e');
    }
    _state = const MobileServiceState();
    notifyListeners();
  }

  // ----------------------------------------------------------------- clients

  /// Re-read who is connected.
  ///
  /// The core owns the list; it is not pushed, so a surface showing clients
  /// refreshes after anything that could change it.
  Future<void> refreshClients() async {
    try {
      final payload = await bind.cmGetClientsState();
      if (payload.isEmpty) {
        _clients = const [];
      } else {
        final decoded = jsonDecode(payload);
        _clients = decoded is! List
            ? const []
            : [
                for (final entry in decoded)
                  if (entry is Map<String, dynamic>)
                    ConnectedClient.fromJson(entry)
              ];
      }
    } catch (e) {
      debugPrint('failed to read the connected clients: $e');
      _clients = const [];
    }
    notifyListeners();
  }

  /// Accept or refuse a connection that is waiting.
  Future<void> respondToClient(ConnectedClient client, bool accept) async {
    try {
      await bind.cmLoginRes(connId: client.id, res: accept);
    } catch (e) {
      debugPrint('failed to answer connection ${client.id}: $e');
    }
    await refreshClients();
  }

  /// Disconnect a client.
  Future<void> disconnectClient(ConnectedClient client) async {
    try {
      await bind.cmCloseConnection(connId: client.id);
    } catch (e) {
      debugPrint('failed to close connection ${client.id}: $e');
    }
    await refreshClients();
  }

  /// Test-only: set the state the host would have reported.
  @visibleForTesting
  void setStateForTest(MobileServiceState state) {
    _state = state;
    notifyListeners();
  }

  /// Test-only: set the clients the core would have reported.
  @visibleForTesting
  void setClientsForTest(List<ConnectedClient> clients) {
    _clients = clients;
    notifyListeners();
  }
}

/// The process-wide mobile service adapter.
MobileServiceAdapter get mobileService => MobileServiceAdapter.instance;
