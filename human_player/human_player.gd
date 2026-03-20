extends Player

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	super()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	get_input()


func get_input() -> void:
	pass


func drawn_card_position() -> Vector2:
	return Vector2(global_position.x + hand.get_child_count() * 16, global_position.y)


func add_card(card: Card) -> void:
	super(card)
	card.input_event.connect(_on_card_input_event.bind(hand.get_child_count() - 1))



func _on_card_input_event(viewport: Node, event: InputEvent, shape_idx: int, idx: int) -> void:
	match _state:
		State.SELECT_CARD:
			if event.is_action_pressed("left_click"):
				print("click " + str(idx))
				var c = hand.get_child(idx)
				hand.remove_child(c)
				if hand.get_child_count() == 1:
					var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
					tw.tween_property(hand.get_child(0), "global_position", global_position, get_parent().animation_speed / 2)
				card_played.emit(c)
