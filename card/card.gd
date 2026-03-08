class_name Card
extends Sprite2D

var _type: Deck.CardType
var faceup: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func set_type(type: Deck.CardType) -> void:
	_type = type
	if faceup:
		frame = _type
		
