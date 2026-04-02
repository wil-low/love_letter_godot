extends Node2D

@onready var _start: Start = $Start
@onready var _main: Main = $Main
@onready var _level_selector: LevelSelector = $LevelSelector
@onready var _help: Node2D = $Help
@onready var _pause: Node2D = $Pause

@export var random_seed: int = 0
@export var speed_run: bool = false

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
		seed(42)
		levels = [
			Player.AI_Level.Level_1,
			Player.AI_Level.Level_2,
			Player.AI_Level.Level_3,
			Player.AI_Level.Level_4
			]
			
	for i in range(4):
		_main._players[i].ai_level = levels[i]

	if speed_run:
		for i in range(AudioServer.bus_count):
			AudioServer.set_bus_mute(i, true)
		Animator._speed = 0
		RenderingServer.render_loop_enabled = false
		Engine.print_to_stdout = false
		_main.init_players()
	else:
		load_config()
		_level_selector.set_levels(_main._players, Animator._speed)


func save_config() -> void:
	var config = ConfigFile.new()
	for i in range(4):
		config.set_value("AI_Level", "P" + str(i), _main._players[i].ai_level)
	config.set_value("Gameplay", "speed", Animator._speed)
	config.save(OPTIONS_FILE)


func load_config() -> bool:
	var config = ConfigFile.new()
	var err = config.load(OPTIONS_FILE)

	# If the file didn't load, ignore it.
	if err != OK:
		return false

	for i in range(4):
		var ai_level = config.get_value("AI_Level", "P" + str(i))
		if ai_level != null:
			_main._players[i].ai_level = ai_level
			
	var speed = config.get_value("Gameplay", "speed")
	if speed != null:
		Animator._speed = speed
	return true


func _on_level_selector_levels_changed(levels: Array[Player.AI_Level], speed: int) -> void:
	for i in range(len(_main._players)):
		_main._players[i].ai_level = levels[i]
	Animator._speed = speed
	save_config()
	_start.show()


func _on_main_menu_pressed() -> void:
	_main.get_tree().paused = true
	_main.hide()
	_pause.show()


func _on_start_play_pressed() -> void:
	_main.show()
	_main.init_players()


func _on_start_settings_pressed() -> void:
	_level_selector.show()


func _on_pause_resume_pressed() -> void:
	_main.get_tree().paused = false
	_main.show()


func _on_pause_exit_pressed() -> void:
	_main.interrupted = true
	_main.get_tree().paused = false
	_start.show()


func _on_start_help_pressed() -> void:
	_help.invoker = _start
	_help.show()


func _on_help_back_pressed() -> void:
	_help.invoker.show()


func _on_pause_help_pressed() -> void:
	_help.invoker = _pause
	_help.show()
