extends Node2D

@export var card_scene: PackedScene

var _players: Array[Player]
var _cur_player: int

@onready var _deck: Deck = $Deck

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	seed(42)
	_players = [$Player0, $Player1, $Player2, $Player3]
	_new_game()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func _new_game() -> void:
	for p in _players:
		p.set_score(0)
	_new_round()
	
	
func _new_round() -> void:
	_cur_player = 0
	_deck.prepare()
	for p in _players:
		await deal_card(p, true)
	begin_turn()


func deal_card(p: Player, initial: bool = false) -> void:
	var card = _deck.pop()
	var c = card_scene.instantiate()
	add_child(c)
	c.position = _deck.position
	var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
	if !initial and p.ai_level == Player.AI_Level.Human:
		tw.tween_property(c, "position", p._drawn_card.global_position, 1)
		c.faceup = true
	else:
		tw.tween_property(c, "position", p.global_position, 1)
		c.faceup = false
	await tw.finished
	if initial:
		p.set_card(card)
	else:
		p.set_drawn_card(card)
	c.queue_free()


func begin_turn():
	var p = _players[_cur_player]
	await deal_card(p)
	
