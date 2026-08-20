import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';

/// Rendezvous server connection state, as reported by `mainGetConnectStatus`.
///
/// The numeric values are the Rust `status_num` contract:
/// -1 connecting, 0 disconnected, 1 connected.
enum ConnectStatus { connecting, disconnected, connected, unknown }

ConnectStatus connectStatusFrom(int statusNum) {
  switch (statusNum) {
    case -1:
      return ConnectStatus.connecting;
    case 0:
      return ConnectStatus.disconnected;
    case 1:
      return ConnectStatus.connected;
    default:
      return ConnectStatus.unknown;
  }
}

/// How incoming connections authenticate. Values are the persisted option
/// strings and must not be renamed.
const String kUseTemporaryPassword = 'use-temporary-password';
const String kUsePermanentPassword = 'use-permanent-password';
const String kUseBothPasswords = 'use-both-passwords';

/// A snapshot of local service state.
///
/// Every field comes from the Rust core. [isLoaded] is false until the first
/// successful poll, so the UI can distinguish "not read yet" from "read and
/// the service is off".
@immutable
class ServiceStatus {
  const ServiceStatus({
    required this.isLoaded,
    required this.deviceId,
    required this.connectStatus,
    required this.isServiceRunning,
    required this.temporaryPassword,
    required this.verificationMethod,
    required this.temporaryPasswordLength,
    required this.approveMode,
    required this.allowNumericOneTimePassword,
    this.error,
  });

  const ServiceStatus.initial()
      : isLoaded = false,
        deviceId = '',
        connectStatus = ConnectStatus.unknown,
        isServiceRunning = false,
        temporaryPassword = '',
        verificationMethod = kUseBothPasswords,
        temporaryPasswordLength = '6',
        approveMode = '',
        allowNumericOneTimePassword = false,
        error = null;

  final bool isLoaded;

  /// This device's RustDesk ID. Empty until the core has generated it.
  final String deviceId;

  final ConnectStatus connectStatus;

  /// Whether the local sharing service is accepting connections. Derived from
  /// the `stop-service` option, which the core owns.
  final bool isServiceRunning;

  final String temporaryPassword;

  /// One of [kUseTemporaryPassword], [kUsePermanentPassword],
  /// [kUseBothPasswords]. Unrecognized stored values resolve to both.
  final String verificationMethod;

  /// One of '6', '8', '10'. Unrecognized stored values resolve to '6'.
  final String temporaryPasswordLength;

  final String approveMode;
  final bool allowNumericOneTimePassword;

  /// Set when the last poll failed. The previous values are retained so the
  /// UI can show stale data alongside the error rather than blanking.
  final Object? error;

  bool get hasError => error != null;

