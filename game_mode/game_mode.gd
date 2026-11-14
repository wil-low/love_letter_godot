class_name GameMode
extends Node2D

# Noble Family variant, todo step 24: the mode picker PLAY opens before a game starts.
#
# Shape follows `start.tscn`: a Label per row with ONE flat, full-area `Button` child, so the whole
# text is the tap target (the 8 px row is 64 real px at the 8x viewport scale) and the picker has no
# chrome of its own. `application.gd` owns the transition: PLAY hides the start page and shows this
# panel, a row here hides the panel and reports the choice, and ONLY then does a game start.
#
# The mode is chosen PER GAME and never persisted (todo §C fixed rules), so this scene stores
# nothing: no "last mode", no highlight, no default row. Every press is a fresh choice.
#
# DEVIATION from the todo's wording: `_ready()` hides the rows and the entry point is `show_rows()`,
# NOT an override of `show()` - Godot 4.7 rejects that ("The method show() overrides a method from
# native class CanvasItem", warning treated as error, verified with a probe script), and the engine
# would never call it. `hide()` stays native (the handlers call it, they do not redefine it).
signal classic_pressed
signal noble_family_pressed
signal back_pressed


func _ready() -> void:
	# A picker with visible rows at scene setup would be tappable before the start page is gone, and
	# a tap here must be impossible while a game is running.
	hide()
	_hide_rows()


# The entry point `application.gd` calls after PLAY: rows first, then the panel itself, so a shown
# panel never flashes an empty board.
func show_rows() -> void:
	_classic_row().show()
	_noble_row().show()
	_back_row().show()
	show()


func _hide_rows() -> void:
	for row: String in ["ClassicRow", "NobleRow", "BackRow"]:
		(get_node(row) as Control).hide()


func _row(name: String) -> Control:
	return get_node(name) as Control


func _classic_row() -> Control:
	return _row("ClassicRow")


func _noble_row() -> Control:
	return _row("NobleRow")


func _back_row() -> Control:
	return _row("BackRow")


# Every handler leaves the panel FIRST, then reports: the picker is a menu, and a menu that stays on
# screen while a game deals cards is a stuck overlay. The signals are the whole API - `application.gd`
# decides what a mode means (`Main.noble_family` + `start_game()`), this scene knows no game state.
func _on_classic_pressed() -> void:
	hide()
	classic_pressed.emit()


func _on_noble_family_pressed() -> void:
	hide()
	noble_family_pressed.emit()


func _on_back_pressed() -> void:
	hide()
	back_pressed.emit()
