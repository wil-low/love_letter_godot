extends Node2D

signal type_clicked(type: Deck.CardType)
@onready var _selection: Sprite2D = $Selection

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	for c in get_children():
		if c is Card:
			c.input_event.connect(_on_card_input_event.bind(c.type))


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func _on_card_input_event(viewport: Node, event: InputEvent, shape_idx: int, type: Deck.CardType) -> void:
	if event.is_action_pressed("left_click"):
		print("Card " + str(type))
		type_clicked.emit(type)


func show_selection(type: Deck.CardType) -> void:
	for c in get_children():
		if c is Card and c.type == type:
			_selection.position = c.position
			_selection.show()
