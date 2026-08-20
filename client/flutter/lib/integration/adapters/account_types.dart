import 'package:flutter/foundation.dart';

/// Account and address book payload types.
///
/// Ported from `flutter_legacy/lib/common/hbbs/hbbs.dart`. The JSON keys are
/// the hbbs API and on-disk cache contract; they must not be renamed.

enum UserStatus { disabled, unverified, normal }

UserStatus userStatusFromJson(dynamic status) {
  if (status == 0) return UserStatus.disabled;
  if (status == -1) return UserStatus.unverified;
  return UserStatus.normal;
}

int userStatusToJson(UserStatus status) {
  switch (status) {
    case UserStatus.disabled:
      return 0;
    case UserStatus.unverified:
      return -1;
    case UserStatus.normal:
      return 1;
  }
}

@immutable
class UserPayload {
  const UserPayload({
    this.name = '',
    this.displayName = '',
    this.avatar = '',
    this.email = '',
    this.note = '',
    this.verifier,
    this.status = UserStatus.normal,
    this.isAdmin = false,
  });

  UserPayload.fromJson(Map<String, dynamic> json)
      : name = json['name'] ?? '',
        displayName = json['display_name'] ?? '',
        avatar = json['avatar'] ?? '',
        email = json['email'] ?? '',
        note = json['note'] ?? '',
        verifier = json['verifier'],
        status = userStatusFromJson(json['status']),
        isAdmin = json['is_admin'] == true;

  final String name;
  final String displayName;
  final String avatar;
  final String email;
  final String note;
  final String? verifier;
  final UserStatus status;
  final bool isAdmin;

  String get displayNameOrName =>
      displayName.trim().isEmpty ? name : displayName;

  Map<String, dynamic> toJson() => {
        'name': name,
        'display_name': displayName,
        'avatar': avatar,
        'status': userStatusToJson(status),
      };

  Map<String, dynamic> toGroupCacheJson() => {
        'name': name,
        'display_name': displayName,
      };
}

@immutable
class AbProfile {
  const AbProfile({
    required this.guid,
    required this.name,
    this.owner = '',
    this.note,
    this.rule = 0,
    this.info,
  });

  AbProfile.fromJson(Map<String, dynamic> json)
      : guid = json['guid'] ?? '',
        name = json['name'] ?? '',
        owner = json['owner'] ?? '',
        note = json['note'] ?? '',
        info = json['info'],
        rule = json['rule'] ?? 0;

  final String guid;
  final String name;
  final String owner;
  final String? note;
  final dynamic info;

  /// Share rule bitmask; see [ShareRule].
  final int rule;
}

/// Address book share permissions. Values are the persisted bitmask.
class ShareRule {
  static const int read = 1;
  static const int readWrite = 2;
  static const int fullControl = 3;

  static bool canWrite(int rule) => rule >= readWrite;
  static bool canManage(int rule) => rule >= fullControl;
}

@immutable
class AbTag {
  const AbTag(this.name, this.color);

  AbTag.fromJson(Map<String, dynamic> json)
      : name = json['name'] ?? '',
        color = json['color'] ?? 0;

  final String name;
  final int color;
}

@immutable
class DeviceGroupPayload {
  const DeviceGroupPayload(this.name);

  DeviceGroupPayload.fromJson(Map<String, dynamic> json)
      : name = json['name'] ?? '';

  final String name;

  Map<String, dynamic> toGroupCacheJson() => {'name': name};
}
