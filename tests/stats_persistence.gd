extends Node

const FILE := "user://stats_persistence_test.cfg"

var _failures: Array[String] = []


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("FAIL: ", msg)


func _assert_eq(actual, expected, msg: String) -> void:
	# stringified so that Array[int] and Array compare the same way
	if str(actual) != str(expected):
		_fail(msg + " (expected %s, got %s)" % [str(expected), str(actual)])


func _zeros() -> Array:
	return range(12).map(func(_x): return 0)


func _ready() -> void:
	await get_tree().process_frame
	var stats: Stats = load("res://stats/stats.tscn").instantiate()
	add_child(stats)
	await get_tree().process_frame

	# fresh stats: one wins/games pair per tracked level
	_assert_eq(stats._totals_and_wins.size(), 2 * Stats.LABELS.length(), "fresh stats size")
	_assert_eq(stats._totals_and_wins, _zeros(), "fresh stats are zeros")

	# a short save is padded with zeros
	stats.adopt([5, 1])
	_assert_eq(stats._totals_and_wins, [5, 1] + _zeros().slice(2), "short save padded")

	# left number is wins, right number is games played
	_assert_eq(stats._levels[0].text, "    5  H  1    ", "label for Human row")

	# round counting stays inside the array
	stats.record_finished(Player.AI_Level.Human)
	stats.record_win(Player.AI_Level.Human)
	stats.record_finished(Player.AI_Level.Level_5)
	stats.record_win(Player.AI_Level.Level_5)
	_assert_eq(stats._totals_and_wins[0], 6, "human wins")
	_assert_eq(stats._totals_and_wins[1], 2, "human games")
	_assert_eq(stats._totals_and_wins[10], 1, "level 5 wins")
	_assert_eq(stats._totals_and_wins[11], 1, "level 5 games")

	# a save/load round trip preserves the numbers
	var config := ConfigFile.new()
	config.set_value("Gameplay", "totals_and_wins", stats._totals_and_wins)
	_assert_eq(config.save(FILE), OK, "config saved")
	var reloaded := ConfigFile.new()
	_assert_eq(reloaded.load(FILE), OK, "config loaded")
	stats.adopt(reloaded.get_value("Gameplay", "totals_and_wins", []))
	_assert_eq(stats._totals_and_wins, [6, 2, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1], "stats survive a restart")

	# an oversized save that is not the old layout keeps the rows it has
	stats.adopt(range(16).map(func(x): return x))
	_assert_eq(stats._totals_and_wins, range(12), "oversized save truncated")

	# the old layout (a pair per AI_Level entry, Disabled included) is re-indexed
	var legacy: Array = []
	legacy.resize(2 * Player.AI_Level.size())
	legacy[2 * (Player.AI_Level.Human + 1)] = 5
	legacy[2 * (Player.AI_Level.Human + 1) + 1] = 9
	legacy[2 * (Player.AI_Level.Level_4 + 1)] = 3
	legacy[2 * (Player.AI_Level.Level_4 + 1) + 1] = 7
	stats.adopt(legacy)
	_assert_eq(
		stats._totals_and_wins,
		[5, 9, 0, 0, 0, 0, 0, 0, 3, 7, 0, 0],
		"legacy save migrated"
	)

	# reset zeroes everything and asks the app to persist it
	var emitted := [false]
	stats.stats_reset_requested.connect(func() -> void: emitted[0] = true)
	stats._on_reset_button_pressed()
	_assert_eq(stats._totals_and_wins, _zeros(), "reset")
	_assert_eq(emitted[0], true, "reset asks the app to save")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(FILE))

	if _failures.is_empty():
		print("stats persistence: PASS")
	else:
		print("stats persistence: %d FAILURE(S)" % _failures.size())
	get_tree().quit()
