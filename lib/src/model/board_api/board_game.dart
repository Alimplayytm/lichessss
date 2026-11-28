import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:lichess_mobile/src/model/board_api/board_api.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';

/// Server-authoritative state, rebuilt from the complete UCI move list after reconnects
/// and takebacks as well as normal moves. No native mobile game endpoint is involved.
class BoardGame({
  required final String id,
  required final Variant variant,
  required final String initialFen,
  required final String white,
  required final String black,
  required final Side side,
  required final Position position,
  required final Move? lastMove,
  required final String status,
  required final String? winner,
  required final Duration? whiteTime,
  required final Duration? blackTime,
  required final bool opponentDraw,
  required final DateTime receivedAt,
}) {
  bool get playing => status == 'started' || status == 'created';

  factory fromFull(IMap<String, dynamic> json, String userId) {
    final white = json['white'] as Map<String, dynamic>;
    final black = json['black'] as Map<String, dynamic>;
    final side = (white['id'] as String?)?.toLowerCase() == userId.toLowerCase()
        ? Side.white
        : (black['id'] as String?)?.toLowerCase() == userId.toLowerCase()
        ? Side.black
        : null;
    if (side == null) throw const BoardApiException('This account is not a player in this game.');
    final variantKey = (json['variant'] as Map<String, dynamic>)['key'] as String;
    final variant = Variant.values.firstWhere((value) => value.name == variantKey);
    final initialFen = json['initialFen'] as String;
    final initial = initialFen == 'startpos'
        ? variant.initialPosition
        : Position.setupPosition(variant.rule, Setup.parseFen(initialFen));
    return BoardGame(
      id: json['id'] as String,
      variant: variant,
      initialFen: initialFen,
      white: white['name'] as String? ?? 'White',
      black: black['name'] as String? ?? 'Black',
      side: side,
      position: initial,
      lastMove: null,
      status: 'created',
      winner: null,
      whiteTime: null,
      blackTime: null,
      opponentDraw: false,
      receivedAt: DateTime.now(),
    ).update((json['state'] as Map<String, dynamic>).lock);
  }

  BoardGame update(IMap<String, dynamic> state) {
    Position current = initialFen == 'startpos'
        ? variant.initialPosition
        : Position.setupPosition(variant.rule, Setup.parseFen(initialFen));
    Move? last;
    for (final uci in (state['moves'] as String).split(' ').where((move) => move.isNotEmpty)) {
      final move = Move.parse(uci);
      if (move == null || !current.isLegal(move)) {
        throw const BoardApiException('Could not decode the server move list.');
      }
      current = current.play(move);
      last = move;
    }
    return BoardGame(
      id: id,
      variant: variant,
      initialFen: initialFen,
      white: white,
      black: black,
      side: side,
      position: current,
      lastMove: last,
      status: state['status'] as String,
      winner: state['winner'] as String?,
      whiteTime: state['wtime'] == null ? null : Duration(milliseconds: state['wtime'] as int),
      blackTime: state['btime'] == null ? null : Duration(milliseconds: state['btime'] as int),
      opponentDraw: state[side == .white ? 'bdraw' : 'wdraw'] == true,
      receivedAt: DateTime.now(),
    );
  }

  Duration? timeLeft(Side color, DateTime now) {
    final time = color == .white ? whiteTime : blackTime;
    if (time == null || !playing || position.turn != color || position.ply < 2) return time;
    final remaining = time - now.difference(receivedAt);
    return remaining.isNegative ? Duration.zero : remaining;
  }
}
