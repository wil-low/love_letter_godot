class_name Move
extends RefCounted

var _played_card: Card
var _played_card_idx: int
var _target_player: int
var _target_type: Deck.CardType
var _score: int

func _init(played_card: Card, played_card_idx: int = -1, target_player: int = -1, target_type: Deck.CardType = Deck.CardType.Unknown) -> void:
	_played_card = played_card
	_played_card_idx = played_card_idx
	_target_player = target_player
	_target_type = target_type
	_score = 0


func _to_string() -> String:
	var s: String = "Move score " + str(_score) + ": "
	s += Deck.CardType.keys()[_played_card.type]
	s +=  " (" + str(_played_card_idx) + ")"
	if _target_player != -1:
		s += ", tgt " + str(_target_player)
	if _target_type != Deck.CardType.Unknown:
		s += ", " + Deck.CardType.keys()[_target_type]
	return s
