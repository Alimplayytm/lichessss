import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/chess_helper/chess_helper.dart';
import 'package:lichess_mobile/src/model/chess_helper/chess_helper_preferences.dart';
import 'package:lichess_mobile/src/model/engine/engine.dart';

UciInfo line(int index, String move, int cp) => UciInfo(
  depth: 12,
  nodes: 1000,
  multiPv: index,
  elapsed: const Duration(seconds: 1),
  pv: IList([move]),
  cp: cp,
);

void main() {
  test('real-turn mode respects the side filter', () {
    const prefs = ChessHelperPrefs(hintMode: .actualTurn, hintSide: .black);
    expect(helperPosition(Chess.initial, .white, prefs), isNull);
    expect(
      helperPosition(Chess.initial.play(Move.parse('e2e4')!), .white, prefs)?.turn,
      Side.black,
    );
  });

  test('preview does not change the real FEN or retain en passant', () {
    final actual = Chess.fromSetup(Setup.parseFen('4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2'));
    final fen = actual.fen;
    final preview = helperPosition(actual, .black, const ChessHelperPrefs());
    expect(preview?.turn, Side.black);
    expect(preview?.epSquare, isNull);
    expect(actual.fen, fen);
    expect(actual.epSquare, Square.d6);
  });

  test('does not manufacture a preview when the opponent is in check', () {
    final checked = Chess.fromSetup(Setup.parseFen('4k3/8/8/8/8/8/4R3/4K3 b - - 0 1'));
    expect(checked.isCheck, isTrue);
    expect(helperPosition(checked, .white, const ChessHelperPrefs()), isNull);
  });

  test('does not search a finished position', () {
    final mate = Chess.fromSetup(Setup.parseFen('7k/6Q1/5K2/8/8/8/8/8 b - - 0 1'));
    expect(helperPosition(mate, .black, const ChessHelperPrefs()), isNull);
  });

  test('real positions keep all four castling moves legal', () {
    for (final side in ['w', 'b']) {
      final actual = Chess.fromSetup(Setup.parseFen('r3k2r/8/8/8/8/8/8/R3K2R $side KQkq - 0 1'));
      final position = helperPosition(actual, actual.turn, const ChessHelperPrefs())!;
      final rank = side == 'w' ? '1' : '8';
      for (final file in ['a', 'h']) {
        expect(position.isLegal(Move.parse('e$rank$file$rank')!), isTrue);
      }
      expect(position.fen, actual.fen);
    }
  });

  test('preview never invents lost castling rights', () {
    final actual = Chess.fromSetup(Setup.parseFen('r3k2r/8/8/8/8/8/8/R3K2R b - - 0 1'));
    final preview = helperPosition(actual, .white, const ChessHelperPrefs())!;
    expect(preview.fen.split(' ')[2], '-');
    expect(preview.isLegal(Move.parse('e1h1')!), isFalse);
  });

  test('no quotas selects the first principal variation', () {
    final suggestion = chooseHelperSuggestion(
      [line(2, 'd2d4', 10), line(1, 'e2e4', 30)].toIList(),
      remainingMistakes: 0,
      remainingBlunders: 0,
    );
    expect(suggestion?.move, 'e2e4');
    expect(suggestion?.weakness, isNull);
  });

  test('blunder quota takes precedence and selects the weakest alternative', () {
    final suggestion = chooseHelperSuggestion(
      [line(1, 'e2e4', 30), line(2, 'd2d4', 10), line(3, 'a2a3', -100)].toIList(),
      remainingMistakes: 1,
      remainingBlunders: 1,
    );
    expect(suggestion, (move: 'a2a3', weakness: HelperWeakMove.blunder, loss: 130));
  });

  test('mistake quota selects the second-weakest alternative when available', () {
    final suggestion = chooseHelperSuggestion(
      [line(1, 'e2e4', 30), line(2, 'd2d4', 10), line(3, 'a2a3', -100)].toIList(),
      remainingMistakes: 1,
      remainingBlunders: 0,
    );
    expect(suggestion?.move, 'd2d4');
    expect(suggestion?.weakness, HelperWeakMove.mistake);
  });

  test('an empty or cancelled search has no invented recommendation', () {
    expect(
      chooseHelperSuggestion(const IListConst([]), remainingMistakes: 1, remainingBlunders: 1),
      isNull,
    );
  });

  test('scores are always from white perspective', () {
    expect(helperScore(line(1, 'e2e4', 23), .white), '+0.23');
    expect(helperScore(line(1, 'e7e5', 23), .black), '-0.23');
    expect(
      helperScore(
        const UciInfo(
          depth: 12,
          nodes: 100,
          multiPv: 1,
          elapsed: Duration(seconds: 1),
          pv: IListConst(['e7e5']),
          mate: 3,
        ),
        .black,
      ),
      'M-3',
    );
  });

  test('settings and panel preferences survive JSON round-trip', () {
    const prefs = ChessHelperPrefs(
      eloEnabled: false,
      depth: 18,
      hintMode: .actualTurn,
      playerColor: .black,
      plannedMistakes: 3,
      plannedBlunders: 2,
      panelWidth: 320,
      pinned: true,
      flipped: true,
    );
    expect(ChessHelperPrefs.fromJson(prefs.toJson()), prefs);
    expect(ChessHelperPrefs.fromJson({}), const ChessHelperPrefs());
  });
}