  ServiceStatus copyWith({
    bool? isLoaded,
    String? deviceId,
    ConnectStatus? connectStatus,
    bool? isServiceRunning,
    String? temporaryPassword,
    String? verificationMethod,
    String? temporaryPasswordLength,
    String? approveMode,
    bool? allowNumericOneTimePassword,
    Object? error,
    bool clearError = false,
  }) {
    return ServiceStatus(
      isLoaded: isLoaded ?? this.isLoaded,
      deviceId: deviceId ?? this.deviceId,
      connectStatus: connectStatus ?? this.connectStatus,
      isServiceRunning: isServiceRunning ?? this.isServiceRunning,
      temporaryPassword: temporaryPassword ?? this.temporaryPassword,
      verificationMethod: verificationMethod ?? this.verificationMethod,
      temporaryPasswordLength:
          temporaryPasswordLength ?? this.temporaryPasswordLength,
      approveMode: approveMode ?? this.approveMode,
      allowNumericOneTimePassword:
          allowNumericOneTimePassword ?? this.allowNumericOneTimePassword,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ServiceStatus &&
      other.isLoaded == isLoaded &&
      other.deviceId == deviceId &&
      other.connectStatus == connectStatus &&
      other.isServiceRunning == isServiceRunning &&
      other.temporaryPassword == temporaryPassword &&
      other.verificationMethod == verificationMethod &&
      other.temporaryPasswordLength == temporaryPasswordLength &&
      other.approveMode == approveMode &&
      other.allowNumericOneTimePassword == allowNumericOneTimePassword &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        isLoaded,
        deviceId,
        connectStatus,
        isServiceRunning,
        temporaryPassword,
        verificationMethod,
        temporaryPasswordLength,
        approveMode,
        allowNumericOneTimePassword,
        error,
      );
}

/// Normalize a stored verification method, matching the legacy fallback.
String normalizeVerificationMethod(String stored) {
  const known = [
    kUseTemporaryPassword,
    kUsePermanentPassword,
    kUseBothPasswords,
  ];
  return known.contains(stored) ? stored : kUseBothPasswords;
}

/// Normalize a stored one-time password length, matching the legacy fallback.
String normalizeTemporaryPasswordLength(String stored) {
  const known = ['6', '8', '10'];
  return known.contains(stored) ? stored : '6';
}

/// Read-only view of local service state.
///
/// Polls the core on the same 500ms cadence as the legacy `ServerModel` and
/// notifies only when the snapshot actually changes. Milestone 0 is read-only:
/// starting and stopping the service arrives with the workspace migration.
class ServiceStatusAdapter extends ChangeNotifier {
  ServiceStatusAdapter({
    OptionRepository? optionRepository,
    Duration pollInterval = const Duration(milliseconds: 500),
  })  : _options = optionRepository ?? OptionRepository.instance,
        _pollInterval = pollInterval;

  static final ServiceStatusAdapter instance = ServiceStatusAdapter();

  final OptionRepository _options;
  final Duration _pollInterval;

  Timer? _timer;
  bool _polling = false;
  ServiceStatus _status = const ServiceStatus.initial();

  ServiceStatus get status => _status;

  bool get isRunning => _timer != null;

  /// Begin polling. Safe to call more than once.
  ///
  /// Does nothing when the bridge failed to initialize; the UI should be
  /// reading [AppBootstrap.status] in that case.
  void start() {
    if (_timer != null) return;
    if (!platformFFI.isInitialized) {
      debugPrint('ServiceStatusAdapter.start before the bridge is ready');
      return;
    }
    unawaited(refresh());
    _timer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Read the current state once.
  Future<void> refresh() async {
    if (_polling) return;
    _polling = true;
    try {
      final rawStatus = await bind.mainGetConnectStatus();
      final decoded = jsonDecode(rawStatus) as Map<String, dynamic>;
      final statusNum = decoded['status_num'] as int? ?? 0;

      final next = ServiceStatus(
        isLoaded: true,
        deviceId: await bind.mainGetMyId(),
        connectStatus: connectStatusFrom(statusNum),
        // The core stores the inverse: `stop-service` true means stopped.
        isServiceRunning: !_options.getBool(kOptionStopService),
        temporaryPassword: await bind.mainGetTemporaryPassword(),
        verificationMethod: normalizeVerificationMethod(
            await _options.getStringAsync(kOptionVerificationMethod)),
        temporaryPasswordLength: normalizeTemporaryPasswordLength(
            await _options.getStringAsync(kOptionTemporaryPasswordLength)),
        approveMode: await _options.getStringAsync(kOptionApproveMode),
        allowNumericOneTimePassword: await _options
            .getBoolAsync(kOptionAllowNumericOneTimePassword),
      );
      _apply(next);
    } catch (e, s) {
      debugPrint('failed to read service status: $e');
      debugPrintStack(stackTrace: s);
      // Keep the last known values and surface the failure.
      _apply(_status.copyWith(error: e));
    } finally {
      _polling = false;
    }
  }

  void _apply(ServiceStatus next) {
    if (next == _status) return;
    _status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
