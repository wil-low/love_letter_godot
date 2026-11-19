extends Node

const OPTIONS := "user://options.cfg"

const STATS := [6, 2, 1, 1, 0, 0, 0, 0, 3, 7, 2, 2]
const ZEROS := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

var _failures: Array[String] = []
var _backup: String = ""


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("FAIL: ", msg)


func _assert_eq(actual, expected, msg: String) -> void:
	# compare stringified values so that Array[int] and Array compare equally
	if str(actual) != str(expected):
		_fail(msg + " (expected %s, got %s)" % [str(expected), str(actual)])


func _read_options() -> String:
	if not FileAccess.file_exists(OPTIONS):
		return ""
	var file := FileAccess.open(OPTIONS, FileAccess.READ)
	return file.get_as_text()


func _write_options(text: String) -> void:
	var file := FileAccess.open(OPTIONS, FileAccess.WRITE)
	file.store_string(text)


func _saved_stats() -> Array:
	var config := ConfigFile.new()
	if config.load(OPTIONS) != OK:
		return []
	return config.get_value("Gameplay", "totals_and_wins", [])


func _new_app() -> Node2D:
	var app: Node2D = load("res://application/application.tscn").instantiate()
	add_child(app)
	await get_tree().process_frame
	return app


func _ready() -> void:
	_backup = _read_options()

	var app := await _new_app()
	var stats: Stats = app.get_node("Stats")

	# a full board of stats is on disk, and a restart loads it
	stats.adopt(STATS)
	app.save_config()
	_assert_eq(_saved_stats(), STATS, "stats saved")
	var reloaded := await _new_app()
	_assert_eq(reloaded.get_node("Stats")._totals_and_wins, STATS, "stats survive a restart")

	# pressing Reset is written out straight away, not kept in memory only
	stats._on_reset_button_pressed()
	_assert_eq(_saved_stats(), ZEROS, "reset saved to disk")

	# restarting after a Reset shows zeros, not the numbers that were reset
	stats.adopt(STATS)
	app.load_config()
	_assert_eq(stats._totals_and_wins, ZEROS, "reset survives a restart")

	for app_node in [app, reloaded]:
		app_node.get_tree().paused = false
		app_node.queue_free()
	_write_options(_backup)

	if _failures.is_empty():
		print("stats reset: PASS")
	else:
		print("stats reset: %d FAILURE(S)" % _failures.size())
	get_tree().quit()
