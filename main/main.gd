class_name Main
extends Node2D

@export var card_scene: PackedScene
@export var animation_speed: float = 1

var _players: Array[Player]
var _cur_player: int:
	get:
		return _cur_player
	set(value):
		_players[_cur_player].score_digit.modulate = Color(1.0, 1.0, 1.0)
		_cur_player = value


@onready var _deck: Deck = $Table/Deck
@onready var _marker_0: Marker2D = $Table/Marker0
@onready var _marker_1: Marker2D = $Table/Marker1
@onready var _player_selection: Sprite2D = $PlayerSelection
@onready var _table: Node2D = $Table
@onready var _type_selector: Node2D = $TypeSelector
@onready var _discard_marker: Marker2D = $DiscardMarker

var _played_type: Deck.CardType

var _target_player: int:
	get:
		return _target_player
	set(value):
		_target_player = value
		_player_selection.visible = value != -1
		if _player_selection.visible:
			_player_selection.position = _players[_target_player].position
		
var _target_type: int

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	seed(42)
	_players = [$HumanPlayer, $Player1, $Player2, $Player3]
	for p in _players:
		p.player_clicked.connect(_on_player_clicked)
	_new_game()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _input(event):
	if event.is_action_pressed("debug_show_hands"):
		for p in _players:
			var s = str(p.idx) + ":"
			for ch in p.hand.get_children():
				s += " " + Deck.CardType.keys()[ch.type]
			print(s)
	if event.is_action_pressed("debug_reset_game"):
		_new_game()


func _new_game() -> void:
	for p in _players:
		p.clear_hand()
		p.protected = false
		p.active = true
		p.set_score(0)
	discard()
	_new_round()
	
	
func _new_round() -> void:
	_cur_player = 0
	_deck.prepare()
	for p in _players:
		await deal_card(p, true)
	new_turn()


func animate_card_move(card_type: Deck.CardType, new_parent: Node2D, is_faceup: bool, from: Vector2, to: Vector2) -> Card:
	var c = card_scene.instantiate()
	new_parent.add_child(c)
	c.type = card_type
	c.faceup = is_faceup
	c.global_position = from
	c.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
	tw.tween_property(c, "global_position", to, animation_speed)
	await tw.finished
	c.z_index = 0
	return c


func deal_card(p: Player, initial: bool = false) -> void:
	var card = _deck.pop()
	var is_faceup = p.ai_level == Player.AI_Level.Human
	var c = await animate_card_move(
		card, self, is_faceup,
		_deck.global_position,
		p.drawn_card_position())
	remove_child(c)
	p.add_card(c)


func new_turn():
	_target_player = -1
	_target_type = -1
	var p = _players[_cur_player]
	await deal_card(p)
	p.score_digit.modulate = Color(1.0, 0.337, 1.0)
	p._state = Player.State.SELECT_CARD


func _on_card_played(card: Card) -> void:
	var c = await animate_card_move(card.type, _table, true, card.global_position, _marker_0.global_position)
	_played_type = c.type
	var p = _players[_cur_player]
	var next_state = Player.State.IDLE
	match _played_type:
		Deck.CardType.Guard:
			next_state = Player.State.INPUT_OTHER_P
			print("Guard: select other player")
		Deck.CardType.Handmaid:
			resolve_effect()
			
	p._state = next_state
	#if next_state == Player.State.IDLE:
	#	_cur_player

func _on_player_clicked(idx: int) -> void:
	if _players[idx].active and !_players[idx].protected:
		var p = _players[_cur_player]
		match p._state:
			Player.State.INPUT_OTHER_P:
				if _cur_player != idx:
					_target_player = idx
					if _played_type == Deck.CardType.Guard:
						p._state = Player.State.INPUT_T
						_table.hide()
						_type_selector.show()
			Player.State.INPUT_ANY_P:
				_target_player = idx


func _on_type_selector_type_clicked(type: Deck.CardType) -> void:
	_table.show()
	_type_selector.hide()
	_target_type = type
	resolve_effect()


func resolve_effect() -> void:
	var p = _players[_cur_player]
	p._state = Player.State.IDLE
	print("resolve_effect for " + 
		Deck.CardType.keys()[_played_type] +
		", player " + str(_target_player) + 
		", type " + Deck.CardType.keys()[_target_type])

	match _played_type:
		Deck.CardType.Guard:
			_players[_target_player].active = _players[_target_player].hand.get_child(0).type != _target_type
		Deck.CardType.Handmaid:
			p.protected = true
			print("Handmaid: protected on")

	_player_selection.hide()
	discard()
	if !round_over():
		_cur_player = (_cur_player + 1) % len(_players)
		while !_players[_cur_player].active:
			_cur_player = (_cur_player + 1) % len(_players)
		new_turn()


func discard() -> void:
	for ch in _table.get_children():
		if ch is Card:
			ch.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
			var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
			tw.tween_property(ch, "global_position", _discard_marker.global_position, animation_speed)
			await tw.finished
			ch.queue_free()


func round_over() -> bool:
	var active_count := 0
	for p in _players:
		if p.active:
			active_count += 1
	if active_count == 1:
		print("Round over")
		return true
	return false
