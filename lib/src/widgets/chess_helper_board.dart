import 'dart:async';
import 'dart:math' as math;

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/chess_helper/chess_helper.dart';
import 'package:lichess_mobile/src/model/chess_helper/chess_helper_preferences.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/engine/engine.dart';
import 'package:lichess_mobile/src/model/engine/engine_providers.dart';
import 'package:lichess_mobile/src/model/engine/engine_spec.dart';
import 'package:lichess_mobile/src/widgets/platform_context_menu_button.dart';
import 'package:material_ui/material_ui.dart';

/// An iOS-only companion to a real board, not another owner of the game's position.
/// Collapsing the panel keeps hints running; leaving the board stops its search.
class const ChessHelperBoard({
  required final ChessboardController controller,
  required final Side orientation,
  required final ChessboardSettings settings,
  required final Widget child,
  super.key,
}) extends ConsumerStatefulWidget {
  @override
  ConsumerState<ChessHelperBoard> createState() => _ChessHelperBoardState();
}

class _ChessHelperBoardState() extends ConsumerState<ChessHelperBoard> with WidgetsBindingObserver {
  final _portal = OverlayPortalController();
  final _lines = <int, UciInfo>{};
  final _game = Object();
  ProviderSubscription<AsyncValue<Engine>>? _engineSubscription;
  StreamSubscription<UciInfo>? _infoSubscription;
  Search? _search;
  Timer? _debounce;
  Timer? _deadline;
  Position? _actual;
  Position? _searched;
  Position? _historyRoot;
  final _history = <UCIMove>[];
  HelperSuggestion? _suggestion;
  String? _error;
  String? _engineName;
  late ChessHelperPrefs _draft;
  int _epoch = 0;
  int _usedMistakes = 0;
  int _usedBlunders = 0;
  bool _running = false;
  bool _searching = false;
  bool _settingsTab = false;
  bool _pinned = false;
  bool _flipped = false;
  bool _foreground = true;
  bool _visible = true;
  bool _pointerDown = false;
  double _width = 350;
  double _height = 530;
  Offset _offset = const Offset(12, 80);

