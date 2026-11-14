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

# Noble Family variant, todo §C.28: the save carries ONE KEY PER MODE, so a variant game's counters
# survive a restart as a variant history and a classic game's as a classic one. `Gameplay/totals_and_wins`
# is retired as a write target (it stays a READ target, see `legacy_classic_stats`).
const STATS_SECTION: String = "Stats"
const STATS_CLASSIC_KEY: String = "classic"
const STATS_NOBLE_KEY: String = "noble_family"
const STATS_LEGACY_SECTION: String = "Gameplay"
const STATS_LEGACY_KEY: String = "totals_and_wins"
# The pre-variant save: 6 label rows (H12345) x 2 counters. A table is `2 * AI_Level.size()` == 14, so
# an old save is 2 counters SHORT - see `legacy_classic_stats` for why the gap is tail padding.
const STATS_LEGACY_SIZE: int = 12

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
	# BOTH tables, every save: a save that carried only the table of the mode the last game played
	# would ERASE the other mode's history at the next boot, because `load_config()` rebuilds both
	# tables out of this one file. Writing them per-save is also what makes a write to one mode
	# observable as "the other file content did not change".
	config.set_value(STATS_SECTION, STATS_CLASSIC_KEY, _stats.tables[Stats.MODE_CLASSIC])
	config.set_value(STATS_SECTION, STATS_NOBLE_KEY, _stats.tables[Stats.MODE_NOBLE])
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
	load_stats(config)
	return true


# Noble Family, todo §C.28: read BOTH tables. The pre-variant rule "a save of the wrong length is not
# your history" is KEPT, and it is applied PER TABLE: a corrupt/stale classic table must not delete a
# good noble table (the pre-variant code could only ever drop "the" table, and it dropped it via the
# Reset button, which is a player-facing action - a load path that resets a page is a page that clears
# the player's history as a side effect of booting).
func load_stats(config: ConfigFile) -> void:
	var classic: Array = config.get_value(STATS_SECTION, STATS_CLASSIC_KEY, [])
	var noble: Array = config.get_value(STATS_SECTION, STATS_NOBLE_KEY, [])
	if classic.is_empty() and noble.is_empty():
		# A save from BEFORE the variant has no per-mode key at all. Its history is the classic
		# history - there is no other history it could be - so it migrates to the classic table.
		classic = legacy_classic_stats(config)
	_stats.tables[Stats.MODE_CLASSIC] = _stats.ints_of(classic)
	_stats.tables[Stats.MODE_NOBLE] = _stats.ints_of(noble)
	var counters := 2 * Player.AI_Level.size()  # 14, == STATS_COUNT in the suite
	if _stats.tables[Stats.MODE_CLASSIC].size() != counters:
		_stats.tables[Stats.MODE_CLASSIC] = _stats.empty_table()
	if _stats.tables[Stats.MODE_NOBLE].size() != counters:
		_stats.tables[Stats.MODE_NOBLE] = _stats.empty_table()


# The migration: an old `Gameplay/totals_and_wins` save becomes the classic table. A 12-counter save
# (the pre-variant format) is PADDED TO 14 at the TAIL, because the two slots a table has and such a
# save lacks are the `Disabled` pair: `_on_round_won` writes `2 * level`, `AI_Level.Disabled` is -1, and
# `2 * -1` == -2 == slot 12 of a 14-slot array (Godot counts a negative index from the end). So the
# tail pair is exactly the pair no pre-variant game could ever write, and padding there keeps every
# migrated counter on the index it already had - the migration moves no number, it only adds two zeros.
# Any OTHER length is passed through untouched and dies in `load_stats()`'s per-table size drop: an
# old-format save is migrated, a corrupt one is not.
func legacy_classic_stats(config: ConfigFile) -> Array:
	var legacy: Array = config.get_value(STATS_LEGACY_SECTION, STATS_LEGACY_KEY, [])
	if legacy.size() == STATS_LEGACY_SIZE:
		var padded: Array = legacy.duplicate()
		padded.append(0)
		padded.append(0)
		return padded
	return legacy


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


# Noble Family, todo §C.28: a counter is filed by the mode of the game that ENDED the round
# (`Main.noble_family` is the deal table the game was dealt by, fixed at the deal - step 25), NOT by
# the table the stats page is showing. Step 26 aliased `_totals_and_wins` to `tables[mode]` and step 27
# put the player's own arrows on that `mode`, so a page view was the write target: browse the classic
# table during a variant game, resume, and the variant round filed itself into classic (TEST O's O6
# measured exactly that, and says it is the Check that flips when this lands - it lands here).
func _on_round_won(level: Player.AI_Level) -> void:
	var tab: Array[int] = _stats.tables[_main.noble_family_index()]
	tab[2 * level] = clampi(tab[2 * level] + 1, 0, 99999)


func _on_round_finished(level: Player.AI_Level) -> void:
	var tab: Array[int] = _stats.tables[_main.noble_family_index()]
	tab[2 * level + 1] = clampi(tab[2 * level + 1] + 1, 0, 99999)
