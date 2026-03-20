class_name Main
extends Node2D

@export var card_scene: PackedScene
@export var animation_speed: float = 1

var _players: Array[Player]
var _cur_player: int

@onready var _deck: Deck = $Deck
@onready var _table_card_1: Marker2D = $TableCard1
@onready var _table_card_2: Marker2D = $TableCard2


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	seed(42)
	_players = [$HumanPlayer, $Player1, $Player2, $Player3]
	_new_game()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	get_input()


func get_input() -> void:
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


func animate_card_move(card_type: Deck.CardType, is_faceup: bool, from: Vector2, to: Vector2) -> Card:
	var c = card_scene.instantiate()
	add_child(c)
	c.type = card_type
	c.faceup = is_faceup
	c.global_position = from
	c.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
	tw.tween_property(c, "global_position", to, animation_speed)
	await tw.finished
	return c


func deal_card(p: Player, initial: bool = false) -> void:
	var card = _deck.pop()
	var is_faceup = !initial and p.ai_level == Player.AI_Level.Human
	var c = await animate_card_move(
		card, is_faceup,
		_deck.global_position,
		p._drawn_card.global_position if is_faceup else p.global_position)
	if initial:
		p.set_card(card)
	else:
		p.set_drawn_card(card)
	c.faceup = is_faceup
	c.queue_free()


func begin_turn():
	var p = _players[_cur_player]
	await deal_card(p)
	p._state = Player.State.SELECT_CARD


func _on_card_played(card: Card) -> void:
	animate_card_move(card.type, true, card.global_position, _table_card_1.global_position)
	_players[_cur_player]._state = Player.State.IDLE
	pass # Replace with function body.
