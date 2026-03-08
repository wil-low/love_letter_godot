extends Node2D

var _players: Array[Player]
var _cur_player: int = 0

@onready var _deck: Deck = $Deck

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	seed(42)
	_players = [$Player0, $Player1, $Player2, $Player3]
	_new_round()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _new_round() -> void:
	_deck.prepare()
	for p in _players:
		var card = _deck.pop()
		p.set_card(card)
	
