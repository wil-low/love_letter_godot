class_name Card
extends Area2D

@onready var _sprite: Sprite2D = $Sprite
@export var card_type: Deck.CardType

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
	type = card_type
	faceup = true


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


#func _input(event):
#	if event.is_action_pressed("debug_show_hands"):
#		flip(!faceup, 0.2)


func flip(to_faceup: bool, speed: float) -> void:
	if faceup != to_faceup:
		var pos = position
		var width = self._sprite.get_rect().size.x
		var tw = create_tween().set_trans(Tween.TRANS_SINE)
		tw.tween_property(self, "position:x", pos.x + width / 2, speed)
		tw.parallel().tween_property(self, "scale:x", 0, speed)
		tw.tween_callback(func (): faceup = to_faceup)
		tw.tween_property(self, "scale:x", 1, speed)
		tw.parallel().tween_property(self, "position:x", pos.x, speed)
		await tw.finished
		position = pos
