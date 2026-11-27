import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:lichess_mobile/src/constants.dart';
import 'package:logging/logging.dart';

/// Opt-in for the diagnostic iOS build. Other builds keep the original sign-in behavior.
const authDiagnosticsEnabled = bool.fromEnvironment('AUTH_DIAGNOSTICS');
final _logger = Logger('AuthDiagnostics');

enum AuthStage() {
  browser,
  personalToken,
  emailRequest,
  emailExchange,
  account,
  sessionStorage,
}

String get authSecretConfiguration => switch (kLichessWSSecret) {
  '' => 'missing',
  'somethingElseInProd' => 'development-placeholder',
  _ => 'configured-unverified',
};

/// Only predefined categories can leave this function; never echo server-supplied text.
String safeAuthReason(Object? value) => switch (value) {
  'invalid_token' || 'Invalid token' || 'Invalid bearer token' => 'invalid_token',
  'invalid_client' => 'invalid_client',
  'invalid_grant' => 'invalid_grant',
  'invalid_scope' || 'insufficient_scope' => 'insufficient_scope',
  'access_denied' => 'access_denied',
  'unauthorized_client' => 'unauthorized_client',
  'invalid_request' => 'invalid_request',
  'Invalid signature' || 'Invalid bearer token signature' => 'invalid_signature',
  'Missing authorization' || 'Missing bearer token' => 'missing_authorization',
  'temporarily_unavailable' => 'temporarily_unavailable',
  'server_error' => 'server_error',
  _ => 'unrecognized',
};

Duration? authRetryAfter(String? header, {required DateTime now}) {
  if (header == null) return null;
  final seconds = int.tryParse(header.trim());
  if (seconds != null) {
    return seconds >= 0 && seconds <= 31536000 ? Duration(seconds: seconds) : null;
  }
  try {
    final milliseconds = HttpDate.parse(header).difference(now.toUtc()).inMilliseconds;
    return Duration(seconds: milliseconds <= 0 ? 0 : (milliseconds + 999) ~/ 1000);
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

/// Deliberately excludes raw bodies, challenge headers, URLs, identifiers and credentials.
String authResponseSummary(http.Response response, {required DateTime now}) {
  var bodyKind = 'not-inspected';
  var reason = 'unrecognized';
  if (response.statusCode >= 400) {
    if (response.bodyBytes.isEmpty) {
      bodyKind = 'empty';
    } else if (response.bodyBytes.length > 8192) {
      bodyKind = 'oversize';
    } else {
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      try {
        final body = jsonDecode(text);
        bodyKind = 'json';
        if (body is Map<String, dynamic>) {
          reason = safeAuthReason(body['error']);
        } else {
          reason = safeAuthReason(body);
        }
      } on FormatException {
        bodyKind = 'non-json';
        reason = safeAuthReason(text.trim());
      }
    }
  }
  final retryAfter = authRetryAfter(response.headers['retry-after'], now: now);
  final challengeHeader = response.headers['www-authenticate'];
  final challenge = challengeHeader != null && challengeHeader.length <= 2048
      ? safeAuthReason(RegExp('error="([^"]+)"').firstMatch(challengeHeader)?.group(1))
      : 'unrecognized';
  return 'http=${response.statusCode}; body=$bodyKind; reason=$reason; '
      'challenge=$challenge; '
      'retryAfterSeconds=${retryAfter?.inSeconds ?? 'unknown'}';
}

void logAuthEvent(AuthStage stage, String event) {
  if (authDiagnosticsEnabled) {
    // The app log defaults to WARNING. Opt-in diagnostics must survive that filter.
    _logger.warning('v1 stage=${stage.name}; $event');
  }
}

void logAuthResponse(AuthStage stage, http.Response response) {
  if (authDiagnosticsEnabled) {
    final message = 'v1 stage=${stage.name}; ${authResponseSummary(response, now: DateTime.now())}';
    _logger.warning(message);
  }
}

/// Safe to display or log: contains only app-defined stages/reasons and an HTTP status.
class const AuthDiagnosticException({
  required final AuthStage stage,
  required final String reason,
  final int? statusCode,
  final Duration? retryAfter,
}) implements Exception {
  String get userMessage {
    if (stage == .personalToken && reason == 'invalid_format') {
      return 'Paste only the personal API token, without a Bearer prefix or spaces.';
    }
    if (stage == .personalToken && statusCode == 401) {
      return 'Personal token not accepted (401). Check that it is correct and has not been revoked.';
    }
    if (stage == .personalToken && statusCode == 403) {
      return 'This token does not permit the requested API operation (403).';
    }
    if (statusCode == 429) {
      return retryAfter == null
          ? 'Too many sign-in attempts (429). Wait before trying again; the server did not give a retry time.'
          : 'Too many sign-in attempts (429). Retry in ${retryAfter!.inSeconds} seconds.';
    }
    if (stage == .account && statusCode == 401) {
      return 'A token was received, but the account request was rejected (401). '
          'See AuthDiagnostics in the network log.';
    }
    return 'Sign-in failed at ${stage.name} ($reason${statusCode == null ? '' : ', HTTP $statusCode'}). '
        'See AuthDiagnostics in the network log.';
  }

  @override
  String toString() =>
      'AuthDiagnosticException(stage=${stage.name}, reason=$reason, '
      'http=$statusCode, retryAfterSeconds=${retryAfter?.inSeconds})';
}
