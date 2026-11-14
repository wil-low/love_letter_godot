class_name Stats
extends Node2D

signal back_pressed

const LABELS: String = "H12345"
@onready var _levels: Array[Label] = [$L_H, $L_1, $L_2, $L_3, $L_4, $L_5]

# Noble Family variant, todo §C.27: the page's OWN mode switch, in the left margin (the one column of
# the 84 x 48 board no counter row uses). `mode` is which table the page SHOWS; the two arrow buttons
# flip it, `ModeLabel` names it with a single letter so a player always knows which history he is
# looking at.
@onready var _mode_label: Label = $ModeLabel

# One letter per mode, indexed by `mode`: "C" = classic, "F" = noble family (the variant). A letter, not a word, so
# the whole left margin is a 9 px column (a 12 px digit sprite is 9 px wide and the margin is 16 px).
const MODE_LETTERS: String = "CF"

# Noble Family variant, todo §C.26: ONE counter table PER MODE, so a variant game's numbers never
# mix with a classic game's. Index = mode: MODE_CLASSIC / MODE_NOBLE.
# `Array[Array[int]]` is REJECTED by Godot 4.7 ("Nested typed collections are not supported"), so
# the OUTER array is untyped and every element is a real `Array[int]` — the same shape
# `Deck.prepare_noble()` returns (progress, step 3).
const MODE_CLASSIC: int = 0
const MODE_NOBLE: int = 1
const MODE_COUNT: int = 2

var tables: Array = [empty_table(), empty_table()]
var mode: int = MODE_CLASSIC
var invoker: Node2D

# The pre-variant name stays alive as an ALIAS of the CURRENT mode's table, so `application.gd`
# (read, mutate and whole-array assignment of a loaded save) needs no change. A getter-only
# property cannot be assigned, so it has both halves: the getter hands out the SAME array the
# table holds (Godot 4 arrays are references: `alias[i] = n` and `table()[i] = n` both mutate
# `tables[mode]`), and the setter NORMALIZES what it stores to `Array[int]` — a save loaded from
# `options.cfg` arrives as an untyped `Array`, and an untyped element makes `table()` raise
# "Trying to return a value of type Array from a function whose return type is Array[int]".
# The length is preserved on purpose: `application.gd` drops a save of the wrong size, and a
# setter that padded it would silently accept stale stats.
var _totals_and_wins: Array:
	get:
		return tables[mode]
	set(value):
		tables[mode] = ints_of(value)


func table() -> Array[int]:
	return tables[mode]


func mode_letter() -> String:
	return MODE_LETTERS[mode]


# The mode switch: browse the other table, touch NOTHING else. Flipping never clears, copies, merges
# or re-sorts a counter (the tables are independent by §C.26), never closes the page and never moves
# the Back/Reset buttons. `wrapi` wraps, so both arrows stay alive at both ends of a 2-mode list:
# a control with a dead end is a mode a player cannot reach back from.
#
# The wrap is over `MODE_COUNT`, NOT `MODE_COUNT - 1`, because `wrapi`'s upper bound is EXCLUSIVE
# (`wrapi(1, 0, 1)` is 0 - measured in the suite). Written with the inclusive bound, EVERY press
# clamped to mode 0 and the NOBLE table was UNREACHABLE: two tables a player could never read,
# which is the exact failure this step is about. `show_mode()` takes a DELTA from the current mode
# (the arrows are Left/Right, not "go to mode N"), so the page never names a mode - `application.gd`
# stays the only file in the project that names one (step 26), and the switch stays a view.
func _on_left_button_pressed() -> void:
	show_mode(mode - 1)


func _on_right_button_pressed() -> void:
	show_mode(mode + 1)


func show_mode(next: int) -> void:
	mode = wrapi(next, 0, MODE_COUNT)
	update_labels()


func empty_table() -> Array[int]:
	var t: Array[int] = []
	for i in 2 * Player.AI_Level.size():  # totals + wins per AI level
		t.append(0)
	return t


func ints_of(value) -> Array[int]:
	var t: Array[int] = []
	if value is Array:
		for v in value:
			t.append(int(v))
	return t


func _on_back_button_pressed() -> void:
	hide()
	back_pressed.emit()


# Reset clears ONLY the visible table: the other mode's history is not the player's target here.
func _on_reset_button_pressed() -> void:
	tables[mode] = empty_table()
	update_labels()


func update_labels() -> void:
	var t := table()
	for i in _levels.size():
		# A table SHORTER than the 12 slots the page shows is possible: `application.gd` assigns a
		# loaded save WHOLE and only AFTERWARDS checks its size, so a 0-length save (a missing key) is
		# live here for a moment. Indexing it would be a runtime error, and a stats page must not be
		# able to crash the game it is a child of.
		if t.size() < 2 * i + 2:
			continue
		_levels[i].text = "%5d  %s  %-5d" % [t[2 * i], LABELS[i], t[2 * i + 1]]
	# The mode letter is part of the page's state, so it refreshes on the SAME call the rows do: a
	# player who flips a table sees the letter flip in the same frame, never a row set labeled by the
	# mode he left. Guarded for the same reason as the rows — the page may be told to refresh before
	# its `@onready` children exist.
	if _mode_label != null:
		_mode_label.text = mode_letter()
