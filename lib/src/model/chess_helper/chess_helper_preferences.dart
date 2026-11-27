import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:lichess_mobile/src/model/settings/preferences_storage.dart';

part 'chess_helper_preferences.freezed.dart';
part 'chess_helper_preferences.g.dart';

enum HelperHintMode() {
  playerPreview,
  actualTurn,
}

enum HelperSide() {
  auto,
  white,
  black,
  both,
}

final chessHelperPreferencesProvider = NotifierProvider<ChessHelperPreferences, ChessHelperPrefs>(
  ChessHelperPreferences.new,
);

class ChessHelperPreferences()
    extends Notifier<ChessHelperPrefs>
    with PreferencesStorage<ChessHelperPrefs> {
  @override
  final prefCategory = PrefCategory.chessHelper;

  @override
  ChessHelperPrefs get defaults => const ChessHelperPrefs();

  @override
  ChessHelperPrefs fromJson(Map<String, dynamic> json) => ChessHelperPrefs.fromJson(json);

  @override
  ChessHelperPrefs build() => fetch();
}

@Freezed(fromJson: true, toJson: true)
sealed class ChessHelperPrefs with _$ChessHelperPrefs implements Serializable {
  const factory({
    @Default(true) bool eloEnabled,
    @Default(1800) int elo,
    @Default(12) int depth,
    @Default(HelperHintMode.playerPreview) HelperHintMode hintMode,
    @Default(HelperSide.auto) HelperSide playerColor,
    @Default(HelperSide.both) HelperSide hintSide,
    @Default(0) int plannedMistakes,
    @Default(0) int plannedBlunders,
    @Default(350.0) double panelWidth,
    @Default(530.0) double panelHeight,
    @Default(false) bool pinned,
    @Default(false) bool flipped,
  }) = _ChessHelperPrefs;

  factory fromJson(Map<String, dynamic> json) => _$ChessHelperPrefsFromJson(json);
}
