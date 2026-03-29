class_name LevelSelector
extends Node2D

signal ai_levels_changed(levels: Array[Player.AI_Level])


func _ready() -> void:
	pass


func _on_back_button_pressed() -> void:
	var result: Array[Player.AI_Level]
	result.resize(4)
	var player_count := 0
	for p in get_children():
		if p is PlayerLevel:
			result[p.player_num] = p.ai_level
			if p.ai_level != Player.AI_Level.Disabled:
				player_count += 1
	if player_count > 1:
		ai_levels_changed.emit(result)
	else:
		print("Too few players")
