class_name Main
extends Node2D

@export var card_scene: PackedScene
@export var random_seed: int = 42

const max_score: int = 4
const max_games: int = 1000

var game_counter: int = 0

var _players: Array[Player]
var _cur_player: int:
	get:
		return _cur_player
	set(value):
		_players[_cur_player].current_mark.hide()
		_cur_player = value


@onready var _deck: Deck = $Table/Deck
@onready var _marker_0: Marker2D = $Table/Marker0
@onready var _player_selection: Sprite2D = $PlayerSelection
@onready var _table: Node2D = $Table
@onready var _type_selector: Node2D = $TypeSelector
@onready var _discard_marker: Marker2D = $DiscardMarker
@onready var _round_over_button: TextureButton = $RoundOver
@onready var _game_over_button: TextureButton = $GameOver
@onready var _select_other_player: TextureButton = $SelectOtherPlayer
@onready var _select_any_player: TextureButton = $SelectAnyPlayer

var _other_protected: bool

var _played_card: Deck.CardType

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
	if Animator._speed == 0: # speedrun
		RenderingServer.render_loop_enabled = false
		Engine.print_to_stdout = false
	seed(random_seed if random_seed != 0 else Time.get_ticks_usec())
	_players = [$Player0, $Player1, $Player2, $Player3]
	for p in _players:
		assert(p.idx == 0 or !p.is_human(), "Human is allowed for Player 0 only")
		if p.is_human():
			p.card_played.connect(_on_card_played)
		else:
			p.move_chosen.connect(_on_move_chosen)
		p.target_player_selected.connect(_on_target_player_selected)
	_new_game()


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
	game_counter += 1
	if game_counter > max_games:
		push_warning("Max games count reached, stop")
	else:
		print("\n\nNew game " + str(game_counter))
		for p in _players:
			p.score = 0
		_new_round()
	
	
func _new_round() -> void:
	_select_other_player.hide()
	_select_any_player.hide()
	_cur_player = 0
	for p in _players:
		p.protected = false
		p.active = true
		for i in range(len(p._memory)):
			p.update_memory(i)
	discard(_table)
	for p in _players:
		await discard(p.hand)
	_deck.prepare()
	for p in _players:
		await deal_card(p)
	new_turn()


func animate_card_move(c: Card, new_parent: Node2D, is_faceup: bool, from: Vector2, to: Vector2) -> Card:
	new_parent.add_child(c)
	c.faceup = is_faceup
	c.global_position = from
	c.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	await Animator.move_card(c, to)
	c.z_index = 0
	return c


func deal_card(p: Player) -> void:
	var card_type = _deck.pop()
	var is_faceup = p.is_human()
	var c = card_scene.instantiate()
	add_child(c)
	c.type = card_type
	c.global_position = _deck.global_position
	remove_child(c)
	await animate_card_move(
		c, self, is_faceup,
		_deck.global_position,
		p.drawn_card_position())
	remove_child(c)
	p.add_card(c)


func new_turn():
	print("\nnew_turn for Player " + str(_cur_player))
	for p in _players:
		p.print_memory()
	var p = _players[_cur_player]
	p.protected = false
	_other_protected = true
	for pl in _players:
		if pl.active and !pl.protected and pl.idx != _cur_player:
			_other_protected = false
	_target_player = -1
	_target_type = Deck.CardType.Unknown
	if len(_deck._cards) > 1:
		await deal_card(p)
		#_players[_cur_player].hand.get_child(0).type = Deck.CardType.Baron
		#_players[_cur_player].hand.get_child(1).type = Deck.CardType.King
		p.current_mark.show()
		if p.is_human():
			var valid_moves = find_valid_moves()
			p.eval_moves(valid_moves)
			for m in valid_moves:
				print("\t" + str(m))
			p._state = Player.State.SELECT_CARD
		else:
			var valid_moves = find_valid_moves()
			p.ai_move(valid_moves)
	else:
		round_over()


