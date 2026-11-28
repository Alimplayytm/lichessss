import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/board_api/board_api.dart';
import 'package:lichess_mobile/src/model/board_api/board_game.dart';

const _token = 'synthetic_board_token';

BoardApi apiWith(http.Client Function() createClient) {
  final api = BoardApi(createClient: createClient, token: _token, userAgent: 'TestPublicClient/1');
  addTearDown(api.close);
  return api;
}

Map<String, dynamic> state({String moves = '', String status = 'started'}) => {
  'type': 'gameState',
  'moves': moves,
  'status': status,
  'wtime': 300000,
  'btime': 300000,
};

IMap<String, dynamic> full({String moves = '', String status = 'started'}) => <String, dynamic>{
  'type': 'gameFull',
  'id': 'abcdefgh',
  'variant': {'key': 'standard'},
  'initialFen': 'startpos',
  'white': {'id': 'test', 'name': 'Test'},
  'black': {'id': 'opponent', 'name': 'Opponent'},
  'state': state(moves: moves, status: status),
}.lock;

class StreamClient(final Future<http.StreamedResponse> Function(http.BaseRequest) handler)
    extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('account events parse chunked NDJSON and skip blank keepalives', () async {
    var ready = false;
    final api = apiWith(
      () => StreamClient((request) async {
        expect(request.url.path, '/api/stream/event');
        expect(request.url.scheme, 'https');
        expect(request.headers['Authorization'], 'Bearer $_token');
        expect(request.headers['User-Agent'], 'TestPublicClient/1');
        expect(request.followRedirects, isFalse);
        return http.StreamedResponse(
          Stream.fromIterable([
            utf8.encode('\n{"type":"game'),
            utf8.encode('Start","game":{"id":"abcdefgh"}}\n\n'),
          ]),
          200,
        );
      }),
    );
    final events = await api.events(onConnected: () => ready = true).toList();
    expect(ready, isTrue);
    expect(events.single['type'], 'gameStart');
  });

  test('cancelling a seek closes only its own HTTP connection', () async {
    final clients = <StreamClient>[];
    final bodies = <StreamController<List<int>>>[];
    final requests = <http.BaseRequest>[];
    final api = apiWith(() {
      final body = StreamController<List<int>>();
      bodies.add(body);
      final client = StreamClient((request) async {
        requests.add(request);
        return http.StreamedResponse(body.stream, 200);
      });
      clients.add(client);
      return client;
    });
    final connected = Completer<void>();
    final events = api.events(onConnected: connected.complete).listen((_) {});
    await connected.future;
    final seek = api
        .seek(time: const Duration(minutes: 10), increment: const Duration(seconds: 5))
        .listen((_) {});
    // Both requests are scheduled before this next event-loop turn.
    await Future<void>.delayed(Duration.zero);
    expect(requests.last.url.path, '/api/board/seek');
    expect((requests.last as http.Request).bodyFields, {
      'time': '10.0',
      'increment': '5',
      'rated': 'false',
      'variant': 'standard',
    });
    await seek.cancel();
    expect(clients.last.closed, isTrue);
    expect(clients.first.closed, isFalse);
    await events.cancel();
    for (final body in bodies) {
      unawaited(body.close());
    }
  });

  test('move and actions use documented public endpoints with raw bearer', () async {
    final paths = <String>[];
    final api = apiWith(
      () => MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.headers['Authorization'], 'Bearer $_token');
        expect(request.url.query, isEmpty);
        paths.add(request.url.path);
        return http.Response('{"ok":true}', 200);
      }),
    );
    await api.move('abcdefgh', 'e2e4');
    await api.draw('abcdefgh', true);
    await api.resign('abcdefgh');
    await api.abort('abcdefgh');
    expect(paths, [
      '/api/board/game/abcdefgh/move/e2e4',
      '/api/board/game/abcdefgh/draw/true',
      '/api/board/game/abcdefgh/resign',
      '/api/board/game/abcdefgh/abort',
    ]);
  });

  test('invalid IDs and moves are rejected before sending credentials', () async {
    var sent = 0;
    final api = apiWith(
      () => MockClient((_) async {
        sent++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(api.move('../secret', 'e2e4'), throwsA(isA<BoardApiException>()));
    await expectLater(api.move('abcdefgh', '../secret'), throwsA(isA<BoardApiException>()));
    expect(sent, 0);
  });

  test('403 and 429 are redacted and never automatically retried', () async {
    for (final status in [401, 403, 429]) {
      var calls = 0;
      final api = apiWith(
        () => MockClient((_) async {
          calls++;
          return http.Response('{"error":"$_token"}', status);
        }),
      );
      await expectLater(
        api.ongoing(),
        throwsA(
          isA<BoardApiException>()
              .having((error) => error.statusCode, 'status', status)
              .having((error) => error.toString(), 'safe error', isNot(contains(_token))),
        ),
      );
      expect(calls, 1);
    }
  });

  test('stream errors never expose server bodies or underlying credentials', () async {
    final api = apiWith(() => StreamClient((_) async => throw Exception(_token)));
    await expectLater(
      api.events(),
      emitsError(
        isA<BoardApiException>().having(
          (error) => error.toString(),
          'safe error',
          isNot(contains(_token)),
        ),
      ),
    );
  });

  test('ongoing games use the public account endpoint', () async {
    final api = apiWith(
      () => MockClient((request) async {
        expect(request.url.path, '/api/account/playing');
        return http.Response('{"nowPlaying":[{"gameId":"abcdefgh"}]}', 200);
      }),
    );
    expect((await api.ongoing()).single['gameId'], 'abcdefgh');
  });

  test('correspondence seek uses days rather than clock fields', () async {
    final api = apiWith(
      () => MockClient((request) async {
        expect(request.url.path, '/api/board/seek');
        expect(request.bodyFields, {'days': '2', 'rated': 'false'});
        return http.Response('{"id":"seek"}', 200);
      }),
    );
    await api.seekCorrespondence(2);
  });

  test('direct Blitz challenges use public challenge endpoints and seconds', () async {
    final paths = <String>[];
    final api = apiWith(
      () => MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/api/challenge/opponent') {
          expect(request.bodyFields, {
            'clock.limit': '180',
            'clock.increment': '2',
            'rated': 'false',
            'variant': 'standard',
          });
          return http.Response('{"challenge":{"id":"abcdefgh"}}', 200);
        }
        return http.Response('{"ok":true}', 200);
      }),
    );
    final id = await api.challenge(
      'opponent',
      time: const Duration(minutes: 3),
      increment: const Duration(seconds: 2),
    );
    expect(id, 'abcdefgh');
    await api.acceptChallenge(id);
    await api.declineChallenge(id);
    await api.cancelChallenge(id);
    expect(paths, [
      '/api/challenge/opponent',
      '/api/challenge/abcdefgh/accept',
      '/api/challenge/abcdefgh/decline',
      '/api/challenge/abcdefgh/cancel',
    ]);
  });

  test('game snapshots reconstruct moves and recover after takebacks', () {
    final game = BoardGame.fromFull(full(moves: 'e2e4 e7e5'), 'test');
    expect(game.side, Side.white);
    expect(
      game.position.fen,
      Chess.initial.play(Move.parse('e2e4')!).play(Move.parse('e7e5')!).fen,
    );
    final rolledBack = game.update(state(moves: 'e2e4').lock);
    expect(rolledBack.position.turn, Side.black);
    expect(rolledBack.lastMove?.uci, 'e2e4');
    final reconnected = BoardGame.fromFull(full(moves: 'e2e4 e7e5 g1f3'), 'test');
    expect(reconnected.position.ply, 3);
  });

  test('spectator credentials cannot drive a player board', () {
    expect(() => BoardGame.fromFull(full(), 'someoneElse'), throwsA(isA<BoardApiException>()));
  });

  test('finished game and draw offers follow server state', () {
    final game = BoardGame.fromFull(full(), 'test');
    expect(game.playing, isTrue);
    final update = state(status: 'draw')..['bdraw'] = true;
    final finished = game.update(update.lock);
    expect(finished.playing, isFalse);
    expect(finished.opponentDraw, isTrue);
  });

  test('malformed server move lists do not produce a playable local position', () {
    expect(
      () => BoardGame.fromFull(full(moves: 'e2e5'), 'test'),
      throwsA(isA<BoardApiException>()),
    );
  });
}
