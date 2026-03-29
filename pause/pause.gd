extends Node2D

signal resume_pressed
signal statistics_pressed
signal exit_pressed

func _on_resume_button_pressed() -> void:
	hide()
	resume_pressed.emit()


func _on_statistics_button_pressed() -> void:
	#hide()
	#statistics_pressed.emit()
	pass


func _on_exit_button_pressed() -> void:
	hide()
	exit_pressed.emit()