func _on_card_played(card: Card) -> void:
	await animate_card_move(card, _table, true, card.global_position, _marker_0.global_position)
	_played_card = card.type
	for p in _players:
		if p.idx != _cur_player and p._memory[_cur_player] == _played_card:
			p.update_memory(_cur_player)  # played card is not in hand anymore
	var st := Player.State.IDLE
	match card.type:
		Deck.CardType.Guard, Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
			st = Player.State.INPUT_OTHER_P
		Deck.CardType.Prince:
			st = Player.State.INPUT_ANY_P
	var p = _players[_cur_player]
	p._state = st
	if p.is_human():
		_select_other_player.visible = p._state == Player.State.INPUT_OTHER_P
		_select_any_player.visible = p._state == Player.State.INPUT_ANY_P
	if p._state == Player.State.IDLE:
		await Animator.delay(1)
		resolve_effect()


func _on_target_player_selected(idx: int) -> void:
	if _players[idx].active:
		var p = _players[_cur_player]
		match p._state:
			Player.State.INPUT_OTHER_P:
				if _cur_player != idx and (!_players[idx].protected or _other_protected):
					_target_player = idx
					_select_other_player.hide()
					match _played_card:
						Deck.CardType.Guard:
							p._state = Player.State.INPUT_T
							_table.hide()
							_type_selector.set_selection(Deck.CardType.Unknown)
							_type_selector.show()
						Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
							resolve_effect()
			Player.State.INPUT_ANY_P:
				if !_players[idx].protected:
					_target_player = idx
					_select_any_player.hide()
					resolve_effect()


func _on_target_type_selected(type: Deck.CardType) -> void:
	_type_selector.set_selection(type)
	await Animator.delay(1)
	_table.show()
	_type_selector.hide()
	_target_type = type
	resolve_effect()


func _on_move_chosen(move: Move) -> void:
	await Animator.delay(1)
	print("My " + str(move))
	_on_card_played(move._played_card)
	if move._target_player != -1:
		await Animator.delay(1)
		_on_target_player_selected(move._target_player)
	if move._target_type != Deck.CardType.Unknown:
		await Animator.delay(1)
		_on_target_type_selected(move._target_type)


func resolve_effect() -> void:
	var p = _players[_cur_player]
	var tp = _players[_target_player]
	p._state = Player.State.IDLE
	print("resolve_effect for " + 
		Deck.CardType.keys()[_played_card] +
		", player " + str(_target_player) + 
		", type " + Deck.CardType.keys()[_target_type])

	_player_selection.hide()

	if !tp.protected:
		match _played_card:
			
			Deck.CardType.Guard:
				if tp.hand.get_child(0).type == _target_type:
					await Animator.reveal_hand(tp)
					tp.active = false
			Deck.CardType.Priest:
				if p.is_human():
					await Animator.reveal_hand(tp)
				p.update_memory(tp.idx, tp.hand.get_child(0).type)
				print("Priest: reveal hand")
			Deck.CardType.Baron:
				if p.is_human():
					await Animator.reveal_hand(tp)
				var my_type = p.hand.get_child(0).type
				var their_type = tp.hand.get_child(0).type
				if my_type > their_type:
					tp.active = false
				elif my_type < their_type:
					p.active = false
				else:
					p.update_memory(tp.idx, their_type)
					tp.update_memory(p.idx, my_type)
				print("Baron: compare cards")
			Deck.CardType.Handmaid:
				p.protected = true
				print("Handmaid: protected on")
			Deck.CardType.Prince:
				var type = tp.hand.get_child(0).type
				await discard(tp.hand)
				await deal_card(tp)
				for pl in _players:
					if pl.idx != _cur_player:
						pl.update_memory(_cur_player)  # hand is unknown now
				if type == Deck.CardType.Princess:
					tp.active = false
				print("Prince: discard and redraw")
			Deck.CardType.King:
				var my_card: Card = p.hand.get_child(0)
				var their_card: Card = tp.hand.get_child(0)
				my_card.faceup = tp.is_human()
				their_card.faceup = p.is_human()
				var my_hand = p.hand
				var their_hand = tp.hand
				await Animator.all([
					Animator.move_card(my_card, tp.global_position),
					Animator.move_card(their_card, p.global_position)
				])
				my_hand.remove_child(my_card)
				their_hand.remove_child(their_card)
				p.add_card(their_card)
				tp.add_card(my_card)
				p.update_memory(tp.idx, my_card.type)
				tp.update_memory(p.idx, their_card.type)
				for pl in _players:
					if pl.idx != p.idx and pl.idx != tp.idx:
						# swap memories
						pl.update_memory(p.idx, pl._memory[tp.idx])
						pl.update_memory(tp.idx, pl._memory[p.idx])
				print("King: trade hands")
			Deck.CardType.Princess:
				p.active = false
				print("Princess: discarded")
	else:
		print("Player " + str(tp.idx) + " protected, no effect")

	await discard(_table)
	var active_count := 0
	for pl in _players:
		if pl.active:
			assert(p.hand.get_child_count() == 1, "Player " + str(_cur_player) +
				" has " + str(p.hand.get_child_count()) + " cards")
			active_count += 1
	if active_count == 1:
		round_over()
	else:
		_cur_player = (_cur_player + 1) % len(_players)
		while !_players[_cur_player].active:
			_cur_player = (_cur_player + 1) % len(_players)
		new_turn()


