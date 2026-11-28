import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/auth/auth_diagnostics.dart';
import 'package:lichess_mobile/src/model/auth/auth_repository.dart';
import 'package:lichess_mobile/src/model/auth/auth_storage.dart';
import 'package:lichess_mobile/src/model/auth/bearer.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/user/user.dart';
import 'package:lichess_mobile/src/network/aggregator.dart';
import 'package:lichess_mobile/src/network/http.dart';

import '../../network/fake_http_client_factory.dart';
import '../../test_container.dart';
import 'auth_repository_test.dart' show emailLoginContainer;

const _account =
    '{"id":"test","username":"test","createdAt":1290415680000,'
    '"seenAt":1290415680000,"perfs":{}}';
const _personal = AuthUser(
  user: LightUser(id: UserId('test'), name: 'test'),
  token: 'test_personal_credential',
  isPersonalToken: true,
);

void main() {
  test('public OAuth credential mode survives storage without changing legacy sessions', () {
    final user = _personal.copyWith(isPersonalToken: false, isPublicOAuth: true);
    final restored = AuthUser.fromJson(
      jsonDecode(jsonEncode(user.toJson())) as Map<String, dynamic>,
    );
    expect(restored.isPublicOAuth, isTrue);
    expect(restored.isPersonalToken, isFalse);
    expect(restored.usesPublicApi, isTrue);
    expect(authBearer(restored), user.token);
  });

  test('public sessions never aggregate requests into private mobile endpoints', () async {
    final paths = <String>[];
    final container = await makeContainer(
      authUser: _personal,
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient((request) async {
              paths.add(request.url.path);
              return http.Response('{}', 200);
            }),
          ),
        ),
      },
    );
    final aggregator = container.read(aggregatorProvider);
    await Future.wait([
      for (final path in [
        '/api/account',
        '/api/account/playing',
        '/api/challenge',
        '/tournament/featured',
        '/api/streamer/live',
      ])
        aggregator.readJson(Uri(path: path), atomicMapper: (json) => json),
    ]);
    expect(paths.length, 5);
    expect(paths.any((path) => path.startsWith('/api/mobile/')), isFalse);
  });

  test('personal token mode survives serialization; legacy sessions remain signed', () {
    final serialized = jsonDecode(jsonEncode(_personal.toJson())) as Map<String, dynamic>;
    expect(AuthUser.fromJson(serialized), _personal);
    final legacy = Map<String, dynamic>.of(serialized)..remove('isPersonalToken');
    expect(AuthUser.fromJson(legacy).isPersonalToken, isFalse);
    expect(authBearer(_personal), _personal.token);
    expect(
      authBearer(_personal.copyWith(isPersonalToken: false)),
      signBearerToken(_personal.token),
    );
    expect(_personal.toString(), isNot(contains(_personal.token)));
  });

  test(
    'token login uses HTTPS account API, unsigned bearer and a distinct client identity',
    () async {
      final container = await emailLoginContainer((request) async {
        expect(request.url.scheme, 'https');
        expect(
          request.url.host,
          'lichess.dev',
        ); // Test build's configured host, not a real request.
        expect(request.url.path, '/api/account');
        expect(request.url.hasQuery, isFalse);
        expect(request.method, 'GET');
        expect(request.body, isEmpty);
        expect(request.headers['Authorization'], 'Bearer ${_personal.token}');
        expect(request.headers['User-Agent'], startsWith('Lichessss/'));
        expect(request.headers['Cache-Control'], 'no-store');
        return http.Response(_account, 200);
      });
      final user = await container
          .read(authRepositoryProvider)
          .signInWithPersonalToken('  ${_personal.token}\n');
      expect(user.isPersonalToken, isTrue);
      expect(user.token, _personal.token);
      expect(user.user.name, 'test');
    },
  );

  test('future-length tokens and nonstandard prefixes are not truncated or rejected', () async {
    final token = 'unusual_${'x' * 600}';
    final container = await emailLoginContainer((request) async {
      expect(request.headers['Authorization'], 'Bearer $token');
      return http.Response(_account, 200);
    });
    expect(
      (await container.read(authRepositoryProvider).signInWithPersonalToken(token)).token,
      token,
    );
  });

  test('bad input is rejected before a network request', () async {
    final container = await emailLoginContainer((_) async => fail('No request expected'));
    for (final token in ['', 'Bearer test_token', 'token\nwith_spaces', 'token:signature']) {
      await expectLater(
        container.read(authRepositoryProvider).signInWithPersonalToken(token),
        throwsA(
          isA<AuthDiagnosticException>().having(
            (error) => error.reason,
            'reason',
            'invalid_format',
          ),
        ),
      );
    }
  });

  test('401 and 429 do not retry or expose raw response data', () async {
    for (final status in [401, 429]) {
      var requests = 0;
      final container = await emailLoginContainer((_) async {
        requests++;
        return http.Response(
          '{"error":"${_personal.token}"}',
          status,
          headers: {'retry-after': '90'},
        );
      });
      await expectLater(
        container.read(authRepositoryProvider).signInWithPersonalToken(_personal.token),
        throwsA(
          isA<AuthDiagnosticException>()
              .having((error) => error.statusCode, 'status', status)
              .having((error) => error.toString(), 'redacted', isNot(contains(_personal.token))),
        ),
      );
      expect(requests, 1);
    }
  });

  test('account requests remain unsigned after the personal session is restored', () async {
    final container = await makeContainer(
      authUser: _personal,
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient((request) async {
              expect(request.headers['Authorization'], 'Bearer ${_personal.token}');
              expect(request.headers['User-Agent'], startsWith('Lichessss/'));
              return http.Response(_account, 200);
            }),
          ),
        ),
      },
    );
    await container.read(lichessClientProvider).get(lichessUri('/api/account'));
  });

  test('successful token sign-in persists the credential mode in secure storage', () async {
    final container = await emailLoginContainer((_) async => http.Response(_account, 200));
    final subscription = container.listen(authControllerProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(authControllerProvider.notifier).signInWithPersonalToken(_personal.token);
    expect(container.read(authControllerProvider)?.isPersonalToken, isTrue);
    final stored = await const AuthStorage().read();
    expect(stored?.token, _personal.token);
    expect(stored?.isPersonalToken, isTrue);
  });

  test('forgetting an imported token does not revoke it on the server', () async {
    final container = await makeContainer(
      authUser: _personal,
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient((_) async => fail('Must not revoke an imported token')),
          ),
        ),
      },
    );
    await container.read(authRepositoryProvider).signOut();
    await container.read(authRepositoryProvider).revokeToken(_personal);
  });
}
