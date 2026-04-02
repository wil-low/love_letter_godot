class_name LevelSelector
extends Node2D

signal levels_changed(levels: Array[Player.AI_Level], speed: int)

@onready var _levels: Node2D = $Levels
@onready var _speed_level: Node2D = $SpeedLevel


func set_levels(arr: Array[Player], speed: int) -> void:
	for i in range(len(arr)):
		_levels.get_child(i).ai_level = arr[i].ai_level
	_speed_level.level = speed


func _on_back_button_pressed() -> void:
	var result: Array[Player.AI_Level]
	result.resize(4)
	var player_count := 0
	for level in _levels.get_children():
		result[level.player_num] = level.ai_level
		if level.ai_level != Player.AI_Level.Disabled:
			player_count += 1
	if player_count > 1:
		hide()
		levels_changed.emit(result, _speed_level.level)
	else:
		print("Too few players")
