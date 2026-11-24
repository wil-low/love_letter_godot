class_name Card
extends Area2D

@onready var _back: Sprite2D = $Back
@onready var _face: Sprite2D = $Face
@onready var _count: Sprite2D = $Count
@onready var _value: Label = $Value
@export var card_type: Deck.CardType


var type: Deck.CardType:
	get:
		return type
	set(value):
		type = value
		_value.text = str(type)
		_face.frame = type
		_face.visible = faceup

		
var faceup: bool:
	get:
		return faceup
	set(value):
		faceup = value
		_back.frame = 0 if faceup else 1
		_face.visible = faceup
		_value.visible = faceup
		_count.visible = faceup


var count: int:
	set(value):
		_count.frame = value


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	type = card_type
	faceup = true
	count = 0
