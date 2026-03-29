class_name Main
extends Node2D

signal menu_pressed

@export var card_scene: PackedScene
@export var random_seed: int = 42

const max_score: int = 4
const max_games: int = 1000

var game_counter: int = 0
var interrupted: bool

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
@onready var _animation_layer: Node2D = $AnimationLayer
@onready var _type_selector: Node2D = $TypeSelector
@onready var _discard_marker: Marker2D = $DiscardMarker
@onready var _round_over_button: TextureButton = $RoundOver
@onready var _game_over_button: TextureButton = $GameOver
@onready var _select_other_player: TextureButton = $SelectOtherPlayer
@onready var _select_any_player: TextureButton = $SelectAnyPlayer
@onready var _deal_audio_player: AudioStreamPlayer = $DealAudioPlayer
@onready var _inactive_audio_player: AudioStreamPlayer = $InactiveAudioPlayer
@onready var _round_over_audio_player: AudioStreamPlayer = $RoundOverAudioPlayer
@onready var _game_over_audio_player: AudioStreamPlayer = $GameOverAudioPlayer

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


func _ready() -> void:
	if Animator._speed == 0: # speedrun
		RenderingServer.render_loop_enabled = false
		Engine.print_to_stdout = false
	_players = [$Player0, $Player1, $Player2, $Player3]


func init_players() -> void:
	seed(random_seed if random_seed != 0 else Time.get_ticks_usec())
	_select_other_player.hide()
	_select_any_player.hide()
	for p in _players:
		assert(p.idx == 0 or !p.is_human(), "Human is allowed for Player 0 only")
		if p.is_human():
			if p.move_chosen.is_connected(_on_move_chosen):
				p.move_chosen.disconnect(_on_move_chosen)
			if !p.card_played.is_connected(_on_card_played):
				p.card_played.connect(_on_card_played)
		else:
			if !p.move_chosen.is_connected(_on_move_chosen):
				p.move_chosen.connect(_on_move_chosen)
		if !p.target_player_selected.is_connected(_on_target_player_selected):
			p.target_player_selected.connect(_on_target_player_selected)
		p.clear_hand()
	for ch in _table.get_children():
		if ch is Card:
			_table.remove_child(ch)
			ch.queue_free()
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
	interrupted = false
	game_counter += 1
	if game_counter > max_games:
		push_warning("Max games count reached, stop")
	else:
		print("\n\nNew game " + str(game_counter))
		for p in _players:
			p.score = 0
		_cur_player = 0
		_new_round()
	
	
func _new_round() -> void:
	_select_other_player.hide()
	_select_any_player.hide()
	for p in _players:
		p.protected = false
		p.active = true
		for i in range(len(p._memory)):
			p.update_memory(i)
	discard(_table)
	for p in _players:
		await discard(p.hand)
	_deck.prepare(len(_players))
	for p in _players:
		await deal_card(p)
	new_turn()


func deal_card(p: Player, allow_widow: bool = false) -> void:
	_deal_audio_player.play()
	var result := _deck.pop(allow_widow)
	var card_type = result["type"]
	var src = result["src"]
	var is_faceup = p.is_human()
	var c = card_scene.instantiate()
	_animation_layer.add_child(c)
	c.type = card_type
	c.faceup = is_faceup
	c.global_position = src.global_position
	_deck.update_piles()
	var dst := p.drawn_card_position()
	print("deal_card from " + str(src.global_position) + " to " + str(dst))
	await Animator.move_card(c, dst)
	p.add_card(c)
	c.position = p.hand.to_local(dst)


func new_turn():
	print("\nnew_turn for Player " + str(_cur_player) + ", level " + str(_players[_cur_player].ai_level))
	for p in _players:
		p.print_memory()
	for i in range(len(_deck._left)):
		print("Left " + Deck.card_names[i] + ": " + str(_deck._left[i]))
	var p = _players[_cur_player]
	p.protected = false
	_other_protected = true
	for pl in _players:
		if pl.active and !pl.protected and pl.idx != _cur_player:
			_other_protected = false
	_target_player = -1
	_target_type = Deck.CardType.Unknown
	if _deck._main.visible:
		await deal_card(p)
		#_players[_cur_player].hand.get_child(0).type = Deck.CardType.Baron
		#_players[_cur_player].hand.get_child(1).type = Deck.CardType.King
		p.current_mark.show()
		if p.is_human():
			var valid_moves = find_valid_moves()
			p.eval_moves(valid_moves, _deck._left)
			for m in valid_moves:
				print("\t" + str(m))
			p._state = Player.State.SELECT_CARD
		else:
			var valid_moves = find_valid_moves()
			p.ai_move(valid_moves, _deck._left)
	else:
		round_over()


