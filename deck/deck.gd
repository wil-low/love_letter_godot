class_name Deck
extends Node2D

enum CardType {
	Assassin = 0,
	Guard,
	Priest,
	Baron,
	Handmaid,
	Prince,
	King,
	Countess,
	Princess,
	Queen,
	Unknown
}

const MIN_HIGH_RANK := 5  # Prince, King, Countess, Princess - the Countess rule threshold


static func rank(t: CardType) -> int:
	# Guard..Princess are ranked 1..8, Unknown has no rank
	return t if t < CardType.Unknown else -1


const _card_count_2_4 = [
	0, # Assassin
	5, # Guard
	2, # Priest
	2, # Baron
	2, # Handmaid
	2, # Prince
	1, # King
	1, # Countess
	1,  # Princess
	0,  # Queen
]

const _card_count_5 = [
	0, # Assassin
	5, # Guard
	3, # Priest
	3, # Baron
	3, # Handmaid
	3, # Prince
	1, # King
	1, # Countess
	1,  # Princess
	0,  # Queen
]

const _card_count_6 = [
	0, # Assassin
	7, # Guard
	3, # Priest
	3, # Baron
	3, # Handmaid
	3, # Prince
	2, # King
	1, # Countess
	1,  # Princess
	0,  # Queen
]


const card_names := [
	"Assassin",
	"Guard   ",
	"Priest  ",
	"Baron   ",
	"Handmaid",
	"Prince  ",
	"King    ",
	"Countess",
	"Princess",
	"Princess",
	"Unknown "
]

@onready var _main: Sprite2D = $Main
@onready var _widow: Sprite2D = $Widow
@onready var _card_counter: Sprite2D = $CardCounter

var card_count = []
var _cards: Array[CardType]
var _widow_cards: Array[CardType]
var _left: Array[int]


func prepare(player_count: int) -> void:
	if player_count <= 4:
		card_count = _card_count_2_4
	elif player_count == 5:
		card_count = _card_count_5
	elif player_count == 6:
		card_count = _card_count_6
	_cards = []
	_widow_cards = []
	update_piles()
	_left = []
	for i in card_count.size():
		_left.append(card_count[i])
		for j in range(card_count[i]):
			_cards.append(i)
	_cards.shuffle()
	#while len(_cards) > 6:
	#	_cards.pop_front()
	var widow_count = 1 if player_count != 2 else 3
	for i in widow_count:
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
