class_name Main
extends Node2D

@export var card_scene: PackedScene
@export var animation_speed: float = 1
@export var random_seed: int = 42

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
@onready var _round_over_button: TextureButton = $RoundOver
@onready var _game_over_button: TextureButton = $GameOver

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
	seed(random_seed if random_seed != 0 else Time.get_ticks_usec())
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
		p.score = 0
	_new_round()
	
	
func _new_round() -> void:
	_cur_player = 0
	for p in _players:
		await discard(p.hand, 0.2)
		p.protected = false
		p.active = true
	discard(_table)
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
	if len(_deck._cards) > 1:
		var p = _players[_cur_player]
		await deal_card(p)
		p.score_digit.modulate = Color(1.0, 0.337, 1.0)
		p._state = Player.State.SELECT_CARD
	else:
		round_over()


func _on_card_played(card: Card) -> void:
	var c = await animate_card_move(card.type, _table, true, card.global_position, _marker_0.global_position)
	_played_type = c.type
	var p = _players[_cur_player]
	var next_state = Player.State.IDLE
	match _played_type:
		Deck.CardType.Guard, Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
			next_state = Player.State.INPUT_OTHER_P
			print("Select another player")
		Deck.CardType.Prince:
			next_state = Player.State.INPUT_ANY_P
			print("Select any player")
		Deck.CardType.Handmaid, Deck.CardType.Countess, Deck.CardType.Princess:
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
					match _played_type:
						Deck.CardType.Guard:
							p._state = Player.State.INPUT_T
							_table.hide()
							_type_selector.show()
						Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
							resolve_effect()
			Player.State.INPUT_ANY_P:
				_target_player = idx
				resolve_effect()


func _on_type_selector_type_clicked(type: Deck.CardType) -> void:
	_table.show()
	_type_selector.hide()
	_target_type = type
	resolve_effect()


func resolve_effect() -> void:
	var p = _players[_cur_player]
	var tp = _players[_target_player]
	p._state = Player.State.IDLE
	print("resolve_effect for " + 
		Deck.CardType.keys()[_played_type] +
		", player " + str(_target_player) + 
		", type " + Deck.CardType.keys()[_target_type])

	_player_selection.hide()

	match _played_type:
		
		Deck.CardType.Guard:
			tp.active = tp.hand.get_child(0).type != _target_type
		Deck.CardType.Priest:
			await tp.reveal_hand(animation_speed)
			print("Priest: reveal hand")
		Deck.CardType.Baron:
			await tp.reveal_hand(animation_speed)
			var my_type = p.hand.get_child(0).type
			var their_type = tp.hand.get_child(0).type
			if my_type > their_type:
				tp.active = false
			elif my_type < their_type:
				p.active = false
			print("Baron: compare cards")
		Deck.CardType.Handmaid:
			p.protected = true
			print("Handmaid: protected on")
		Deck.CardType.Prince:
			var type = tp.hand.get_child(0).type
			discard(tp.hand)
			if type == Deck.CardType.Princess:
				tp.active = false
			else:
				deal_card(tp)
			print("Prince: discard and redraw")
		Deck.CardType.King:
			var my_card: Card = p.hand.get_child(0)
			var their_card: Card = tp.hand.get_child(0)
			my_card.faceup = tp.ai_level == Player.AI_Level.Human
			their_card.faceup = p.ai_level == Player.AI_Level.Human
			var my_hand = p.hand
			var their_hand = tp.hand
			var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
			tw.tween_property(my_card, "global_position", tp.global_position,
				animation_speed)
			tw.tween_property(their_card, "global_position", p.global_position,
				animation_speed)
			my_hand.remove_child(my_card)
			their_hand.remove_child(their_card)
			p.add_card(their_card)
			tp.add_card(my_card)
			await tw.finished
			print("King: trade hands")
		Deck.CardType.Princess:
			p.active = false
			print("Princess: discarded")

	await discard(_table)
	var active_count := 0
	for pl in _players:
		if pl.active:
			active_count += 1
	if active_count == 1:
		round_over()
	else:
		#_cur_player = (_cur_player + 1) % len(_players)
		#while !_players[_cur_player].active:
		#	_cur_player = (_cur_player + 1) % len(_players)
		new_turn()


func discard(from: Node, speed_multiplier: float = 1) -> void:
	var for_discard: Array[Card]
	for ch in from.get_children():
		if ch is Card:
			for_discard.append(ch)
	for ch in for_discard:
		ch.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
		var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
		tw.tween_property(ch, "global_position", _discard_marker.global_position,
			animation_speed * speed_multiplier)
		await tw.finished
		from.remove_child(ch)
		ch.queue_free()


func round_over() -> void:
	print("Round over! Update scores")
	var max_type := 0
	for p in _players:
		if p.active:
			p.reveal_hand(animation_speed, false)
			max_type = max(max_type, p.hand.get_child(0).type)
	var round_winners := ""
	var game_winners := ""
	for p in _players:
		if p.active and p.hand.get_child(0).type == max_type:
			p.score += 1
			if !round_winners.is_empty():
				round_winners += ", "
			round_winners += str(p.idx)
			if p.score >= 4:
				if !game_winners.is_empty():
					game_winners += ", "
				game_winners += str(p.idx)
	if !game_winners.is_empty():
		print("Game over! Winners are " + game_winners)
		_game_over_button.show()
	elif !round_winners.is_empty():
		print("Round over! Winners are " + round_winners)
		_round_over_button.show()


func _on_round_over_pressed() -> void:
	_round_over_button.hide()
	_new_round()


func _on_game_over_pressed() -> void:
	_game_over_button.hide()
	_new_game()
