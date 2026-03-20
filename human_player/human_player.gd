extends Player

@onready var _drawn_card: Card = $DrawnCard

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	super()
	_card.faceup = true
	_drawn_card.faceup = true


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	get_input()


func get_input() -> void:
	pass


func set_drawn_card(type: Deck.CardType) -> void:
	_drawn_card.type = type
	_drawn_card.show()


func _on_card_input_event(viewport: Node, event: InputEvent, shape_idx: int, is_drawn: bool) -> void:
	match _state:
		State.SELECT_CARD:
			if event.is_action_pressed("left_click"):
				var c = _drawn_card if is_drawn else _card
				card_played.emit(c)
				c.hide()


func _on_drawn_card_input_event(viewport: Node, event: InputEvent, shape_idx: int, extra_arg_0: bool) -> void:
	pass # Replace with function body.
