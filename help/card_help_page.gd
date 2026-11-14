@tool
extends Node2D

@onready var _card: Sprite2D = $Card
@onready var _name: Label = $Name
@onready var _description: Label = $Description

@export var card_type: Deck.CardType = Deck.CardType.Unknown:
	set(value):
		card_type = value
		if Engine.is_editor_hint() and _card != null:
			_card.frame = card_type

# Noble Family, todo §C.29: a page tag, set in the editor. `help.gd` hides every `variant_only`
# page while a variant game is not active, so the 4 Noble Family pages are the ONLY pages a
# classic game never shows, and a classic page can never be hidden by a variant game (the tag is
# false on all 17 of them). It carries no behaviour of its own - it is data the page list reads.
@export var variant_only: bool = false

@export var show_card: bool = true:
	set(value):
		show_card = value
		if Engine.is_editor_hint() and _card != null:
			_card.visible = show_card

@export var card_name: String:
	set(value):
		card_name = value
		if Engine.is_editor_hint() and _name != null:
			_name.text = card_name

@export_custom(PROPERTY_HINT_MULTILINE_TEXT, "") var card_description: String:
	set(value):
		card_description = value
		if Engine.is_editor_hint() and _description != null:
			_description.text = card_description


func _ready() -> void:
	_card.frame = card_type
	_card.visible = show_card
	_name.text = card_name
	_description.text = card_description
