import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/auth/auth_storage.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:lichess_mobile/src/view/auth/personal_token_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../network/fake_http_client_factory.dart';
import '../../test_provider_scope.dart';

void main() {
  testWidgets('successful token login stores the mode and closes the sign-in screen', (
    tester,
  ) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(PersonalTokenScreen.buildRoute()),
            child: const Text('Open token sign-in'),
          ),
        ),
      ),
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient(
              (_) async => http.Response(
                '{"id":"test","username":"test","createdAt":1290415680000,'
                '"seenAt":1290415680000,"perfs":{}}',
                200,
              ),
            ),
          ),
        ),
      },
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open token sign-in'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'test_personal_credential');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(PersonalTokenScreen), findsNothing);
    expect((await const AuthStorage().read())?.isPersonalToken, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('token field is obscured and empty input never reaches the network', (tester) async {
    var accountRequests = 0;
    final app = await makeTestProviderScopeApp(
      tester,
      home: const PersonalTokenScreen(),
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient((request) async {
              if (request.url.path == '/api/account') accountRequests++;
              return http.Response('', 200);
            }),
          ),
        ),
      },
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(find.byType(EditableText)).obscureText, isTrue);
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(accountRequests, 0);
    expect(find.text('Paste only the token, without a Bearer prefix or spaces.'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('rejected token leaves the form open with a safe actionable message', (tester) async {
    var accountRequests = 0;
    final app = await makeTestProviderScopeApp(
      tester,
      home: const PersonalTokenScreen(),
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient((request) async {
              if (request.url.path == '/api/account') {
                accountRequests++;
                expect(request.headers['Authorization'], 'Bearer test_personal_credential');
                return http.Response('{"error":"test_personal_credential"}', 401);
              }
              return http.Response('', 200);
            }),
          ),
        ),
      },
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'test_personal_credential');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(accountRequests, 1);
    expect(find.byType(PersonalTokenScreen), findsOneWidget);
    expect(
      find.text(
        'Personal token not accepted (401). Check that it is correct and has not been revoked.',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'test_personal_credential',
      ),
      findsNothing,
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
