extends Node2D

@onready var _start: Start = $Start
@onready var _main: Main = $Main
@onready var _level_selector: LevelSelector = $LevelSelector
@onready var _pause: Node2D = $Pause


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var platform := OS.get_name()
	if platform == "Android" or platform == "iOS":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	var levels: Array[Player.AI_Level] = [
		Player.AI_Level.Human,
		Player.AI_Level.Level_4,
		Player.AI_Level.Level_4,
		Player.AI_Level.Level_4
		]
	_level_selector.set_levels(levels, 2)
	_level_selector._on_back_button_pressed()


func _on_level_selector_levels_changed(levels: Array[Player.AI_Level], speed: int) -> void:
	for i in range(len(_main._players)):
		_main._players[i].ai_level = levels[i]
	Animator._speed = speed
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
