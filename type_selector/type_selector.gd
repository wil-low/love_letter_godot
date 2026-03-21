extends Node2D

signal type_clicked(type: Deck.CardType)
@onready var _type_selection: Sprite2D = $TypeSelection

var _use_modulate = true

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	for c in get_children():
		if c is Card:
			c.input_event.connect(_on_card_input_event.bind(c.type))


func _on_card_input_event(_viewport: Node, event: InputEvent, _shape_idx: int, type: Deck.CardType) -> void:
	if event.is_action_pressed("left_click"):
		print("Card " + str(type))
		type_clicked.emit(type)


func reset_and_show() -> void:
	for c in get_children():
		if c is Card:
			if _use_modulate:
				c.modulate = Color(1, 1, 1, 1)
			else:
				_type_selection.hide()
	show()


func show_selection(type: Deck.CardType) -> void:
	for c in get_children():
		if c is Card:
			if _use_modulate:
				c.modulate = Color(1.0, 1.0, 1.0, 1.0 if c.type == type else 0.25)
			elif c.type == type:
				_type_selection.position = c.position
				_type_selection.show()
