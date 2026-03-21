class_name Move
extends RefCounted

var _played_type: Deck.CardType
var _played_card_idx: int
var _target_player: int
var _target_type: Deck.CardType

func _init() -> void:
	init(Deck.CardType.Unknown)


func init(played_type: Deck.CardType, played_card_idx: int = -1, target_player: int = -1, target_type: Deck.CardType = Deck.CardType.Unknown) -> Move:
	_played_type = played_type
	_played_card_idx = played_card_idx
	_target_player = target_player
	_target_type = target_type
	return self

func _to_string() -> String:
	var s: String = "Move: "
	s += Deck.CardType.keys()[_played_type] + ", "
	s += str(_played_card_idx) + ", "
	s += str(_target_player) + ", "
	s += Deck.CardType.keys()[_target_type]
	return s
