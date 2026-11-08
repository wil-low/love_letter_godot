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

const NOBLE_BURN := [
	0, # unused
	0, # unused
	3, # 2 players burned into the widow
	1, # 3 players
	0  # 4 players - no widow pile exists
]

const NOBLE_FAMILY_SIZE := [
	0, # unused
	0, # unused
	5, # family cards per seat, 2 players
	4, # 3 players
	3  # 4 players
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
var first_hand: Array[CardType] = []


func _build_deck() -> void:
	_cards = []
	_widow_cards = []
	first_hand = []
	update_piles()
	_left = []
	for i in card_count.size():
		_left.append(card_count[i])
		for j in range(card_count[i]):
			_cards.append(i)
	_cards.shuffle()
	#while len(_cards) > 6:
	#	_cards.pop_front()


func prepare(player_count: int) -> void:
	_build_deck()
	var widow_count = 1 if player_count != 2 else 3
	for i in widow_count:
		_widow_cards.append(_cards.pop_front())
	update_piles()


# Noble Family deal: burn 3/1/0 (2p/3p/4p) into the widow, then 1 first-hand card
# per seat, then NOBLE_FAMILY_SIZE per seat, round-robin, in as-dealt order.
# Leftovers (1/0/0) stay in the main pile. `_left` stays at full counts: burning,
# first-hand and family cards are not out of play, they are only out of the main pile.
# Returns per-seat family arrays (each one an Array[CardType], in as-dealt order);
# the first-hand cards are in `first_hand`. The outer Array cannot be typed -
# GDScript 4 rejects nested typed collections.
func prepare_noble(player_count: int) -> Array:
	assert(player_count >= 2 and player_count <= 4)
	var burn: int = NOBLE_BURN[player_count]
	var family_size: int = NOBLE_FAMILY_SIZE[player_count]
	var total: int = 0
	for n in card_count:
		total += n
	assert(burn + player_count * (1 + family_size) <= total)
	_build_deck()
	var families: Array = []
	for i in player_count:
		var seat_family: Array[CardType] = []
		families.append(seat_family)
	for _n in burn:
		_widow_cards.append(_cards.pop_front())
	for _n in player_count:
		first_hand.append(_cards.pop_front())
	for _c in family_size:
		for i in player_count:
			families[i].append(_cards.pop_front())
	update_piles()
	return families


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
