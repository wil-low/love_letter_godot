class_name Deck
extends Sprite2D

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

var _cards: Array[CardType]
var _left: Array[int]


func prepare() -> void:
	_cards = []
	_left = []
	for i in range(card_count.size()):
		_left.append(card_count[i])
		for j in range(card_count[i]):
			_cards.append(i)
	_cards.shuffle()


func pop() -> CardType:
	return _cards.pop_back()