  @override
  void initState() {
    super.initState();
    _draft = ref.read(chessHelperPreferencesProvider);
    _width = _draft.panelWidth;
    _height = _draft.panelHeight;
    _pinned = _draft.pinned;
    _flipped = _draft.flipped;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onPosition);
    _readPosition();
  }

  @override
  void didUpdateWidget(ChessHelperBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPosition);
      widget.controller.addListener(_onPosition);
      _historyRoot = null;
      _history.clear();
      _usedMistakes = _usedBlunders = 0;
      _actual = null;
      _onPosition();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      if (visible) {
        _schedule();
      } else {
        _cancelSearch();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == .resumed;
    if (_foreground) {
      _schedule();
    } else {
      _cancelSearch();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onPosition);
    _cancelSearch();
    _engineSubscription?.close();
    super.dispose();
  }

  void _cancelSearch() {
    _epoch++;
    _debounce?.cancel();
    _deadline?.cancel();
    _search?.stop();
    _search = null;
    unawaited(_infoSubscription?.cancel());
    _infoSubscription = null;
    _searching = false;
  }

  void _readPosition() {
    try {
      final next = Chess.fromSetup(Setup.parseFen(widget.controller.fen));
      if (_actual?.fen == next.fen) return;
      final previous = _actual;
      Move? played;
      if (previous != null) {
        final lastMove = widget.controller.lastMove;
        final move = lastMove is NormalMove ? previous.normalizeMove(lastMove) : lastMove;
        if (move != null && previous.isLegal(move) && previous.play(move).fen == next.fen) {
          played = move;
        }
      }
      if (played != null && previous != null) {
        final suggested = _suggestion;
        if (_searched?.fen == previous.fen && suggested?.move == played.uci) {
          if (suggested?.weakness == .mistake) _usedMistakes++;
          if (suggested?.weakness == .blunder) _usedBlunders++;
        }
        _history.add(played.uci);
      } else {
        // Navigation, takeback or board replacement: never replay a disconnected move list.
        _historyRoot = next;
        _history.clear();
        _usedMistakes = _usedBlunders = 0;
      }
      _actual = next;
      _suggestion = null;
      _searched = null;
      _lines.clear();
      _error = null;
    } on Exception {
      _actual = null;
      _searched = null;
      _suggestion = null;
      _lines.clear();
      _history.clear();
      _historyRoot = null;
      _error = 'Поддерживаются только корректные позиции стандартных шахмат.';
    }
  }

  void _onPosition() {
    final oldFen = _actual?.fen;
    _readPosition();
    if (oldFen == _actual?.fen) return;
    _cancelSearch();
    _schedule();
    // Controllers can notify during another widget's build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _schedule() {
    _debounce?.cancel();
    if (!_running || !_visible || !_foreground) return;
    _debounce = Timer(const Duration(milliseconds: 200), _analyse);
  }

  Side get _player => switch (ref.read(chessHelperPreferencesProvider).playerColor) {
    .white => Side.white,
    .black => Side.black,
    _ => switch (widget.controller.game.playerSide) {
      PlayerSide.white => Side.white,
      PlayerSide.black => Side.black,
      _ => widget.orientation,
    },
  };

  Future<void> _analyse() async {
    _cancelSearch();
    final epoch = _epoch;
    final actual = _actual;
    final prefs = ref.read(chessHelperPreferencesProvider);
    final position = actual == null ? null : helperPosition(actual, _player, prefs);
    if (position == null) {
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      _searched = position;
      _lines.clear();
      _suggestion = null;
      _error = null;
      _searching = true;
    });
    try {
      const spec = StockfishSpec.light();
      _engineSubscription ??= ref.listenManual(engineProvider(spec), (_, next) {
        if (next case AsyncError(:final error)) {
          _cancelSearch();
          if (mounted) setState(() => _error = 'Ошибка движка: $error');
        }
      });
      if (ref.read(engineProvider(spec)) is AsyncError<Engine>) {
        ref.invalidate(engineProvider(spec));
      }
      final engine = await ref.read(engineProvider(spec).future);
      if (!mounted || epoch != _epoch || !_running) return;
      _engineName = engine.name.value;
      // Standard offline opponents use Fairy/LC0, not this slot. The helper can replace
      // an ordinary light-engine evaluation; otherwise infinite analysis would block it forever.
      final preview = position.fen != actual!.fen;
      final search = engine.search(
        SearchRequest(
          initialPosition: _historyRoot ?? actual,
          moves: _history.toIList(),
          fenOverride: preview ? position.fen : null,
          variant: Variant.standard,
          limit: SearchLimit.depth(prefs.depth.clamp(5, 20)),
          multiPv: prefs.plannedMistakes > _usedMistakes || prefs.plannedBlunders > _usedBlunders
              ? 4
              : 1,
          options: {
            'UCI_LimitStrength': prefs.eloEnabled ? 'true' : 'false',
            'UCI_Elo': '${prefs.elo.clamp(1350, 2850)}',
          }.toIMap(),
          game: _game,
        ),
      );
      _search = search;
      _deadline = Timer(const Duration(seconds: 15), search.stop);
      _infoSubscription = search.infos.listen((info) {
        if (!mounted || epoch != _epoch || info.pv.isEmpty) return;
        setState(() => _lines[info.multiPv] = info);
      });
      final best = await search.bestMove.timeout(const Duration(seconds: 30));
      if (!mounted || epoch != _epoch) return;
      _deadline?.cancel();
      await _infoSubscription?.cancel();
      if (!mounted || epoch != _epoch) return;
      _infoSubscription = null;
      _search = null;
      setState(() {
        _searching = false;
        _suggestion = chooseHelperSuggestion(
          _lines.values.toIList(),
          remainingMistakes: prefs.plannedMistakes - _usedMistakes,
          remainingBlunders: prefs.plannedBlunders - _usedBlunders,
        );
        if (_suggestion == null && best != null) {
          _suggestion = (move: best, weakness: null, loss: null);
        }
        if (_suggestion == null) _error = 'Расчёт прерван. Нажмите «Повторить».';
      });
      if (best == null) {
        // An evaluator may have taken the shared slot while this search was running.
        _debounce = Timer(const Duration(milliseconds: 500), _analyse);
      }
    } on Exception catch (error) {
      if (!mounted || epoch != _epoch) return;
      _cancelSearch();
      if (error is TimeoutException) {
        ref.invalidate(engineProvider(const StockfishSpec.light()));
      }
      setState(() {
        _searching = false;
        _suggestion = null;
        _lines.clear();
        _error = 'Не удалось запустить движок: $error';
      });
    }
  }

  void _toggleRunning() {
    setState(() {
      _running = !_running;
      _error = null;
      if (!_running) {
        _cancelSearch();
        _suggestion = null;
        _lines.clear();
      }
    });
    if (_running) {
      _schedule();
    } else {
      _engineSubscription?.close();
      _engineSubscription = null;
    }
  }

  String _san(UCIMove uci) {
    final position = _searched;
    final move = Move.parse(uci);
    if (position == null || move == null) return uci;
    final normalized = move is NormalMove ? position.normalizeMove(move) : move;
    return position.isLegal(normalized) ? position.makeSan(normalized).$2 : uci;
  }

  Future<void> _saveLayout() async {
    try {
      await ref
          .read(chessHelperPreferencesProvider.notifier)
          .save(
            ref
                .read(chessHelperPreferencesProvider)
                .copyWith(
                  panelWidth: _width,
                  panelHeight: _height,
                  pinned: _pinned,
                  flipped: _flipped,
                ),
          );
    } on Exception catch (error) {
      if (mounted) setState(() => _error = 'Ошибка сохранения: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _lines[1];
    final move = _running ? _suggestion?.move ?? info?.pv.firstOrNull : null;
    final parsedMove = move == null ? null : Move.parse(altCastles[move] ?? move);
    final parsed = parsedMove is NormalMove ? parsedMove : null;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        final screen = MediaQuery.sizeOf(context);
        final padding = MediaQuery.paddingOf(context);
        final width = math.min(_width, screen.width - 16);
        final height = math.min(_height, screen.height - padding.vertical - 16);
        final left = _offset.dx.clamp(8.0, math.max(8.0, screen.width - width - 8)).toDouble();
        final top = _offset.dy
            .clamp(
              padding.top + 8,
              math.max(padding.top + 8, screen.height - padding.bottom - height - 8),
            )
            .toDouble();
        return Stack(
          children: [
            if (!_pinned)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(_portal.hide),
                ),
              ),
            Positioned(
              left: left,
              top: top,
              width: width,
              height: height,
              child: Theme(
                data: ThemeData.dark().copyWith(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xFF80E3BD),
                    brightness: Brightness.dark,
                  ),
                ),
                child: Material(
                  elevation: 16,
                  color: const Color(0xFF172322),
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (details) =>
                            setState(() => _offset = Offset(left, top) + details.delta),
                        child: Row(
                          children: [
                            const SizedBox(width: 12),
                            const Expanded(child: Text('♟ Chess Helper')),
                            IconButton(
                              tooltip: _pinned ? 'Открепить' : 'Закрепить',
                              onPressed: () {
                                setState(() => _pinned = !_pinned);
                                unawaited(_saveLayout());
                              },
                              icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
                            ),
                            ContextMenuIconButton(
                              icon: const Icon(Icons.more_horiz),
                              semanticsLabel: 'Меню',
                              actions: [
                                ContextMenuAction(
                                  label: 'Перевернуть мини-доску',
                                  onPressed: () {
                                    setState(() => _flipped = !_flipped);
                                    unawaited(_saveLayout());
                                  },
                                ),
                                ContextMenuAction(
                                  label: 'Скопировать FEN',
                                  onPressed: () => unawaited(
                                    Clipboard.setData(
                                      ClipboardData(text: _actual?.fen ?? widget.controller.fen),
                                    ),
                                  ),
                                ),
                                ContextMenuAction(
                                  label: 'Сбросить размер окна',
                                  onPressed: () {
                                    setState(() {
                                      _width = 350;
                                      _height = 530;
                                      _offset = const Offset(12, 80);
                                    });
                                    unawaited(_saveLayout());
                                  },
                                ),
                              ],
                            ),
                            IconButton(
                              tooltip: 'Свернуть, не останавливая',
                              onPressed: () => setState(_portal.hide),
                              icon: const Icon(Icons.remove),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => setState(() => _settingsTab = false),
                              child: Text(_settingsTab ? 'Позиция' : '● Позиция'),
                            ),
                          ),
                          Expanded(
                            child: TextButton(
                              onPressed: () {
                                setState(() {
                                  _draft = ref.read(chessHelperPreferencesProvider);
                                  _settingsTab = true;
                                });
                              },
                              child: Text(_settingsTab ? '● Настройки' : 'Настройки'),
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _settingsTab
                              ? ChessHelperSettings(
                                  value: _draft,
                                  onChanged: (value) => setState(() => _draft = value),
                                  onSave: () async {
                                    try {
                                      await ref
                                          .read(chessHelperPreferencesProvider.notifier)
                                          .save(
                                            _draft.copyWith(
                                              panelWidth: _width,
                                              panelHeight: _height,
                                              pinned: _pinned,
                                              flipped: _flipped,
                                            ),
                                          );
                                      if (!mounted) return;
                                      setState(() => _settingsTab = false);
                                      _cancelSearch();
                                      _suggestion = null;
                                      _lines.clear();
                                      _schedule();
                                    } on Exception catch (error) {
                                      if (mounted) {
                                        setState(() => _error = 'Ошибка сохранения: $error');
                                      }
                                    }
                                  },
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    const Text(
                                      'Подсказки в онлайн-партиях нарушают fair play '
                                      'и могут привести к блокировке.',
                                      style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
                                    ),
                                    const SizedBox(height: 8),
                                    Center(
                                      child: StaticChessboard(
                                        size: math.min(width - 32, 224),
                                        fen: _actual?.fen ?? widget.controller.fen,
                                        orientation: _flipped
                                            ? widget.orientation.opposite
                                            : widget.orientation,
                                        settings: StaticChessboardSettings.fromBoardSettings(
                                          widget.settings,
                                        ),
                                        shapes: {
                                          if (parsed != null)
                                            Arrow(
                                              orig: parsed.from,
                                              dest: parsed.to,
                                              color: const Color(0xCC80E3BD),
                                            ),
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      info == null
                                          ? 'Лучший ход: —'
                                          : 'Лучший ход: ${_san(info.pv.first)} (${info.pv.first})',
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                    if (_suggestion?.weakness case final weakness?)
                                      Text(
                                        'Тренировочный ход: ${move == null ? '—' : _san(move)}'
                                        ' · ${weakness == .blunder ? 'зевок' : 'ошибка'}'
                                        '${_suggestion?.loss == null ? '' : ' · потеря ${_suggestion!.loss} cp'}',
                                      ),
                                    Text(
                                      'Оценка за белых: ${info == null || _searched == null ? '—' : helperScore(info, _searched!.turn)}',
                                    ),
                                    LinearProgressIndicator(
                                      value: info?.cp == null || _searched == null
                                          ? 0.5
                                          : 1 /
                                                (1 +
                                                    math.exp(
                                                      -0.00368208 *
                                                          info!.cp! *
                                                          (_searched!.turn == .white ? 1 : -1),
                                                    )),
                                      semanticsLabel: 'Условная оценка, не вероятность победы',
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${_engineName ?? 'Stockfish'} · глубина ${info?.depth ?? '—'}'
                                      ' · ${info == null || info.elapsed.inMilliseconds == 0 ? '—' : (info.nodes * 1000 / info.elapsed.inMilliseconds).round()} узлов/с',
                                    ),
                                    if (_searched != null && _searched!.fen != _actual?.fen)
                                      const Text(
                                        'Предварительный вариант без ответа соперника.',
                                        style: TextStyle(color: Colors.orangeAccent),
                                      ),
                                    if (_running && _searched == null && _error == null)
                                      const Text(
                                        'Нет подсказки: выбран другой цвет, шах или партия завершена.',
                                      ),
                                    if (_searching) const Text('Расчёт…'),
                                    if (_error != null) Text(_error!),
                                    Text(
                                      'Ошибки: $_usedMistakes/${ref.watch(chessHelperPreferencesProvider).plannedMistakes}'
                                      ' · зевки: $_usedBlunders/${ref.watch(chessHelperPreferencesProvider).plannedBlunders}',
                                    ),
                                    FilledButton(
                                      onPressed: _toggleRunning,
                                      child: Text(
                                        _running ? 'Остановить анализ' : 'Начать подсказки',
                                      ),
                                    ),
                                    if (_running && !_searching)
                                      TextButton(
                                        onPressed: _schedule,
                                        child: const Text('Повторить'),
                                      ),
                                  ],
                                ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (details) => setState(() {
                            _width = (width + details.delta.dx).clamp(
                              math.min(280.0, screen.width - 16),
                              screen.width - 16,
                            );
                            _height = (height + details.delta.dy).clamp(
                              math.min(250.0, screen.height - padding.vertical - 16),
                              screen.height - padding.vertical - 16,
                            );
                          }),
                          onPanEnd: (_) => unawaited(_saveLayout()),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle, semanticLabel: 'Изменить размер окна'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: Stack(
        children: [
          Listener(
            onPointerDown: (_) => setState(() => _pointerDown = true),
            onPointerUp: (_) => setState(() => _pointerDown = false),
            onPointerCancel: (_) => setState(() => _pointerDown = false),
            child: widget.child,
          ),
          if (parsed != null && !_pointerDown)
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      for (final square in [parsed.from, parsed.to])
                        Positioned(
                          left:
                              (widget.orientation == .white
                                  ? square.file.value
                                  : 7 - square.file.value) *
                              constraints.maxWidth /
                              8,
                          top:
                              (widget.orientation == .white
                                  ? 7 - square.rank.value
                                  : square.rank.value) *
                              constraints.maxHeight /
                              8,
                          width: constraints.maxWidth / 8,
                          height: constraints.maxHeight / 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0x4480E3BD),
                              border: Border.all(color: const Color(0xFF80E3BD), width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            right: 4,
            bottom: 4,
            child: IconButton.filledTonal(
              tooltip: 'Chess Helper',
              onPressed: () => setState(_portal.toggle),
              icon: Icon(_running ? Icons.lightbulb : Icons.lightbulb_outline),
            ),
          ),
        ],
      ),
    );
  }
}

class const ChessHelperSettings({
  required final ChessHelperPrefs value,
  required final ValueChanged<ChessHelperPrefs> onChanged,
  required final VoidCallback onSave,
  super.key,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ограничить силу'),
          value: value.eloEnabled,
          onChanged: (enabled) => onChanged(value.copyWith(eloEnabled: enabled)),
        ),
        Text('${value.elo} Elo'),
        Slider(
          value: value.elo.clamp(1350, 2850).toDouble(),
          min: 1350,
          max: 2850,
          divisions: 30,
          onChanged: value.eloEnabled ? (elo) => onChanged(value.copyWith(elo: elo.round())) : null,
        ),
        Text('Глубина: ${value.depth}'),
        Slider(
          value: value.depth.clamp(5, 20).toDouble(),
          min: 5,
          max: 20,
          divisions: 15,
          onChanged: (depth) => onChanged(value.copyWith(depth: depth.round())),
        ),
        const Text('Режим подсказок'),
        DropdownButton<HelperHintMode>(
          isExpanded: true,
          value: value.hintMode,
          items: const [
            DropdownMenuItem(value: HelperHintMode.playerPreview, child: Text('Как в v1: за меня')),
            DropdownMenuItem(value: HelperHintMode.actualTurn, child: Text('По реальной очереди')),
          ],
          onChanged: (mode) {
            if (mode != null) onChanged(value.copyWith(hintMode: mode));
          },
        ),
        const Text('Моя сторона'),
        DropdownButton<HelperSide>(
          isExpanded: true,
          value: value.playerColor,
          items: const [
            DropdownMenuItem(value: HelperSide.auto, child: Text('Авто')),
            DropdownMenuItem(value: HelperSide.white, child: Text('Белые')),
            DropdownMenuItem(value: HelperSide.black, child: Text('Чёрные')),
          ],
          onChanged: (side) {
            if (side != null) onChanged(value.copyWith(playerColor: side));
          },
        ),
        const Text('Для кого показывать подсказки'),
        DropdownButton<HelperSide>(
          isExpanded: true,
          value: value.hintSide,
          items: const [
            DropdownMenuItem(value: HelperSide.both, child: Text('Обе стороны')),
            DropdownMenuItem(value: HelperSide.white, child: Text('Белые')),
            DropdownMenuItem(value: HelperSide.black, child: Text('Чёрные')),
          ],
          onChanged: value.hintMode == .playerPreview
              ? null
              : (side) {
                  if (side != null) onChanged(value.copyWith(hintSide: side));
                },
        ),
        Text('Намеренные ошибки: ${value.plannedMistakes}'),
        Slider(
          value: value.plannedMistakes.clamp(0, 20).toDouble(),
          max: 20,
          divisions: 20,
          onChanged: (count) => onChanged(value.copyWith(plannedMistakes: count.round())),
        ),
        Text('Намеренные зевки: ${value.plannedBlunders}'),
        Slider(
          value: value.plannedBlunders.clamp(0, 20).toDouble(),
          max: 20,
          divisions: 20,
          onChanged: (count) => onChanged(value.copyWith(plannedBlunders: count.round())),
        ),
        const Text(
          'Слабый ход выбирается из вариантов MultiPV. Ошибка или зевок нужной тяжести '
          'не гарантируются. Лимит расходуется только после выполнения подсказанного хода.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: onSave, child: const Text('Сохранить настройки')),
      ],
    );
  }
}
