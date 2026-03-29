class_name LevelSelector
extends Node2D

signal ai_levels_changed(levels: Array[Player.AI_Level])

@onready var _levels: Node2D = $Levels


func set_levels(arr: Array[Player.AI_Level]) -> void:
	for i in range(len(arr)):
		_levels.get_child(i).ai_level = arr[i]


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
		ai_levels_changed.emit(result)
	else:
		print("Too few players")
