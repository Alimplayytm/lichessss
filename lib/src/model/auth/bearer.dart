import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:lichess_mobile/src/constants.dart';
import 'package:lichess_mobile/src/model/auth/auth_user.dart';

final hmacSha1 = Hmac(sha1, utf8.encode(kLichessWSSecret));

/// Sign a bearer token with the lichess secret.
String signBearerToken(String token) {
  final digest = hmacSha1.convert(utf8.encode(token));
  return '$token:$digest';
}

/// Personal API credentials are sent as documented, without the official-client signature.
String authBearer(AuthUser user) => user.usesPublicApi ? user.token : signBearerToken(user.token);

String personalTokenUserAgent(String version) =>
    'Lichessss/$version (+https://github.com/Alimplayytm/lichessss; public API)';
