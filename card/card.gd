class_name Card
extends Area2D

@onready var _sprite: Sprite2D = $Sprite

var type: Deck.CardType:
	get:
		return type
	set(value):
		type = value
		_sprite.frame = type if faceup else 8

		
var faceup: bool:
	get:
		return faceup
	set(value):
		faceup = value
		_sprite.frame = type if faceup else 8


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
