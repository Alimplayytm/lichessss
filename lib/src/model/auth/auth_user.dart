import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:lichess_mobile/src/model/user/user.dart';

part 'auth_user.freezed.dart';
part 'auth_user.g.dart';

@Freezed(fromJson: true, toJson: true, toStringOverride: false)
sealed class const AuthUser._() with _$AuthUser {
  const factory({
    required LightUser user,
    required String token,
    @Default(false) bool isPersonalToken,
    @Default(false) bool isPublicOAuth,
  }) = _AuthUser;

  factory fromJson(Map<String, dynamic> json) => _$AuthUserFromJson(json);

  /// Public credentials must never be signed or used with private mobile APIs.
  bool get usesPublicApi => isPersonalToken || isPublicOAuth;

  @override
  String toString() =>
      'AuthUser(user: ${user.id}, personalToken: $isPersonalToken, token: [redacted])';
}
