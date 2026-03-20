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

var _cards: Array[CardType]

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	prepare()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func prepare() -> void:
	_cards = []
	for i in range(card_count.size()):
		for j in range(card_count[i]):
			_cards.append(i)
	_cards.shuffle()


func pop() -> CardType:
	return _cards.pop_back()
