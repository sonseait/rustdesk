import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

@immutable
class ManagedClientStatus {
  const ManagedClientStatus(
      {required this.state,
      required this.managedOnly,
      required this.deviceId,
      required this.controlPlaneUrl,
      required this.rendezvousServer,
      required this.relayServer,
      required this.credentialExpiresAt,
      required this.policyExpiresAt,
      required this.policyState,
      required this.lastError,
      this.coreReady = false,
      this.lastSuccessfulSync = '',
      this.nextRetry = ''});
  final String state;
  final bool managedOnly;
  final String deviceId;
  final String controlPlaneUrl;
  final String rendezvousServer;
  final String relayServer;
  final String credentialExpiresAt;
  final String policyExpiresAt;
  final String policyState;
  final String lastError;
  final bool coreReady;
  final String lastSuccessfulSync;
  final String nextRetry;
  bool get enrolled => deviceId.isNotEmpty && state != 'revoked';
  bool get ready {
    final now = DateTime.now().toUtc();
    return state != 'revoked' && (coreReady || state == 'ready') &&
        policyState == 'active' &&
        (DateTime.tryParse(credentialExpiresAt)?.isAfter(now) ?? false) &&
        (DateTime.tryParse(policyExpiresAt)?.isAfter(now) ?? false);
  }
}

class ManagedClientAdapter extends ChangeNotifier {
  ManagedClientAdapter({Future<String> Function()? statusReader,
      Duration pollInterval = const Duration(seconds: 2)})
      : _statusReader = statusReader, _pollInterval = pollInterval;
  static final instance = ManagedClientAdapter();
  final Future<String> Function()? _statusReader;
  final Duration _pollInterval;
  Timer? _timer;
  bool _reading = false;
  bool _disposed = false;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(_pollInterval, (_) => refresh());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) { _timer?.cancel(); _timer = null; }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
  ManagedClientStatus _status = const ManagedClientStatus(
      state: 'not_enrolled',
      managedOnly: false,
      deviceId: '',
      controlPlaneUrl: '',
      rendezvousServer: '',
      relayServer: '',
      credentialExpiresAt: '',
      policyExpiresAt: '',
      policyState: 'unavailable',
      lastError: '');
  ManagedClientStatus get status => _status;

  Future<void> refresh() async {
    if (_disposed || _reading || (_statusReader == null && !platformFFI.isInitialized)) return;
    _reading = true;
    try {
    final raw = _statusReader != null ? await _statusReader!() : PlatformFFI.instance.ffiBind.managedGetStatus();
    if (_disposed) return;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    _status = ManagedClientStatus(
        state: map['state'] as String? ?? 'not_enrolled',
        managedOnly: map['managed_only'] as bool? ?? false,
        deviceId: map['device_id'] as String? ?? '',
        controlPlaneUrl: map['control_plane_url'] as String? ?? '',
        rendezvousServer: map['rendezvous_server'] as String? ?? '',
        relayServer: map['relay_server'] as String? ?? '',
        credentialExpiresAt: map['credential_expires_at'] as String? ?? '',
        policyExpiresAt: map['policy_expires_at'] as String? ?? '',
        policyState: map['policy_state'] as String? ?? 'unavailable',
        lastError: map['last_error'] as String? ?? '',
        coreReady: map['ready'] as bool? ?? false,
        lastSuccessfulSync: map['last_successful_sync'] as String? ?? '',
        nextRetry: map['next_retry'] as String? ?? '');
    notifyListeners();
    } catch (_) {
      if (!_disposed && _status.state != 'revoked') {
        _status = ManagedClientStatus(state: 'reconnecting', managedOnly: _status.managedOnly,
            deviceId: _status.deviceId, controlPlaneUrl: _status.controlPlaneUrl,
            rendezvousServer: _status.rendezvousServer, relayServer: _status.relayServer,
            credentialExpiresAt: _status.credentialExpiresAt, policyExpiresAt: _status.policyExpiresAt,
            policyState: _status.policyState, lastError: 'owner_unavailable');
        notifyListeners();
      }
    } finally { _reading = false; }
  }

  Future<void> configure(String url) async =>
      _check(await PlatformFFI.instance.ffiBind
          .managedConfigure(controlPlaneUrl: url));
  Future<void> heartbeat() async {
    try {
    _check(await PlatformFFI.instance.ffiBind.managedHeartbeat());
    } finally { await refresh(); }
  }

  Future<void> renewCredential() async {
    try {
    _check(await PlatformFFI.instance.ffiBind.managedRenewCredential());
    } finally { await refresh(); }
  }

  Future<void> requestSessionTicketForRustdeskId(String rustdeskId) async =>
      _check(await PlatformFFI.instance.ffiBind
          .managedRequestSessionTicketForRustdeskId(
              targetRustdeskId: rustdeskId));

  Future<void> deprovision() async {
    try {
    _check(await PlatformFFI.instance.ffiBind.managedDeprovision());
    } finally { await refresh(); }
  }

  Future<void> enroll(String token, String name) async {
    try {
    final raw = await PlatformFFI.instance.ffiBind
        .managedEnroll(enrollmentToken: token, displayName: name);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['error'] != null) throw StateError(map['error']);
    } finally { await refresh(); }
  }

  void _check(String error) {
    if (error.isNotEmpty) throw StateError(error);
  }
}
