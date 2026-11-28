import 'dart:async';
import 'dart:math' as math;

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/board_api/board_api.dart';
import 'package:lichess_mobile/src/model/board_api/board_game.dart';
import 'package:lichess_mobile/src/model/settings/board_preferences.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/widgets/board.dart';
import 'package:lichess_mobile/src/widgets/feedback.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

/// Independent public-API lobby; native and anonymous game screens remain unchanged.
class const BoardApiScreen({super.key}) extends ConsumerStatefulWidget {
  static Route<void> buildRoute() => buildScreenRoute(screen: const BoardApiScreen());

  @override
  ConsumerState<BoardApiScreen> createState() => _BoardApiScreenState();
}

class _BoardApiScreenState() extends ConsumerState<BoardApiScreen> with WidgetsBindingObserver {
  StreamSubscription<IMap<String, dynamic>>? _events;
  StreamSubscription<IMap<String, dynamic>>? _seek;
  Timer? _reconnect;
  IList<IMap<String, dynamic>> _ongoing = const IListConst([]);
  IMap<String, String> _challenges = const IMapConst({});
  final _username = TextEditingController();
  String? _challengeId;
  bool _connected = false;
  bool _searching = false;
  bool _busy = false;
  bool _openingGame = false;
  String? _error;
  int _minutes = 10;
  bool _rated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect();
    unawaited(_refresh());
  }

  void _connect() {
    _events = ref
        .read(boardApiProvider)
        .events(
          onConnected: () {
            if (mounted) {
              setState(() {
                _connected = true;
                _error = null;
              });
            }
          },
        )
        .listen(
          (event) {
            if (!mounted) return;
            setState(() {
              _connected = true;
              _error = null;
            });
            if (event['type'] == 'gameStart') {
              final game = event['game'] as Map<String, dynamic>;
              _challengeId = null;
              unawaited(_open(game['id'] as String));
            } else if (event['type'] == 'challenge') {
              final challenge = event['challenge'] as Map<String, dynamic>;
              final challenger = challenge['challenger'] as Map<String, dynamic>;
              if (challenger['id'] != ref.read(authControllerProvider)?.user.id.value) {
                setState(() {
                  _challenges = _challenges.add(
                    challenge['id'] as String,
                    challenger['name'] as String,
                  );
                });
              }
            } else if (event['type'] == 'challengeCanceled' ||
                event['type'] == 'challengeDeclined') {
              final challenge = event['challenge'] as Map<String, dynamic>;
              final id = challenge['id'] as String;
              setState(() {
                _challenges = _challenges.remove(id);
                if (_challengeId == id) _challengeId = null;
              });
            }
          },
          onError: (Object error) => _lost(error),
          onDone: () => _lost(null),
          cancelOnError: true,
        );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == .paused || state == .inactive) {
      unawaited(_seek?.cancel());
      _seek = null;
      if (mounted) setState(() => _searching = false);
    } else if (state == .resumed) {
      unawaited(_refresh());
    }
  }

  void _lost(Object? error) {
    if (!mounted || _reconnect != null) return;
    setState(() {
      _connected = false;
      _searching = false;
      _error = error?.toString() ?? 'Event stream closed. Reconnecting…';
    });
    unawaited(_seek?.cancel());
    _seek = null;
    final status = error is BoardApiException ? error.statusCode : null;
    if (status == 401 || status == 403) return;
    _reconnect = Timer(Duration(seconds: status == 429 ? 60 : 3), () {
      _reconnect = null;
      unawaited(_events?.cancel());
      _connect();
    });
  }

  Future<void> _refresh() async {
    try {
      final games = await ref.read(boardApiProvider).ongoing();
      if (mounted) setState(() => _ongoing = games);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _open(String id) async {
    if (_openingGame) return;
    _openingGame = true;
    await _seek?.cancel();
    _seek = null;
    if (!mounted) return;
    setState(() => _searching = false);
    await Navigator.of(context).push(BoardApiGameScreen.buildRoute(id));
    _openingGame = false;
    if (mounted) await _refresh();
  }

  Future<void> _challengeAction(Future<void> Function(BoardApi) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(ref.read(boardApiProvider));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _search() {
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    _seek = ref
        .read(boardApiProvider)
        .seek(
          time: Duration(minutes: _minutes),
          increment: const Duration(seconds: 5),
          rated: _rated,
        )
        .listen(
          (_) {},
          onError: (Object error) {
            if (mounted) {
              setState(() {
                _searching = false;
                _error = error.toString();
              });
            }
          },
          onDone: () {
            if (mounted) setState(() => _searching = false);
            unawaited(_refresh());
          },
          cancelOnError: true,
        );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnect?.cancel();
    unawaited(_seek?.cancel());
    unawaited(_events?.cancel());
    _username.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(boardApiProvider);
    final user = ref.watch(authControllerProvider);
    return PlatformScaffold(
      appBar: const PlatformAppBar(title: Text('Online · Board API')),
      body: ListView(
        padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
        children: [
          Text('Signed in as ${user?.user.name ?? ''}'),
          Text(_connected ? 'Event stream connected' : 'Connecting to public event stream…'),
          if (_error != null) Text(_error!),
          const SizedBox(height: 16),
          const Text('Random pairing: Standard, Rapid / Classical'),
          Wrap(
            spacing: 8,
            children: [
              for (final minutes in [10, 15, 30])
                ChoiceChip(
                  label: Text('$minutes+5'),
                  selected: _minutes == minutes,
                  onSelected: _searching ? null : (_) => setState(() => _minutes = minutes),
                ),
            ],
          ),
          SwitchListTile(
            title: const Text('Rated'),
            value: _rated,
            onChanged: _searching ? null : (value) => setState(() => _rated = value),
          ),
          FilledButton(
            onPressed: _connected && !_searching ? _search : null,
            child: Text(_searching ? 'Searching…' : 'Find opponent'),
          ),
          if (_searching)
            TextButton(
              onPressed: () async {
                await _seek?.cancel();
                _seek = null;
                if (mounted) setState(() => _searching = false);
              },
              child: const Text('Cancel search'),
            ),
          TextButton(
            onPressed: _busy || _searching
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      await ref.read(boardApiProvider).seekCorrespondence(2);
                      if (context.mounted) {
                        showSnackBar(context, 'Correspondence seek created: 2 days per move.');
                      }
                    } catch (error) {
                      if (mounted) setState(() => _error = error.toString());
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: const Text('Create correspondence seek · 2 days'),
          ),
          const SizedBox(height: 16),
          for (final entry in _challenges.entries)
            ListTile(
              title: Text('Challenge from ${entry.value}'),
              trailing: Wrap(
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _challengeAction((api) => api.acceptChallenge(entry.key)),
                    child: const Text('Accept'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _challengeAction((api) async {
                            await api.declineChallenge(entry.key);
                            if (mounted) {
                              setState(() => _challenges = _challenges.remove(entry.key));
                            }
                          }),
                    child: const Text('Decline'),
                  ),
                ],
              ),
            ),
          TextField(
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Challenge a Lichess username'),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final minutes in [3, 5, 10])
                TextButton(
                  onPressed: !_connected || _busy || _searching || _challengeId != null
                      ? null
                      : () => _challengeAction((api) async {
                          final id = await api.challenge(
                            _username.text.trim(),
                            time: Duration(minutes: minutes),
                            increment: const Duration(seconds: 2),
                          );
                          if (mounted && !_openingGame) setState(() => _challengeId = id);
                        }),
                  child: Text('Challenge $minutes+2'),
                ),
            ],
          ),
          if (_challengeId != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _challengeAction((api) async {
                      await api.cancelChallenge(_challengeId!);
                      if (mounted) setState(() => _challengeId = null);
                    }),
              child: const Text('Cancel pending challenge'),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Text('Ongoing games')),
              IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
            ],
          ),
          for (final game in _ongoing)
            ListTile(
              title: Text(
                (game['opponent'] as Map<String, dynamic>)['username'] as String? ?? 'Game',
              ),
              subtitle: Text('${game['speed']} · ${game['color']}'),
              onTap: () => _open(game['gameId'] as String),
            ),
          const Text(
            'This screen uses the public Board API. Bullet and random Blitz pairing are not '
            'supported by that API. Direct Blitz challenges are available above.',
          ),
        ],
      ),
    );
  }
}

