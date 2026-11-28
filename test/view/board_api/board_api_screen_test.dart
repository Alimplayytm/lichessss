import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/auth/auth_user.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/user/user.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:lichess_mobile/src/view/board_api/board_api_screen.dart';
import 'package:lichess_mobile/src/widgets/board.dart';
import 'package:material_ui/material_ui.dart';

import '../../model/board_api/board_api_test.dart' show full;
import '../../network/fake_http_client_factory.dart';
import '../../test_provider_scope.dart';

const _user = AuthUser(
  user: LightUser(id: UserId('test'), name: 'Test'),
  token: 'synthetic_public_token',
  isPublicOAuth: true,
);

void main() {
  testWidgets('lobby becomes ready on HTTP connection even with only blank keepalives', (
    tester,
  ) async {
    final events = StreamController<List<int>>();
    addTearDown(() => unawaited(events.close()));
    final requests = <String>[];
    final app = await makeTestProviderScopeApp(
      tester,
      authUser: _user,
      home: const BoardApiScreen(),
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient.streaming((request, _) async {
              requests.add(request.url.path);
              expect(request.headers['Authorization'], 'Bearer ${_user.token}');
              if (request.url.path == '/api/stream/event') {
                return http.StreamedResponse(events.stream, 200);
              }
              return http.StreamedResponse(Stream.value(utf8.encode('{"nowPlaying":[]}')), 200);
            }),
          ),
        ),
      },
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    events.add(utf8.encode('\n'));
    await tester.pump();
    expect(find.text('Event stream connected'), findsOneWidget);
    final findButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Find opponent'),
    );
    expect(findButton.onPressed, isNotNull);
    expect(requests, containsAll(['/api/stream/event', '/api/account/playing']));
    expect(requests.any((path) => path.startsWith('/api/mobile/')), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('permission failure does not reconnect in a loop or enable matchmaking', (
    tester,
  ) async {
    var eventRequests = 0;
    final app = await makeTestProviderScopeApp(
      tester,
      authUser: _user,
      home: const BoardApiScreen(),
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient((request) async {
              if (request.url.path == '/api/stream/event') {
                eventRequests++;
                return http.Response('{"error":"private server response"}', 403);
              }
              return http.Response('{"nowPlaying":[]}', 200);
            }),
          ),
        ),
      },
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    expect(eventRequests, 1);
    expect(find.textContaining('board:play'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Find opponent')).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('game uses Board API state and disables input when the server ends the game', (
    tester,
  ) async {
    final stream = StreamController<List<int>>();
    addTearDown(() => unawaited(stream.close()));
    final app = await makeTestProviderScopeApp(
      tester,
      authUser: _user,
      home: const BoardApiGameScreen(gameId: 'abcdefgh'),
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(
            () => MockClient.streaming((request, _) async {
              if (request.method == 'POST') {
                expect(request.url.path, '/api/board/game/abcdefgh/move/e2e4');
                return http.StreamedResponse(Stream.value(utf8.encode('{"ok":true}')), 200);
              }
              expect(request.url.path, '/api/board/game/stream/abcdefgh');
              return http.StreamedResponse(stream.stream, 200);
            }),
          ),
        ),
      },
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    stream.add(utf8.encode('${jsonEncode(full().unlock)}\n'));
    await tester.pumpAndSettle();
    final board = tester.widget<BoardWidget>(find.byType(BoardWidget));
    expect(board.controller.interactive, isTrue);
    expect(board.enableChessHelper, isFalse);
    board.onMove!(Move.parse('e2e4')!);
    await tester.pumpAndSettle();
    expect(tester.widget<BoardWidget>(find.byType(BoardWidget)).controller.interactive, isFalse);
    stream.add(
      utf8.encode(
        '{"type":"gameState","moves":"e2e4","status":"draw","wtime":300000,"btime":300000}\n',
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<BoardWidget>(find.byType(BoardWidget)).controller.interactive, isFalse);
    expect(find.text('draw'), findsOneWidget);
    expect(find.text('Resign'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
