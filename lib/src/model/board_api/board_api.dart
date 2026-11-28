import 'dart:async';
import 'dart:convert';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/auth/bearer.dart';
import 'package:lichess_mobile/src/model/common/preloaded_data.dart';
import 'package:lichess_mobile/src/network/http.dart';

final boardApiProvider = Provider.autoDispose<BoardApi>((ref) {
  final session = ref.watch(authControllerProvider);
  if (session == null || !session.usesPublicApi) {
    throw const BoardApiException('Sign in using the public OAuth flow first.');
  }
  final api = BoardApi(
    createClient: () => ref.read(httpClientFactoryProvider)(),
    token: session.token,
    userAgent: personalTokenUserAgent(
      ref.read(preloadedDataProvider).requireValue.packageInfo.version,
    ),
  );
  ref.onDispose(api.close);
  return api;
}, name: 'BoardApiProvider');

class const BoardApiException(final String message, {final int? statusCode}) implements Exception {
  @override
  String toString() => message;
}

/// A public API transport. Each stream owns its connection so cancelling a seek actually
/// cancels it on the server, without interrupting the account event stream.
class BoardApi({
  required final http.Client Function() createClient,
  required final String token,
  required final String userAgent,
}) {
  final Set<http.Client> _clients = {};
  bool _closed = false;

  http.Client _newClient() {
    if (_closed) throw const BoardApiException('Connection closed.');
    final client = createClient();
    _clients.add(client);
    return client;
  }

  http.Request _request(String method, String path, [Map<String, String>? body]) {
    final uri = lichessUri(path);
    if (uri.scheme != 'https') {
      throw const BoardApiException('The public API requires HTTPS.');
    }
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'User-Agent': userAgent,
        'Accept': 'application/x-ndjson, application/json',
        'Cache-Control': 'no-store',
      });
    if (body != null) request.bodyFields = body;
    return request;
  }

  void _checkStatus(int status) {
    if (status >= 200 && status < 300) return;
    throw BoardApiException(switch (status) {
      401 => 'Session expired. Please sign in again.',
      403 => 'Board API permission is required. Sign in again and grant board:play.',
      429 => 'Too many requests. Wait at least one minute before retrying.',
      _ => 'Public API request failed (HTTP $status).',
    }, statusCode: status);
  }

  Stream<IMap<String, dynamic>> events({void Function()? onConnected}) =>
      _stream('GET', '/api/stream/event', null, onConnected);

  Stream<IMap<String, dynamic>> game(String id) =>
      _stream('GET', '/api/board/game/stream/${_id(id)}');

  /// A real-time seek emits only keepalive lines. Game starts arrive on [events].
  Stream<IMap<String, dynamic>> seek({
    required Duration time,
    required Duration increment,
    bool rated = false,
  }) {
    return _stream('POST', '/api/board/seek', {
      'time': (time.inSeconds / 60).toString(),
      'increment': increment.inSeconds.toString(),
      'rated': rated.toString(),
      'variant': 'standard',
    });
  }

  Stream<IMap<String, dynamic>> _stream(
    String method,
    String path, [
    Map<String, String>? body,
    void Function()? onConnected,
  ]) {
    http.Client? client;
    bool cancelled = false;
    late final StreamController<IMap<String, dynamic>> controller;
    Future<void> run() async {
      try {
        final connection = _newClient();
        client = connection;
        final response = await connection
            .send(_request(method, path, body))
            .timeout(const Duration(seconds: 15));
        _checkStatus(response.statusCode);
        if (!cancelled && !_closed) onConnected?.call();
        await for (final line
            in response.stream
                .timeout(const Duration(seconds: 45))
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (cancelled) break;
          if (line.trim().isEmpty) continue;
          final json = jsonDecode(line);
          if (json is! Map<String, dynamic>) {
            throw const FormatException('Expected an event object.');
          }
          controller.add(json.lock);
        }
      } catch (error) {
        if (!cancelled && !_closed) {
          controller.addError(
            error is BoardApiException
                ? error
                : const BoardApiException('Public API connection interrupted.'),
          );
        }
      } finally {
        client?.close();
        _clients.remove(client);
        if (!controller.isClosed) unawaited(controller.close());
      }
    }

    controller = StreamController<IMap<String, dynamic>>(
      onListen: () => unawaited(run()),
      onCancel: () {
        cancelled = true;
        client?.close();
        _clients.remove(client);
      },
    );
    return controller.stream;
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, [
    Map<String, String>? body,
  ]) async {
    final client = _newClient();
    try {
      final response = await http.Response.fromStream(
        await client.send(_request(method, path, body)).timeout(const Duration(seconds: 15)),
      ).timeout(const Duration(seconds: 15));
      _checkStatus(response.statusCode);
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on BoardApiException {
      rethrow;
    } catch (_) {
      throw const BoardApiException('Public API request interrupted.');
    } finally {
      client.close();
      _clients.remove(client);
    }
  }

  Future<IList<IMap<String, dynamic>>> ongoing() async {
    final json = await _json('GET', '/api/account/playing');
    return (json['nowPlaying'] as List<dynamic>)
        .map((game) => (game as Map<String, dynamic>).lock)
        .toIList();
  }

  Future<void> move(String id, String uci) async {
    if (!RegExp(r'^([a-h][1-8][a-h][1-8][qrbn]?|[PNBRQK]@[a-h][1-8])$').hasMatch(uci)) {
      throw const BoardApiException('Invalid move.');
    }
    await _json('POST', '/api/board/game/${_id(id)}/move/$uci');
  }

  Future<void> resign(String id) async {
    await _json('POST', '/api/board/game/${_id(id)}/resign');
  }

  Future<void> abort(String id) async {
    await _json('POST', '/api/board/game/${_id(id)}/abort');
  }

  Future<void> draw(String id, bool accept) async {
    await _json('POST', '/api/board/game/${_id(id)}/draw/$accept');
  }

  Future<void> seekCorrespondence(int days) async {
    await _json('POST', '/api/board/seek', {'days': days.toString(), 'rated': 'false'});
  }

  Future<String> challenge(
    String username, {
    required Duration time,
    required Duration increment,
    bool rated = false,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{2,30}$').hasMatch(username)) {
      throw const BoardApiException('Enter a valid Lichess username.');
    }
    final result = await _json('POST', '/api/challenge/$username', {
      'clock.limit': time.inSeconds.toString(),
      'clock.increment': increment.inSeconds.toString(),
      'rated': rated.toString(),
      'variant': 'standard',
    });
    return (result['challenge'] as Map<String, dynamic>)['id'] as String;
  }

  Future<void> acceptChallenge(String id) async {
    await _json('POST', '/api/challenge/${_id(id)}/accept');
  }

  Future<void> declineChallenge(String id) async {
    await _json('POST', '/api/challenge/${_id(id)}/decline');
  }

  Future<void> cancelChallenge(String id) async {
    await _json('POST', '/api/challenge/${_id(id)}/cancel');
  }

  static String _id(String value) {
    if (!RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(value)) {
      throw const BoardApiException('Invalid game ID.');
    }
    return value;
  }

  void close() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
  }
}
