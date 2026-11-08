class_name Move
extends RefCounted

var _played_card: Card
var _played_card_idx: int
var _target_player: int
var _target_type: Deck.CardType
var _score: int

# Noble Family variant: a move is a (draw, play, target) triple.
# The draw is decided before the card is drawn, so the pair is described by card
# *types*: _drawn_type is the family card we intend to draw, _leftover_type is the
# other card of the pair (the card kept in hand after the play).
# _drawn_family_idx == -1 means "no family draw" - a classic move.
# _played_card is null when the drawn card is the one being played, in which case
# the played type is _drawn_type (_played_card_idx: 0 = active card, 1 = drawn card).
# _drawn_card is filled in by Main only for the winning move, after the draw animates.
var _drawn_family_idx: int = -1
var _drawn_type: Deck.CardType = Deck.CardType.Unknown
var _leftover_type: Deck.CardType = Deck.CardType.Unknown
var _drawn_card: Card = null

func _init(
		played_card: Card,
		played_card_idx: int = -1,
		target_player: int = -1,
		target_type: Deck.CardType = Deck.CardType.Unknown,
		drawn_family_idx: int = -1,
		drawn_type: Deck.CardType = Deck.CardType.Unknown,
		leftover_type: Deck.CardType = Deck.CardType.Unknown,
		drawn_card: Card = null
) -> void:
	_played_card = played_card
	_played_card_idx = played_card_idx
	_target_player = target_player
	_target_type = target_type
	_drawn_family_idx = drawn_family_idx
	_drawn_type = drawn_type
	_leftover_type = leftover_type
	_drawn_card = drawn_card
	_score = 0


# Type of the card this move plays, available without any Card node.
func played_type() -> Deck.CardType:
	if _played_card != null:
		return _played_card.type
	return _drawn_type


func is_noble() -> bool:
	return _drawn_family_idx != -1


func _to_string() -> String:
	var s: String = "Move score " + str(_score) + ": "
	s += Deck.CardType.keys()[played_type()]
	s +=  " (" + str(_played_card_idx) + ")"
	if _drawn_family_idx != -1:
		s += ", draw " + Deck.CardType.keys()[_drawn_type]
		s += " (#" + str(_drawn_family_idx) + ")"
		s += ", keep " + Deck.CardType.keys()[_leftover_type]
	if _target_player != -1:
		s += ", tgt " + str(_target_player)
	if _target_type != Deck.CardType.Unknown:
		s += ", " + Deck.CardType.keys()[_target_type]
	return s
