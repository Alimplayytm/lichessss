import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:lichess_mobile/src/constants.dart';
import 'package:lichess_mobile/src/model/auth/auth_diagnostics.dart';
import 'package:lichess_mobile/src/model/auth/auth_user.dart';
import 'package:lichess_mobile/src/model/auth/bearer.dart';
import 'package:lichess_mobile/src/model/auth/sign_in_failure_reporter.dart';
import 'package:lichess_mobile/src/model/user/user.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:logging/logging.dart';

/// Host of the custom URI scheme callback. Must stay in sync with the
/// intent-filter for `net.openid.appauth.RedirectUriReceiverActivity` in
/// `android/app/src/main/AndroidManifest.xml` and the `CFBundleURLSchemes` entry in `ios/Runner/Info.plist`.
const _kOAuthCustomSchemeCallbackHost = 'login-callback';

/// The custom URI scheme redirect for OAuth.
///
/// Custom schemes are more universally supported across Android browsers/OEMs than
/// HTTPS App Link redirects, so they are used on every platform and host.
const kOAuthRedirectUri = '$kLichessCustomUriSchemeName://$_kOAuthCustomSchemeCallbackHost';
const oauthScopes = ['web:mobile'];

/// Thrown when the user dismisses the OAuth session before completing it.
///
/// This is distinct from a genuine sign-in failure: the UI should silently
/// ignore it rather than surfacing an error.
class const SignInCancelledException() implements Exception {
  @override
  String toString() => 'Sign-in was cancelled.';
}

/// Thrown when the server rate-limits one of the email login requests (429).
class const EmailLoginRateLimitException({final Duration? retryAfter}) implements Exception {
  @override
  String toString() => 'Too many email login requests.';
}

/// Thrown when the submitted login code is unknown, expired, or already used (404).
class const InvalidEmailLoginCodeException() implements Exception {
  @override
  String toString() => 'Invalid or expired email login code.';
}

/// A provider for [FlutterAppAuth].
final appAuthProvider = Provider<FlutterAppAuth>((Ref ref) {
  return const FlutterAppAuth();
}, name: 'AppAuthProvider');

final authRepositoryProvider = Provider<AuthRepository>((Ref ref) {
  final appAuth = ref.read(appAuthProvider);
  return AuthRepository(ref, appAuth);
}, name: 'AuthRepositoryProvider');

class AuthRepository(final Ref _ref, final FlutterAppAuth _appAuth) {
  final Logger _log = Logger('AuthRepository');
  LichessClient get _client => _ref.read(lichessClientProvider);

