class_name Deck
extends Node2D

enum CardType {
	Guard = 0,
	Priest,
	Baron,
	Handmaid,
	Prince,
	King,
	Countess,
	Princess,
	Unknown
}

const card_count = [
	5, # Guard
	2, # Priest
	2, # Baron
	2, # Handmaid
	2, # Prince
	1, # King
	1, # Countess
	1  # Princess
]

const card_names := [
	"Guard   ",
	"Priest  ",
	"Baron   ",
	"Handmaid",
	"Prince  ",
	"King    ",
	"Countess",
	"Princess",
	"Unknown "
]

@onready var _main: Sprite2D = $Main
@onready var _widow: Sprite2D = $Widow
@onready var _card_counter: Sprite2D = $CardCounter

var _cards: Array[CardType]
var _widow_cards: Array[CardType]
var _left: Array[int]


func prepare(player_count: int) -> void:
	_cards = []
	_widow_cards = []
	update_piles()
	_left = []
	for i in range(card_count.size()):
		_left.append(card_count[i])
		for j in range(card_count[i]):
			_cards.append(i)
	_cards.shuffle()
	#while len(_cards) > 6:
	#	_cards.pop_front()
	var widow_count = 1 if player_count != 2 else 3
	for i in range(widow_count):
		_widow_cards.append(_cards.pop_front())
	update_piles()


func pop(allow_widow: bool) -> Dictionary:
	# result = { type: CardType, src: Sprite2D }
	if !_cards.is_empty():
		return { "type": _cards.pop_front(), "src": _main }
	elif allow_widow and !_widow_cards.is_empty():
		return { "type": _widow_cards.pop_front(), "src": _widow }
	return {}


func update_piles() -> void:
	_main.visible = !_cards.is_empty()
	_widow.visible = !_widow_cards.is_empty()
	#_card_counter.visible = len(_cards) > 0 and len(_cards) < 5
	#if _card_counter.visible:
	#	_card_counter.frame = len(_cards)
