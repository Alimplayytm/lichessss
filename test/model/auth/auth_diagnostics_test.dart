import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/auth/auth_diagnostics.dart';
import 'package:lichess_mobile/src/model/auth/auth_repository.dart';
import 'package:lichess_mobile/src/model/auth/bearer.dart';
import 'package:logging/logging.dart';

import 'auth_repository_test.dart'
    show FakeFlutterAppAuth, appAuthContainer, emailLoginContainer, tokenResponse;

void main() {
  final now = DateTime.utc(2026, 11, 27, 20);

  test('Retry-After accepts seconds and an HTTP date, not arbitrary header text', () {
    expect(authRetryAfter('120', now: now), const Duration(minutes: 2));
    expect(
      authRetryAfter(HttpDate.format(now.add(const Duration(seconds: 75))), now: now),
      const Duration(seconds: 75),
    );
    expect(
      authRetryAfter(HttpDate.format(now.subtract(const Duration(seconds: 1))), now: now),
      Duration.zero,
    );
    for (final header in [null, '-1', 'secret-user-input', '999999999999999999999']) {
      expect(authRetryAfter(header, now: now), isNull);
    }
  });

  test('only allowlisted server reasons are exposed', () {
    expect(safeAuthReason('invalid_token'), 'invalid_token');
    expect(safeAuthReason('Invalid bearer token'), 'invalid_token');
    expect(safeAuthReason('insufficient_scope'), 'insufficient_scope');
    expect(safeAuthReason('invalid_token: user-secret'), 'unrecognized');
    expect(safeAuthReason({'access_token': 'user-secret'}), 'unrecognized');
  });

  test('error summaries never contain raw JSON, credentials or challenge headers', () {
    final summary = authResponseSummary(
      http.Response(
        '{"error":"invalid_token","access_token":"secret-token",'
        '"email":"private@example.com","code":"123456","password":"secret-password"}',
        401,
        headers: {
          'www-authenticate': 'Bearer secret-challenge',
          'set-cookie': 'secret-cookie',
          'retry-after': '60',
        },
      ),
      now: now,
    );
    expect(summary, contains('http=401'));
    expect(summary, contains('reason=invalid_token'));
    expect(summary, contains('retryAfterSeconds=60'));
    for (final secret in [
      'secret-token',
      'private@example.com',
      '123456',
      'secret-password',
      'secret-challenge',
      'secret-cookie',
    ]) {
      expect(summary, isNot(contains(secret)));
    }
  });

  test('HTML, oversized and success bodies are not echoed or inspected', () {
    expect(
      authResponseSummary(http.Response('<html>private@example.com</html>', 401), now: now),
      contains('body=non-json'),
    );
    expect(
      authResponseSummary(http.Response('x' * 8193, 401), now: now),
      contains('body=oversize'),
    );
    final summary = authResponseSummary(http.Response('secret-token', 200), now: now);
    expect(summary, contains('body=not-inspected'));
    expect(summary, isNot(contains('secret-token')));
    expect(
      authResponseSummary(http.Response.bytes([0xFF, 0xFE], 401), now: now),
      contains('body=non-json'),
    );
  });

  test('unknown retry time does not invent a delay', () {
    const error = AuthDiagnosticException(stage: .account, reason: 'http_error', statusCode: 429);
    expect(error.userMessage, contains('did not give a retry time'));
    expect(
      const AuthDiagnosticException(
        stage: .account,
        reason: 'http_error',
        statusCode: 429,
        retryAfter: Duration(seconds: 90),
      ).userMessage,
      contains('90 seconds'),
    );
  });

  test('account rejection is not represented as proof of an invalid build secret', () {
    const error = AuthDiagnosticException(
      stage: .account,
      reason: 'authorization_rejected',
      statusCode: 401,
    );
    expect(error.userMessage, contains('token was received'));
    expect(error.userMessage, contains('401'));
    expect(error.userMessage, isNot(contains('invalid secret')));
    expect(
      authSecretConfiguration,
      isIn(['missing', 'development-placeholder', 'configured-unverified']),
    );
  });

  if (authDiagnosticsEnabled) {
    test(
      'browser token followed by account 401 records stages without leaking the token',
      () async {
        final messages = <String>[];
        final level = Logger.root.level;
        Logger.root.level = Level.ALL;
        final subscription = Logger.root.onRecord.listen((record) {
          if (record.loggerName == 'AuthDiagnostics') messages.add(record.message);
        });
        addTearDown(() async {
          await subscription.cancel();
          Logger.root.level = level;
        });
        var requests = 0;
        final container = await appAuthContainer(
          MockClient((request) async {
            requests++;
            expect(request.url.path, '/api/account');
            expect(request.headers['Authorization'], 'Bearer ${signBearerToken('secret-token')}');
            return http.Response('{"error":"invalid_token","echo":"secret-token"}', 401);
          }),
          FakeFlutterAppAuth((_) async => tokenResponse(accessToken: 'secret-token')),
        );
        await expectLater(
          container.read(authRepositoryProvider).signIn(),
          throwsA(
            isA<AuthDiagnosticException>()
                .having((error) => error.stage, 'stage', AuthStage.account)
                .having((error) => error.statusCode, 'status', 401),
          ),
        );
        expect(requests, 1);
        expect(messages.join('\n'), contains('token=received'));
        expect(messages.join('\n'), contains('stage=account'));
        expect(messages.join('\n'), contains('reason=invalid_token'));
        expect(messages.join('\n'), isNot(contains('secret-token')));
        expect(messages.join('\n'), isNot(contains(signBearerToken('secret-token'))));
      },
    );

    test('email rate limit preserves Retry-After and is not automatically retried', () async {
      var requests = 0;
      final container = await emailLoginContainer((request) async {
        requests++;
        return http.Response('', 429, headers: {'retry-after': '120'});
      });
      await expectLater(
        container
            .read(authRepositoryProvider)
            .signInWithEmailCode(
              username: 'private-user',
              email: 'private@example.com',
              code: '123456',
            ),
        throwsA(
          isA<EmailLoginRateLimitException>().having(
            (error) => error.retryAfter,
            'retry after',
            const Duration(minutes: 2),
          ),
        ),
      );
      expect(requests, 1);
    });

    test('missing OAuth token is identified before any account request', () async {
      final container = await appAuthContainer(
        MockClient((_) async => fail('Must not fetch an account without a token')),
        FakeFlutterAppAuth((_) async => tokenResponse(accessToken: null)),
      );
      await expectLater(
        container.read(authRepositoryProvider).signIn(),
        throwsA(
          isA<AuthDiagnosticException>()
              .having((error) => error.stage, 'stage', AuthStage.browser)
              .having((error) => error.reason, 'reason', 'missing_token'),
        ),
      );
    });

    test(
      'email network exceptions cannot echo submitted secrets into the diagnostic error',
      () async {
        final container = await emailLoginContainer((_) {
          throw http.ClientException('private@example.com code=123456');
        });
        await expectLater(
          container
              .read(authRepositoryProvider)
              .signInWithEmailCode(
                username: 'private-user',
                email: 'private@example.com',
                code: '123456',
              ),
          throwsA(
            isA<AuthDiagnosticException>()
                .having((error) => error.stage, 'stage', AuthStage.emailExchange)
                .having((error) => error.reason, 'reason', 'network_request_failed')
                .having(
                  (error) => error.toString(),
                  'no email',
                  isNot(contains('private@example.com')),
                )
                .having((error) => error.toString(), 'no code', isNot(contains('123456'))),
          ),
        );
      },
    );
  }
}