  /// Sign in with Lichess using OAuth 2.0 PKCE using the system browser.
  Future<AuthUser> signIn() async {
    logAuthEvent(
      .browser,
      'start; host=$kLichessHost; client=$kLichessClientId; '
      'redirect=$kOAuthRedirectUri; signing=$authSecretConfiguration',
    );
    final AuthorizationTokenResponse authResp;
    try {
      authResp = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          kLichessClientId,
          kOAuthRedirectUri,
          allowInsecureConnections: kDebugMode,
          serviceConfiguration: AuthorizationServiceConfiguration(
            authorizationEndpoint: lichessUri('/oauth').toString(),
            tokenEndpoint: lichessUri('/api/token').toString(),
          ),
          scopes: oauthScopes,
        ),
      );
    } on FlutterAppAuthUserCancelledException {
      logAuthEvent(.browser, 'cancelled');
      throw const SignInCancelledException();
    } catch (e, st) {
      if (authDiagnosticsEnabled) {
        final reason = e is FlutterAppAuthPlatformException
            ? safeAuthReason(e.platformErrorDetails.error)
            : 'platform_or_network_error';
        logAuthEvent(.browser, 'failed; reason=$reason');
        throw AuthDiagnosticException(stage: .browser, reason: reason);
      }
      await reportSignInFailure(_ref, e, st);
      rethrow;
    }

    _log.fine('Got OAuth token response');

    final token = authResp.accessToken;
    if (token == null || token.isEmpty) {
      logAuthEvent(.browser, 'token=missing');
      if (authDiagnosticsEnabled) {
        throw const AuthDiagnosticException(stage: .browser, reason: 'missing_token');
      }
      throw Exception('Access token not found.');
    }

    final type = authResp.tokenType == null
        ? 'not-reported'
        : authResp.tokenType!.toLowerCase() == 'bearer'
        ? 'bearer'
        : 'other';
    final scope = authResp.scopes == null
        ? 'not-reported'
        : authResp.scopes!.contains('web:mobile')
        ? 'present'
        : 'absent';
    final expiry = authResp.accessTokenExpirationDateTime;
    logAuthEvent(
      .browser,
      'token=received; tokenType=$type; mobileScope=$scope; '
      'expired=${expiry == null ? 'unknown' : expiry.isBefore(DateTime.now())}; next=account',
    );
    return await _fetchAuthUser(token);
  }

  /// Asks lichess to email a 6 character login code for the [username] account to [email].
  ///
  /// Throws an [EmailLoginRateLimitException] if the request is rate-limited.
  Future<void> requestEmailLoginCode({required String username, required String email}) async {
    final url = lichessUri('/auth/mobile-code/email');
    // The default client is used on purpose: this endpoint is unauthenticated, and its 429 responses
    // are deliberate rate limiting that must not be retried like [lichessClientProvider] does.
    final response = await _postEmailLogin(.emailRequest, url, {
      'email': email,
      'username': username,
    });

    if (response.statusCode == 429) {
      throw EmailLoginRateLimitException(
        retryAfter: authDiagnosticsEnabled
            ? authRetryAfter(response.headers['retry-after'], now: DateTime.now())
            : null,
      );
    }
    if (response.statusCode >= 400) {
      throw ServerException(
        response.statusCode,
        'Could not request an email login code: ${response.statusCode}',
        url,
        null,
      );
    }
  }

  /// Exchanges the login [code] received by [email] for an OAuth token on the [username] account,
  /// and fetches the account it belongs to.
  ///
  /// Throws an [InvalidEmailLoginCodeException] if the code is unknown, expired, or already used,
  /// and an [EmailLoginRateLimitException] if the request is rate-limited.
  Future<AuthUser> signInWithEmailCode({
    required String username,
    required String email,
    required String code,
  }) async {
    final url = lichessUri('/auth/mobile-code/bearer');
    final response = await _postEmailLogin(.emailExchange, url, {
      'email': email,
      'username': username,
      'code': code,
    });

    switch (response.statusCode) {
      case 429:
        throw EmailLoginRateLimitException(
          retryAfter: authDiagnosticsEnabled
              ? authRetryAfter(response.headers['retry-after'], now: DateTime.now())
              : null,
        );
      case 404:
        throw const InvalidEmailLoginCodeException();
    }
    if (response.statusCode >= 400) {
      throw ServerException(
        response.statusCode,
        'Could not exchange the email login code: ${response.statusCode}',
        url,
        null,
      );
    }

    final token = response.body.trim();
    if (token.isEmpty) {
      if (authDiagnosticsEnabled) {
        throw const AuthDiagnosticException(stage: .emailExchange, reason: 'missing_token');
      }
      throw Exception('Access token not found.');
    }

    _log.fine('Got a token from the email login code');
    logAuthEvent(.emailExchange, 'token=received; next=account');

    return await _fetchAuthUser(token);
  }

  /// Fetches the account owning [token] and pairs it with the token.
  Future<AuthUser> _fetchAuthUser(String token) async {
    if (authDiagnosticsEnabled) {
      return await _fetchAuthUserWithDiagnostics(token);
    }
    final user = await _client.readJson(
      Uri(path: '/api/account'),
      headers: {'Authorization': 'Bearer ${signBearerToken(token)}'},
      mapper: User.fromServerJson,
    );
    return AuthUser(token: token, user: user.lightUser);
  }

  Future<http.Response> _postEmailLogin(AuthStage stage, Uri url, Map<String, String> body) async {
    logAuthEvent(stage, 'start; host=$kLichessHost');
    try {
      final pending = _ref.read(defaultClientProvider).post(url, body: body);
      final response = await (authDiagnosticsEnabled
          ? pending.timeout(const Duration(seconds: 30))
          : pending);
      logAuthResponse(stage, response);
      return response;
    } catch (error) {
      if (!authDiagnosticsEnabled) rethrow;
      final reason = error is TimeoutException ? 'network_timeout' : 'network_request_failed';
      logAuthEvent(stage, 'failed; reason=$reason');
      throw AuthDiagnosticException(stage: stage, reason: reason);
    }
  }

  Future<AuthUser> _fetchAuthUserWithDiagnostics(String token) async {
    logAuthEvent(.account, 'start; signing=$authSecretConfiguration; authorization=present');
    try {
      final response = await _client.get(
        lichessUri('/api/account'),
        headers: {'Authorization': 'Bearer ${signBearerToken(token)}'},
      );
      logAuthResponse(.account, response);
      if (response.statusCode != 200) {
        throw AuthDiagnosticException(
          stage: .account,
          reason: response.statusCode == 401 ? 'authorization_rejected' : 'http_error',
          statusCode: response.statusCode,
          retryAfter: authRetryAfter(response.headers['retry-after'], now: DateTime.now()),
        );
      }
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map<String, dynamic>) {
        throw const AuthDiagnosticException(stage: .account, reason: 'invalid_account_response');
      }
      final user = User.fromServerJson(json);
      logAuthEvent(.account, 'account=decoded; next=session_storage');
      return AuthUser(token: token, user: user.lightUser);
    } on AuthDiagnosticException {
      rethrow;
    } on FormatException {
      logAuthEvent(.account, 'failed; reason=invalid_account_response');
      throw const AuthDiagnosticException(stage: .account, reason: 'invalid_account_response');
    } catch (_) {
      logAuthEvent(.account, 'failed; reason=network_or_account_decode_error');
      throw const AuthDiagnosticException(
        stage: .account,
        reason: 'network_or_account_decode_error',
      );
    }
  }

  /// Sign out the current user by revoking the auth token.
  Future<void> signOut() async {
    await _client.deleteRead(Uri(path: '/api/token'));
  }

  /// Revokes the token of [authUser], which need not be the active session.
  Future<void> revokeToken(AuthUser authUser) async {
    // The default client is used on purpose: a 401 response from [lichessClientProvider] would be
    // taken for a 401 of the active session.
    final url = lichessUri('/api/token');
    final response = await _ref
        .read(defaultClientProvider)
        .delete(url, headers: {'Authorization': 'Bearer ${signBearerToken(authUser.token)}'});
    if (response.statusCode >= 400 && response.statusCode != 401) {
      throw ServerException(
        response.statusCode,
        'Could not revoke the token: ${response.statusCode}',
        url,
        null,
      );
    }
  }

  /// Check if the given authUser token is valid.
  Future<bool> checkToken(AuthUser authUser) async {
    final defaultClient = _ref.read(defaultClientProvider);
    final data = await defaultClient
        .postReadJson(lichessUri('/api/token/test'), mapper: (json) => json, body: authUser.token)
        .timeout(const Duration(seconds: 5));
    return data[authUser.token] != null;
  }
}
