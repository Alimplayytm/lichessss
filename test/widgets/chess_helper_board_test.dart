import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/game/game_board_params.dart';
import 'package:lichess_mobile/src/widgets/game_layout.dart';
import 'package:material_ui/material_ui.dart';

import '../model/engine/fake_engine.dart';
import '../test_provider_scope.dart';

class HoldingHelperEngine() extends FakeEngine {
  @override
  void onGo(FakeEngineSession session, List<String> parts) {}

  @override
  void onStop(FakeEngineSession session) {
    session.emit('bestmove e2e4');
  }
}

Future<void> openHelper(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  FakeEngine? engine,
}) async {
  fakeEngine = engine ?? FakeEngine();
  final app = await makeTestProviderScopeApp(
    tester,
    surfaceSize: size,
    home: Scaffold(
      body: GameLayout(
        orientation: Side.white,
        boardParams: GameBoardParams.interactive(
          variant: Variant.standard,
          position: Chess.initial,
          playerSide: PlayerSide.white,
          onMove: (_, {viaDragAndDrop}) {},
        ),
      ),
    ),
  );
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Chess Helper'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('stopping discards late engine results and cancels the search deadline', (
    tester,
  ) async {
    final engine = HoldingHelperEngine();
    await openHelper(tester, engine: engine);
    await tester.ensureVisible(find.text('Начать подсказки'));
    await tester.tap(find.text('Начать подсказки'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(engine.commands.any((command) => command == 'go depth 12'), isTrue);
    await tester.ensureVisible(find.text('Остановить анализ'));
    await tester.tap(find.text('Остановить анализ'));
    await tester.pumpAndSettle();
    expect(engine.stopCount, 1);
    expect(find.text('Лучший ход: —'), findsOneWidget);
    expect(find.text('Начать подсказки'), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
    expect(engine.stopCount, 1);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('backgrounding stops native work and foregrounding resumes enabled hints', (
    tester,
  ) async {
    final engine = HoldingHelperEngine();
    await openHelper(tester, engine: engine);
    await tester.ensureVisible(find.text('Начать подсказки'));
    await tester.tap(find.text('Начать подсказки'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(engine.stopCount, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(engine.commands.where((command) => command == 'go depth 12').length, 2);
    await tester.ensureVisible(find.text('Остановить анализ'));
    await tester.tap(find.text('Остановить анализ'));
    await tester.pumpAndSettle();
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('iOS menu has position and settings, without game review', (tester) async {
    await openHelper(tester);
    expect(find.text('● Позиция'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Разбор партии'), findsNothing);
    expect(fakeEngine.startCount, 0);
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('● Настройки'), findsOneWidget);
    expect(find.text('Ограничить силу'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('starts native hints and collapsing does not stop the helper', (tester) async {
    await openHelper(tester);
    await tester.ensureVisible(find.text('Начать подсказки'));
    await tester.tap(find.text('Начать подсказки'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(fakeEngine.startCount, 1);
    expect(fakeEngine.commands.any((command) => command == 'go depth 12'), isTrue);
    expect(find.text('Лучший ход: e4 (e2e4)'), findsOneWidget);
    await tester.tap(find.byTooltip('Свернуть, не останавливая'));
    await tester.pumpAndSettle();
    expect(find.text('♟ Chess Helper'), findsNothing);
    await tester.tap(find.byTooltip('Chess Helper'));
    await tester.pumpAndSettle();
    expect(find.text('Остановить анализ'), findsOneWidget);
    await tester.ensureVisible(find.text('Остановить анализ'));
    await tester.tap(find.text('Остановить анализ'));
    await tester.pumpAndSettle();
    expect(find.text('Начать подсказки'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('mini-board flip leaves the real board unchanged', (tester) async {
    await openHelper(tester);
    expect(tester.widget<Chessboard>(find.byType(Chessboard)).orientation, Side.white);
    await tester.tap(find.byTooltip('Меню'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Перевернуть мини-доску'));
    await tester.pumpAndSettle();
    expect(tester.widget<StaticChessboard>(find.byType(StaticChessboard)).orientation, Side.black);
    expect(tester.widget<Chessboard>(find.byType(Chessboard)).orientation, Side.white);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  for (final size in [const Size(320, 568), const Size(844, 390), const Size(810, 1080)]) {
    testWidgets('panel fits $size without overflow', (tester) async {
      await openHelper(tester, size: size);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
  }

  testWidgets('does not add the helper on Android', (tester) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: const Scaffold(
        body: GameLayout(
          orientation: Side.white,
          boardParams: GameBoardParams.readonly(variant: Variant.standard, position: Chess.initial),
        ),
      ),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Chess Helper'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
