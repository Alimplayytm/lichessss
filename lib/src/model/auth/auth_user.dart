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
  }) = _AuthUser;

  factory fromJson(Map<String, dynamic> json) => _$AuthUserFromJson(json);

  @override
  String toString() =>
      'AuthUser(user: ${user.id}, personalToken: $isPersonalToken, token: [redacted])';
}