func _on_card_played(card: Card) -> void:
	if interrupted:
		return
	card.faceup = true
	var g = card.global_position
	assert(card.get_parent())
	card.reparent(_animation_layer)
	card.global_position = g
	await Animator.move_card(card, _marker_0.global_position)
	card.reparent(_table)
	card.position = _table.to_local(card.global_position)
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
	if interrupted:
		return
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
	if interrupted:
		return
	_type_selector.set_selection(type)
	await Animator.delay(1)
	_table.show()
	_type_selector.hide()
	_target_type = type
	resolve_effect()


func _on_move_chosen(move: Move) -> void:
	if interrupted:
		return
	await Animator.delay(1)
	print("My " + str(move))
	_on_card_played(move._played_card)
	if move._target_player != -1:
		await Animator.delay(1)
		_on_target_player_selected(move._target_player)
	if move._target_type != Deck.CardType.Unknown:
		await Animator.delay(1)
		_on_target_type_selected(move._target_type)


func set_inactive(p: Player):
	p.active = false
	_inactive_audio_player.play()
	discard(p.hand)


func resolve_effect() -> void:
	if interrupted:
		return
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
					set_inactive(tp)
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
					set_inactive(tp)
				elif my_type < their_type:
					set_inactive(p)
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
				await deal_card(tp, true)
				for pl in _players:
					if pl.idx != _cur_player:
						pl.update_memory(_cur_player)  # hand is unknown now
				if type == Deck.CardType.Princess:
					set_inactive(tp)
				print("Prince: discard and redraw")
			Deck.CardType.King:
				var my_card: Card = p.hand.get_child(0)
				var their_card: Card = tp.hand.get_child(0)
				my_card.faceup = tp.is_human()
				their_card.faceup = p.is_human()
				var g := my_card.global_position
				my_card.reparent(_animation_layer)
				my_card.global_position = g
				g = their_card.global_position
				their_card.reparent(_animation_layer)
				their_card.global_position = g
				await Animator.all([
					Animator.move_card(my_card, tp.global_position),
					Animator.move_card(their_card, p.global_position)
				])
				p.add_card(their_card)
				their_card.position = p.hand.to_local(their_card.global_position)
				tp.add_card(my_card)
				my_card.position = tp.hand.to_local(my_card.global_position)
				p.update_memory(tp.idx, my_card.type)
				tp.update_memory(p.idx, their_card.type)
				for pl in _players:
					if pl.idx != p.idx and pl.idx != tp.idx:
						# swap memories
						pl.update_memory(p.idx, pl._memory[tp.idx])
						pl.update_memory(tp.idx, pl._memory[p.idx])
				print("King: trade hands")
			Deck.CardType.Princess:
				set_inactive(p)
				print("Princess: discarded")
	else:
		print("Player " + str(tp.idx) + " protected, no effect")

	if interrupted:
		return
	await discard(_table)
	var active_count := 0
	for pl in _players:
		if pl.active:
			assert(pl.hand.get_child_count() == 1, "Player " + str(pl.idx) +
				" has " + str(pl.hand.get_child_count()) + " cards")
			active_count += 1
	if active_count == 1:
		round_over()
	else:
		_cur_player = (_cur_player + 1) % len(_players)
		while !_players[_cur_player].active:
			_cur_player = (_cur_player + 1) % len(_players)
		new_turn()


func discard(from: Node2D) -> void:
	var for_discard: Array[Card]
	for ch in from.get_children():
		if ch is Card:
			for_discard.append(ch)
	for ch in for_discard:
		_deck._left[ch.type] -= 1
		assert(_deck._left[ch.type] >= 0)
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
	var round_winners: Array[int]
	var round_winners_str := ""
	var game_winners := ""
	for p in _players:
		if p.active and p.hand.get_child(0).type == max_type:
			p.score += 1
			p.total_score += 1
			if !round_winners_str.is_empty():
				round_winners_str += ", "
			round_winners_str += str(p.idx)
			round_winners.append(p.idx)
			if p.score >= max_score:
				if !game_winners.is_empty():
					game_winners += ", "
				game_winners += str(p.idx)
	if !game_winners.is_empty():
		_game_over_audio_player.play()
		var s := "Game " + str(game_counter) + " over! Winners: " + game_winners + ". Total scores: "
		for p in _players:
			s += str(p.total_score) + ", "
		push_warning(s)
		_game_over_button.show()
		if !_players[0].is_human():
			await Animator.delay(8)
			_on_game_over_pressed()
	elif !round_winners_str.is_empty():
		_round_over_audio_player.play()
		print("Round over! Winners are " + round_winners_str)
		_cur_player = round_winners[randi() % len(round_winners)]
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


func _on_menu_button_pressed() -> void:
	menu_pressed.emit()
