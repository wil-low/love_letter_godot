extends Node2D

@onready var _start: Start = $Start
@onready var _game_mode: GameMode = $GameMode
@onready var _main: Main = $Main
@onready var _level_selector: LevelSelector = $LevelSelector
@onready var _stats: Stats = $Stats
@onready var _help: Node2D = $Help
@onready var _pause: Node2D = $Pause

@export var random_seed: int = 0
@export var speed_run: bool = false
@export var print_memory: bool = false
@export var print_valid_moves: bool = false

const OPTIONS_FILE := "user://options.cfg"

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	seed(random_seed if random_seed != 0 else Time.get_ticks_usec())

	var platform := OS.get_name()
	if platform == "Android" or platform == "iOS":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		Engine.print_to_stdout = false

	var levels: Array[Player.AI_Level] = [
		Player.AI_Level.Human,
		Player.AI_Level.Level_4,
		Player.AI_Level.Level_4,
		Player.AI_Level.Level_4
		]

	if speed_run:
		levels = [
			Player.AI_Level.Level_1,
			Player.AI_Level.Level_2,
			Player.AI_Level.Level_3,
			Player.AI_Level.Level_4
			]
			
	for i in _main._players.size():
		_main._players[i].ai_level = levels[i]

	if speed_run:
		for i in AudioServer.bus_count:
			AudioServer.set_bus_mute(i, true)
		Animator._speed = 0
		RenderingServer.render_loop_enabled = false
		Engine.print_to_stdout = false
		_main.round_finished.disconnect(_on_round_finished)
		_main.round_won.disconnect(_on_round_won)
		_main.save_stats.disconnect(save_config)
		_main.init_players(42)
	else:
		load_config()


func save_config() -> void:
	var config = ConfigFile.new()
	for i in _main._players.size():
		config.set_value("AI_Level", "P" + str(i), _main._players[i].ai_level)
	config.set_value("Gameplay", "speed", _level_selector._speed_level.level)
	config.set_value("Gameplay", "totals_and_wins", _stats._totals_and_wins)
	config.save(OPTIONS_FILE)


func load_config() -> bool:
	var config = ConfigFile.new()
	var err = config.load(OPTIONS_FILE)

	# If the file didn't load, ignore it.
	if err != OK:
		return false

	for i in _main._players.size():
		var ai_level = config.get_value("AI_Level", "P" + str(i))
		if ai_level != null:
			_main._players[i].ai_level = ai_level

	var speed = clamp(config.get_value("Gameplay", "speed"), SpeedLevel._min_speed, SpeedLevel._max_speed)
	_level_selector.set_levels(_main._players, speed)
	_stats._totals_and_wins = config.get_value("Gameplay", "totals_and_wins", [])
	# drop stats saved for a previous set of AI levels
	if _stats._totals_and_wins.size() != 2 * Player.AI_Level.size():
		_stats._on_reset_button_pressed()
	return true


func _on_level_selector_levels_changed(levels: Array[Player.AI_Level], speed: int) -> void:
	for i in _main._players.size():
		_main._players[i].ai_level = levels[i]
	Animator._speed = pow(2, speed)
	save_config()
	_start.show()


func _on_main_menu_pressed() -> void:
	_main.get_tree().paused = true
	_main.hide()
	_pause.show()


# Noble Family variant, todo step 25: PLAY no longer starts a game, it opens the mode picker. The
# whole "which mode" decision lives here (`Main.noble_family` is set BEFORE `init_players`, which is
# what reads it in `_new_round`); the picker scene stores nothing, so this file is the only place a
# mode exists.
func _on_start_play_pressed() -> void:
	_start.hide()
	_game_mode.show_rows()


# The body `_on_start_play_pressed()` used to run: the game is only started once a mode is chosen.
func start_game() -> void:
	# Noble Family variant, todo §C.26: the stats page keeps ONE counter table PER mode, and this is the
	# line where a mode exists, so the page follows the game that is starting - a
	# classic game's counters land in the classic table and a variant game's in the noble one, which is
	# the whole "a variant game never adds to a classic game's counters" requirement.
	_stats.mode = Stats.MODE_NOBLE if _main.noble_family else Stats.MODE_CLASSIC
	_main.show()
	_main.init_players(random_seed if random_seed != 0 else Time.get_ticks_usec())


func _on_game_mode_classic() -> void:
	_main.noble_family = false
	start_game()


func _on_game_mode_noble_family() -> void:
	_main.noble_family = true
	start_game()


# BACK is a refusal, not a mode: no game starts, the start page comes back, and no mode is remembered.
func _on_game_mode_back() -> void:
	_start.show()


func _on_start_settings_pressed() -> void:
	_level_selector.show()


func _on_pause_resume_pressed() -> void:
	_main.get_tree().paused = false
	_main.show()


func _on_pause_exit_pressed() -> void:
	_main.interrupted = true
	# The mode is per game and never persisted (todo §C fixed rules), so leaving a game for the menu
	# clears it: the next PLAY must pick a mode again, and the default is classic.
	_main.noble_family = false
	_main.get_tree().paused = false
	_start.show()


func _on_start_stats_pressed() -> void:
	# Step 26: the page keeps one table per mode. Opened from the START page no game is running, and the
	# mode is per game and never persisted, so what a player opens here is the classic history - the
	# numbers the pre-variant game wrote. Step 27 puts a picker on the page itself.
	_stats.mode = Stats.MODE_CLASSIC
	_stats.invoker = _start
	_stats.update_labels()
	_stats.show()


func _on_stats_back_pressed() -> void:
	_stats.invoker.show()


func _on_pause_stats_pressed() -> void:
	# Opened from the PAUSE menu, the page belongs to the game that is running: show THAT game's table.
	_stats.mode = Stats.MODE_NOBLE if _main.noble_family else Stats.MODE_CLASSIC
	_stats.invoker = _pause
	_stats.update_labels()
	_stats.show()


func _on_start_help_pressed() -> void:
	_help.invoker = _start
	_help.show()


func _on_help_back_pressed() -> void:
	_help.invoker.show()


func _on_pause_help_pressed() -> void:
	_help.invoker = _pause
	_help.show()


func _on_round_won(level: Player.AI_Level) -> void:
	_stats._totals_and_wins[2 * level] = clampi(_stats._totals_and_wins[2 * level] + 1, 0, 99999)


func _on_round_finished(level: Player.AI_Level) -> void:
	_stats._totals_and_wins[2 * level + 1] = clampi(_stats._totals_and_wins[2 * level + 1] + 1, 0, 99999)