func discard(from: Node) -> void:
	var for_discard: Array[Card]
	for ch in from.get_children():
		if ch is Card:
			for_discard.append(ch)
	for ch in for_discard:
		ch.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
		await Animator.move_card(ch, _discard_marker.global_position, 0.25)
		from.remove_child(ch)
		ch.queue_free()


func round_over() -> void:
	print("Round over! Update scores")
	var max_type := 0
	for p in _players:
		if p.active:
			Animator.reveal_hand(p, false)
			max_type = max(max_type, p.hand.get_child(0).type)
	var round_winners := ""
	var game_winners := ""
	for p in _players:
		if p.active and p.hand.get_child(0).type == max_type:
			p.score += 1
			p.total_score += 1
			if !round_winners.is_empty():
				round_winners += ", "
			round_winners += str(p.idx)
			if p.score >= max_score:
				if !game_winners.is_empty():
					game_winners += ", "
				game_winners += str(p.idx)
	if !game_winners.is_empty():
		var s := "Game " + str(game_counter) + " over! Winners: " + game_winners + ". Total scores: "
		for p in _players:
			s += str(p.total_score) + ", "
		push_warning(s)
		_game_over_button.show()
		if !_players[0].is_human():
			await Animator.delay(8)
			_on_game_over_pressed()
	elif !round_winners.is_empty():
		print("Round over! Winners are " + round_winners)
		_round_over_button.show()
		if !_players[0].is_human():
			await Animator.delay(2)
			_on_round_over_pressed()


func _on_round_over_pressed() -> void:
	_round_over_button.hide()
	_new_round()


func _on_game_over_pressed() -> void:
	_game_over_button.hide()
	_new_game()

func find_valid_moves() -> Array[Move]:
	var result: Array[Move]
	var move: Move;
	var cp = _players[_cur_player]
	var countess_idx = cp.countess_restricted() 
	var cards: Array[Card] = [cp.hand.get_child(0), cp.hand.get_child(1)]
	if countess_idx != -1:
		move = Move.new(cards[countess_idx], countess_idx)
		result.append(move)
	else:
		for i in range(len(cards)):
			var type = cards[i].type
			match type:
				Deck.CardType.Guard:
					for p in _players:
						if p.idx != cp.idx and p.active and (!p.protected or _other_protected):
							for t in range(Deck.CardType.Priest, Deck.CardType.Unknown):
								move = Move.new(cards[i], i, p.idx, t)
								result.append(move)
				Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
					for p in _players:
						if p.idx != cp.idx and p.active and (!p.protected or _other_protected):
							move = Move.new(cards[i], i, p.idx)
							result.append(move)
				Deck.CardType.Handmaid, Deck.CardType.Countess, Deck.CardType.Princess:
					move = Move.new(cards[i], i)
					result.append(move)
				Deck.CardType.Prince:
					for p in _players:
						if p.active and !p.protected:
							move = Move.new(cards[i], i, p.idx)
							result.append(move)
	return result
