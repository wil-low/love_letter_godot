class_name Stats
extends Node2D

signal back_pressed
signal stats_reset_requested

const LABELS: String = "H12345"
const MAX_GAMES: int = 99999
@onready var _levels: Array[Label] = [$L_H, $L_1, $L_2, $L_3, $L_4, $L_5]

var invoker: Node2D

## Flat pairs of [rounds won, rounds played] per row of LABELS,
## matching the "wins  LEVEL  games" layout of the labels.
var _totals_and_wins: Array[int] = []


func _ready() -> void:
	reset()


# One row per playable level (Human + AI levels); Disabled is not tracked.
func _row_count() -> int:
	return LABELS.length()


func _entry_count() -> int:
	return 2 * _row_count()


func reset() -> void:
	_totals_and_wins = []
	_totals_and_wins.resize(_entry_count())
	update_labels()


static func _int_at(saved: Array, idx: int) -> int:
	if idx < 0 or idx >= saved.size() or not saved[idx] is int:
		return 0
	return clampi(saved[idx], 0, MAX_GAMES)


## Builds that had one row per rule set saved a pair for every AI_Level entry,
## Disabled included: 2 * (level + 1). Re-index to the current layout.
static func migrate_legacy(saved: Array) -> Array:
	if saved.size() != 2 * Player.AI_Level.size():
		return []
	var migrated: Array[int] = []
	migrated.resize(2 * LABELS.length())
	for level in LABELS.length():
		migrated[2 * level] = _int_at(saved, 2 * (level + 1))
		migrated[2 * level + 1] = _int_at(saved, 2 * (level + 1) + 1)
	return migrated


## Restore saved stats, padding missing rows and dropping entries saved
## for a level that is no longer tracked.
func adopt(saved: Array) -> void:
	if saved.size() > _entry_count():
		var migrated: Array = migrate_legacy(saved)
		if not migrated.is_empty():
			saved = migrated
	var normalized: Array[int] = []
	normalized.resize(_entry_count())
	for i in normalized.size():
		normalized[i] = _int_at(saved, i)
	_totals_and_wins = normalized
	update_labels()


func record_finished(level: Player.AI_Level) -> void:
	_bump(2 * level + 1)


func record_win(level: Player.AI_Level) -> void:
	_bump(2 * level)


func _bump(idx: int) -> void:
	if idx < 0 or idx >= _totals_and_wins.size():
		return
	_totals_and_wins[idx] = clampi(_totals_and_wins[idx] + 1, 0, MAX_GAMES)


func _on_back_button_pressed() -> void:
	hide()
	back_pressed.emit()


func _on_reset_button_pressed() -> void:
	reset()
	# the reset is only durable once it reaches the config file
	stats_reset_requested.emit()


func update_labels() -> void:
	for i in _levels.size():
		_levels[i].text = "%5d  %s  %-5d" % [_totals_and_wins[2 * i], LABELS[i], _totals_and_wins[2 * i + 1]]