class const BoardApiGameScreen({required final String gameId, super.key})
    extends ConsumerStatefulWidget {
  static Route<void> buildRoute(String id) =>
      buildScreenRoute(screen: BoardApiGameScreen(gameId: id));

  @override
  ConsumerState<BoardApiGameScreen> createState() => _BoardApiGameScreenState();
}

class _BoardApiGameScreenState()
    extends ConsumerState<BoardApiGameScreen>
    with WidgetsBindingObserver {
  StreamSubscription<IMap<String, dynamic>>? _stream;
  Timer? _retry;
  Timer? _clock;
  Timer? _moveEchoTimeout;
  int? _pendingMovePly;
  ChessboardController? _board;
  BoardGame? _game;
  String? _error;
  bool _connected = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _game?.playing == true) setState(() {});
    });
  }

  void _connect() {
    _stream = ref
        .read(boardApiProvider)
        .game(widget.gameId)
        .listen(
          (event) {
            if (!mounted) return;
            try {
              final game = switch (event['type']) {
                'gameFull' => BoardGame.fromFull(
                  event,
                  ref.read(authControllerProvider)!.user.id.toString(),
                ),
                'gameState' => _game?.update(event),
                _ => null,
              };
              if (game == null) return;
              if (event['type'] == 'gameFull' ||
                  game.position.ply != _pendingMovePly ||
                  !game.playing) {
                _pendingMovePly = null;
                _moveEchoTimeout?.cancel();
              }
              setState(() {
                _game = game;
                _connected = true;
                _error = null;
              });
              _syncBoard();
            } catch (_) {
              _lost(const BoardApiException('Could not decode the game. Reconnecting…'));
            }
          },
          onError: (Object error) => _lost(error),
          onDone: () {
            if (_game?.playing != false) _lost(null);
          },
          cancelOnError: true,
        );
  }

  void _lost(Object? error) {
    if (!mounted || _retry != null) return;
    setState(() {
      _connected = false;
      _pendingMovePly = null;
      _error = error?.toString() ?? 'Disconnected. Reconnecting…';
    });
    _syncBoard();
    final status = error is BoardApiException ? error.statusCode : null;
    if (status == 401 || status == 403) return;
    _retry = Timer(Duration(seconds: status == 429 ? 60 : 3), () async {
      _retry = null;
      await _stream?.cancel();
      if (mounted) _connect();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == .resumed && _game?.playing != false) {
      _retry?.cancel();
      _retry = null;
      _lost(null);
    }
  }

  void _syncBoard() {
    final game = _game;
    if (game == null) return;
    final prefs = ref.read(boardPreferencesProvider);
    final data = buildGameData(
      fen: game.position.fen,
      variant: game.variant,
      position: game.position,
      playerSide:
          game.playing &&
              _connected &&
              !_sending &&
              _pendingMovePly == null &&
              game.position.turn == game.side
          ? (game.side == .white ? PlayerSide.white : PlayerSide.black)
          : PlayerSide.none,
      castlingMethod: prefs.castlingMethod,
      boardHighlights: prefs.boardHighlights,
      lastMove: game.lastMove,
    );
    if (_board == null) {
      _board = ChessboardController(game: data);
    } else {
      _board!.updatePosition(data, resetPremove: true);
    }
  }

  Future<void> _move(Move move, {bool? viaDragAndDrop}) async {
    final game = _game;
    if (game == null || _sending || _pendingMovePly != null || !_connected || !game.playing) return;
    if (game.position.turn != game.side || !game.position.isLegal(move)) {
      _syncBoard();
      return;
    }
    _pendingMovePly = game.position.ply;
    // A successful HTTP response is not a new position. Wait for the server event;
    // if it was lost, reconnect and load a fresh authoritative snapshot, never resend.
    _moveEchoTimeout?.cancel();
    _moveEchoTimeout = Timer(const Duration(seconds: 10), () {
      if (_pendingMovePly != null) _lost(null);
    });
    await _action(() => ref.read(boardApiProvider).move(widget.gameId, move.uci));
  }

  Future<void> _action(Future<void> Function() send) async {
    if (_sending) return;
    setState(() => _sending = true);
    _syncBoard();
    try {
      await send();
    } catch (error) {
      if (mounted) {
        _moveEchoTimeout?.cancel();
        setState(() {
          _pendingMovePly = null;
          _error = error.toString();
        });
        // An interrupted response may still mean the move reached the server.
        // Reload the authoritative position instead of permitting a blind resubmission.
        _lost(error);
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _syncBoard();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _clock?.cancel();
    _moveEchoTimeout?.cancel();
    unawaited(_stream?.cancel());
    _board?.dispose();
    super.dispose();
  }

  static String _time(Duration? value) {
    if (value == null) return '—';
    return '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(boardApiProvider);
    final prefs = ref.watch(boardPreferencesProvider);
    final game = _game;
    return PlatformScaffold(
      extendBodyBehindAppBar: false,
      appBar: const PlatformAppBar(title: Text('Online game · Board API')),
      body: game == null
          ? Center(child: Text(_error ?? 'Connecting…'))
          : LayoutBuilder(
              builder: (context, constraints) {
                final size = math
                    .min(constraints.maxWidth, constraints.maxHeight - 180)
                    .clamp(80.0, 800.0);
                final now = DateTime.now();
                return SingleChildScrollView(
                  child: Column(
                    children: [
                      Text('${game.white}  ${_time(game.timeLeft(.white, now))}'),
                      Text('${game.black}  ${_time(game.timeLeft(.black, now))}'),
                      BoardWidget(
                        size: size,
                        orientation: game.side,
                        variant: game.variant,
                        controller: _board!,
                        settings: prefs.toBoardSettings(
                          game.variant,
                          appBrightness: Theme.of(context).brightness,
                        ),
                        onMove: _move,
                      ),
                      Text(
                        game.playing
                            ? (_connected ? 'Connected' : 'Reconnecting…')
                            : '${game.status}${game.winner == null ? '' : ' · ${game.winner} wins'}',
                      ),
                      if (_error != null) Text(_error!),
                      if (game.playing)
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: !_connected || _sending
                                  ? null
                                  : () => _action(
                                      () => ref.read(boardApiProvider).draw(widget.gameId, true),
                                    ),
                              child: Text(game.opponentDraw ? 'Accept draw' : 'Offer draw'),
                            ),
                            TextButton(
                              onPressed: !_connected || _sending
                                  ? null
                                  : () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('Resign this game?'),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.of(context).pop(false),
                                              child: const Text('Cancel'),
                                            ),
                                            TextButton(
                                              onPressed: () => Navigator.of(context).pop(true),
                                              child: const Text('Resign'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirmed == true && mounted) {
                                        await _action(
                                          () => ref.read(boardApiProvider).resign(widget.gameId),
                                        );
                                      }
                                    },
                              child: const Text('Resign'),
                            ),
                            if (game.position.ply < 2)
                              TextButton(
                                onPressed: !_connected || _sending
                                    ? null
                                    : () => _action(
                                        () => ref.read(boardApiProvider).abort(widget.gameId),
                                      ),
                                child: const Text('Abort'),
                              ),
                          ],
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
