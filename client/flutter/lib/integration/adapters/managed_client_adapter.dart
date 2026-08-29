import 'dart:convert';

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
      required this.lastError});
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
  bool get enrolled => state == 'enrolled';
}

class ManagedClientAdapter extends ChangeNotifier {
  ManagedClientAdapter._();
  static final instance = ManagedClientAdapter._();
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
    final raw = PlatformFFI.instance.ffiBind.managedGetStatus();
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
        lastError: map['last_error'] as String? ?? '');
    notifyListeners();
  }

  Future<void> configure(String url) async =>
      _check(await PlatformFFI.instance.ffiBind
          .managedConfigure(controlPlaneUrl: url));
  Future<void> heartbeat() async {
    _check(await PlatformFFI.instance.ffiBind.managedHeartbeat());
    await refresh();
  }

  Future<void> renewCredential() async {
    _check(await PlatformFFI.instance.ffiBind.managedRenewCredential());
    await refresh();
  }

  Future<void> requestSessionTicketForRustdeskId(String rustdeskId) async =>
      _check(await PlatformFFI.instance.ffiBind
          .managedRequestSessionTicketForRustdeskId(
              targetRustdeskId: rustdeskId));

  Future<void> deprovision() async {
    _check(await PlatformFFI.instance.ffiBind.managedDeprovision());
    await refresh();
  }

  Future<void> enroll(String token, String name) async {
    final raw = await PlatformFFI.instance.ffiBind
        .managedEnroll(enrollmentToken: token, displayName: name);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['error'] != null) throw StateError(map['error']);
    await refresh();
  }

  void _check(String error) {
    if (error.isNotEmpty) throw StateError(error);
  }
}
