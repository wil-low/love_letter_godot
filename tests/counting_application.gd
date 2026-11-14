extends "res://application/application.gd"
# Test-only `Application` subclass (installed with `set_script`, no production file is touched -
# the same technique as tests/counting_main.gd and tests/fake_deck.gd).
#
# Step 25 wires the mode picker into the application, and its gate is a SEQUENCING rule:
# `Main.noble_family` must be set BEFORE the deal is decided, because `init_players()` ->
# `_new_game()` -> `_new_round()` READS the flag once, at the deal, to choose the deal table.
# Sampling the flag after a row press cannot tell "set then start" from "start then set".
#
# The recorder is therefore split across the two scripts a game is made of:
#   * THIS file records the Application side: how many times PLAY arrived, how many times a mode
#     handler asked for a game, and the value of `Main.noble_family` ON ENTRY to `start_game()`
#     (a handler that set the mode AFTER this call records the OLD value, which is the failure
#     step 25 must catch).
#   * tests/counting_main.gd records the deal side: `init_players()` is a Main method, not an
#     Application one, so the "value the deal reads" seam lives there.
#
# Counting is also the "PLAY starts NOTHING" proof: PLAY opens a menu, so it must produce 0
# `start_game()` calls (here) and 0 deals (there).

var play_presses: int = 0  # how many times the start page's PLAY reached the application
var start_game_calls: int = 0  # how many games the mode handlers asked to start
var start_seams: Array = []  # per start_game() ENTRY: {noble, picker_visible, start_visible, main_visible}


func _on_start_play_pressed() -> void:
	play_presses += 1
	super()


# A plain `super()`: production `start_game()` never awaits, so the override stays a plain method and
# every caller keeps its exact current behaviour.
func start_game() -> void:
	start_game_calls += 1
	start_seams.append({
		"noble": _main.noble_family,
		"picker_visible": _game_mode.visible,
		"start_visible": _start.visible,
		"main_visible": _main.visible,
	})
	super()
