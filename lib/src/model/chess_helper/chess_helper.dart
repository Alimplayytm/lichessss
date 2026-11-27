import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:lichess_mobile/src/model/chess_helper/chess_helper_preferences.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/engine/engine.dart';

/// Preview positions are hypothetical, never a replacement for the actual game position.
Position? helperPosition(Position actual, Side player, ChessHelperPrefs prefs) {
  if (actual is! Chess || actual.isGameOver) return null;
  if (prefs.hintMode == .actualTurn) {
    if (prefs.hintSide == .white && actual.turn != .white ||
        prefs.hintSide == .black && actual.turn != .black) {
      return null;
    }
    return actual;
  }
  if (actual.turn == player) return actual;
  if (actual.isCheck) return null;
  final fields = actual.fen.split(' ');
  fields[1] = player == .white ? 'w' : 'b';
  fields[3] = '-';
  try {
    return Chess.fromSetup(Setup.parseFen(fields.join(' ')));
  } on PositionSetupException {
    return null;
  }
}

enum HelperWeakMove() {
  mistake,
  blunder,
}

typedef HelperSuggestion = ({UCIMove move, HelperWeakMove? weakness, int? loss});

/// Mirrors the extension's MultiPV choice. A quota is consumed only when the move is played.
HelperSuggestion? chooseHelperSuggestion(
  IList<UciInfo> lines, {
  required int remainingMistakes,
  required int remainingBlunders,
}) {
  final candidates = lines.where((line) => line.pv.isNotEmpty).toList()
    ..sort((a, b) => a.multiPv.compareTo(b.multiPv));
  if (candidates.isEmpty) return null;
  final best = candidates.first;
  final alternatives = candidates.skip(1).where((line) => line.cp != null).toList()
    ..sort((a, b) => a.cp!.compareTo(b.cp!));
  if (alternatives.isEmpty || remainingMistakes <= 0 && remainingBlunders <= 0) {
    return (move: best.pv.first, weakness: null, loss: null);
  }
  final selected = remainingBlunders > 0
      ? alternatives.first
      : alternatives[alternatives.length > 1 ? 1 : 0];
  return (
    move: selected.pv.first,
    weakness: remainingBlunders > 0 ? .blunder : .mistake,
    loss: best.cp == null ? null : (best.cp! - selected.cp!).clamp(0, 100000),
  );
}

/// Engine scores are relative to the searched side, including in a hypothetical preview.
String helperScore(UciInfo info, Side searchedSide) {
  final sign = searchedSide == .white ? 1 : -1;
  if (info.mate case final mate?) return 'M${mate * sign}';
  if (info.cp case final cp?) {
    final value = cp * sign / 100;
    return '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)}';
  }
  return '—';
}
