import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

@immutable
class ManagedClientStatus {
  const ManagedClientStatus(
      {required this.state,
      required this.deviceId,
      required this.controlPlaneUrl,
      required this.credentialExpiresAt,
      required this.policyExpiresAt,
      required this.policyState});
  final String state;
  final String deviceId;
  final String controlPlaneUrl;
  final String credentialExpiresAt;
  final String policyExpiresAt;
  final String policyState;
  bool get enrolled => state == 'enrolled';
}

class ManagedClientAdapter extends ChangeNotifier {
  ManagedClientAdapter._();
  static final instance = ManagedClientAdapter._();
  ManagedClientStatus _status = const ManagedClientStatus(
      state: 'not_enrolled',
      deviceId: '',
      controlPlaneUrl: '',
      credentialExpiresAt: '',
      policyExpiresAt: '',
      policyState: 'unavailable');
  ManagedClientStatus get status => _status;

  Future<void> refresh() async {
    final raw = PlatformFFI.instance.ffiBind.managedGetStatus();
    final map = jsonDecode(raw) as Map<String, dynamic>;
    _status = ManagedClientStatus(
        state: map['state'] as String? ?? 'not_enrolled',
        deviceId: map['device_id'] as String? ?? '',
        controlPlaneUrl: map['control_plane_url'] as String? ?? '',
        credentialExpiresAt: map['credential_expires_at'] as String? ?? '',
        policyExpiresAt: map['policy_expires_at'] as String? ?? '',
        policyState: map['policy_state'] as String? ?? 'unavailable');
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
