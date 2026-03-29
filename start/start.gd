class_name Start
extends Node2D

signal play_pressed
signal settings_pressed


func _on_play_button_pressed() -> void:
	hide()
	play_pressed.emit()


func _on_settings_button_pressed() -> void:
	hide()
	settings_pressed.emit()
