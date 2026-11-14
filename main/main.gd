class_name Main
extends Node2D

signal menu_pressed
signal round_finished(level: Player.AI_Level)
signal round_won(level: Player.AI_Level)
signal save_stats

@export var card_scene: PackedScene

const max_games: int = 1000

# Noble Family geometry lives with the seat (`player/player.gd`: the stack is part of the seat scene,
# it has to follow the seat's position, scale and fade). These aliases keep the harness references
# `Main.FAMILY_*` working.
const FAMILY_STACK_ORIGIN := Player.FAMILY_STACK_ORIGIN
const FAMILY_STACK_MIRROR := Player.FAMILY_STACK_MIRROR
const FAMILY_CASCADE_STEP := Player.FAMILY_CASCADE_STEP

var _random_seed: int = 0

var game_counter: int = 0
var interrupted: bool
var noble_family: bool = false

# Noble Family, todo step 22 - the family modal's EXCLUSIVITY state.
#
# A human family draw is a coroutine that stops the play chain on `await draw_selected`, and the chain
# is single-threaded: while it is suspended nothing else in `Main` runs. That is the whole guarantee a
# human turn rests on - "the modal opens only when he must draw, nothing draws from a family while it
# is open, the draw happens exactly once" - and these two fields are what make it inspectable instead
# of implicit:
#
#	_drawing   - the draw is PENDING: set before the panel opens, cleared when the choice lands.
#	             The panel is permanently allocated (a scene child of Main, not an `instantiate()`
#	             per turn), so its signal is connected ONCE for the whole game; `_drawing` is what the
#	             todo's "CONNECT_ONE_SHOT-safe" requirement is really about - the listener exists for
#	             the game's lifetime, so a stray emission (a double tap, a tap on a closing panel) has
#	             to be dropped by the RECEIVER, and `_drawing` is exactly the predicate that drops it.
#	_draw_idx  - the index the listener recorded for the pending draw, i.e. what the panel reported.
#	             `human_draw_from_family` reads the index off its own `await` (the value the signal
#	             carried) and compares it with the latch: a mismatch is the proof of two emissions in
#	             flight, which is the double-draw failure mode this step is about.
var _drawing: bool = false
var _draw_idx: int = -1

var _player_count: int
var _max_score: int
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
@onready var _family_selector: FamilySelector = $FamilySelector
@onready var _discard_marker: Marker2D = $DiscardMarker
@onready var _round_over_label: Label = $RoundOverLabel
@onready var _game_over_label: Label = $GameOverLabel
@onready var _select_other_player: Label = $SelectOtherPlayer
@onready var _select_any_player: Label = $SelectAnyPlayer
@onready var _deal_audio_player: AudioStreamPlayer = $DealAudioPlayer
@onready var _inactive_audio_player: AudioStreamPlayer = $InactiveAudioPlayer
@onready var _round_over_audio_player: AudioStreamPlayer = $RoundOverAudioPlayer
@onready var _round_won_audio_player: AudioStreamPlayer = $RoundWonAudioPlayer
@onready var _game_over_audio_player: AudioStreamPlayer = $GameOverAudioPlayer
@onready var _game_won_audio_player: AudioStreamPlayer = $GameWonAudioPlayer

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
	_players = [$Player0, $Player1, $Player2, $Player3]
	# The family panel is a permanently allocated node, so it gets exactly ONE listener for the whole
	# game, connected here. A per-`open()` connect would be a second listener on every draw of a long
	# game (and `CONNECT_ONE_SHOT` per open() is what the todo suggests as the alternative: it works,
	# but it makes the connection a per-draw resource that a leaky exit path can strand).
	# The listener is a GUARDED observer (see `_on_family_draw_selected`): it latches the index of the
	# draw that is pending and drops everything else.
	_family_selector.draw_selected.connect(_on_family_draw_selected)


# The modal is open and a family draw is PENDING: the single source of truth for "the human seat is
# choosing right now", read by the harnesses frame by frame (todo step 22's exclusivity gate is
# `is_drawing() == _family_selector.is_open()` at every frame of a human game).
func is_drawing() -> bool:
	return _drawing


# Noble Family, todo §C.28: the ONE translation from a game's mode to the stats table that game's
# history belongs to. `Stats.MODE_CLASSIC` / `Stats.MODE_NOBLE` are the table indices (step 26), and
# this is the only place in the project that turns `noble_family` - a property of the DEAL, fixed when
# the game started - into one of them. It exists so a counter can be filed by the mode the game was
# dealt by, instead of by whichever table the stats page happens to show: step 27 gave the player two
# arrows, i.e. a VIEW he can move at any moment, and a `round_won` arrives from the game, never from
# the page. A page's view must never decide where a number is written.
func noble_family_index() -> int:
	return Stats.MODE_NOBLE if noble_family else Stats.MODE_CLASSIC


# The panel's listener. `_drawing` is the guard: while a draw is pending it latches the reported
# family index; with no draw pending the emission is inert - it cannot queue a second draw, because
# `Main` is not awaiting anything and a family pop only ever happens in `human_draw_from_family`.
func _on_family_draw_selected(family_idx: int) -> void:
	if not _drawing:
		push_warning("FamilySelector reported family index " + str(family_idx) + " with no family draw"
			+ " pending - dropped (the panel emitted twice, out of the blue, or after its modal closed)")
		return
	_draw_idx = family_idx


# Close the modal and drop the pending-draw state. EVERY exit path calls this, so a panel can never
# survive the thing that opened it: the draw commit (step 20/21), a new game (`init_players`, the
# Main-Menu/Exit path: a suspended `await` resumes only on a real tap, so an interrupted game leaves
# the panel open on the menu) and a new round (`_new_round`, the family is RE-DEALT - a row of the
# previous family would be a menu of cards that no longer exist).
func _close_family_modal() -> void:
	if _family_selector.is_open():
		push_warning("FamilySelector was still open at a reset point - closed here (a modal that outlived"
			+ " its draw is a stuck overlay)")
	_family_selector.close()
	_drawing = false
	_draw_idx = -1


func init_players(random_seed: int) -> void:
	_random_seed = random_seed
	_table.show()
	_type_selector.hide()
	# a game starts with no modal and no pending draw (the interrupted path can leave a panel open on
	# the menu: a suspended `await draw_selected` never resumes when the game is interrupted, so this
	# is the ONLY thing that clears it)
	_close_family_modal()
	_round_over_label.hide()
	_game_over_label.hide()
	_select_other_player.hide()
	_select_any_player.hide()
	await Animator.flash(0, [])
	for p in _players:
		assert(p.idx == 0 or !p.is_human(), "Human is allowed for Player 0 only")
		if p.is_active():
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


func _new_game() -> void:
	if _random_seed:
		seed(_random_seed)
	interrupted = false
	game_counter += 1
	if game_counter > max_games:
		push_warning("Max games count reached, stop")
	else:
		print("\n\nNew game " + str(game_counter))
		_player_count = 0
		for p in _players:
			p.score = 0
			if p.ai_level != Player.AI_Level.Disabled:
				_player_count += 1
		if _player_count == 2:
			_max_score = 6
		elif _player_count == 3:
			_max_score = 5
		elif _player_count == 4:
			_max_score = 4
		_cur_player = 0
		_new_round()
	
	
func _new_round() -> void:
	_target_player = -1
	_target_type = Deck.CardType.Unknown
	# The family is re-dealt here, so any panel of the previous round is a menu of cards that do not
	# exist any more: the modal is closed at the round start, and `_drawing` with it - a pending draw
	# and a freshly dealt family cannot coexist.
	_close_family_modal()
	_select_other_player.hide()
	_select_any_player.hide()
	for p in _players:
		p.protected = false
		p.active = true
		p._inactive.visible = false
		p.hand.modulate.a = 1.0
		for i in p._memory.size():
			p.update_memory(i)
	discard(_table)
	for p in _players:
		await discard(p.hand)
	if noble_family:
		# Noble Family: burn 3/1/0, one first-hand card per seat (animated, through the
		# regular deal path so the round looks identical to classic), then the private
		# families, dealt instantly - they are never animated, they are just data + a
		# face-up stack for the human seat (rendering lands in step 18).
		var families: Array = _deck.prepare_noble(_player_count)
		var seat := 0
		for p in _players:
			if p.is_active():
				await deal_card(p, false, _deck.first_hand[seat])
				p.family = families[seat]
				# the human seat's private stack, refilled for the new round (instant, no animation -
				# render_family() renders nothing on an AI seat, his family stays invisible)
				p.render_family()  # the deal's render (step 23)
				seat += 1
			else:
				p.clear_family()
		# Todo step 23: the family batch gets ONE slide sound for the WHOLE batch, not one per card.
		# The families are not animated - 5/4/3 cards per seat appear as data + a face-up stack in one
		# instant - so a per-card sound would be `family_size * player_count` plays of the same stream
		# in one frame (an AudioStreamPlayer restarts on every `play()`, so they would cancel each other
		# and sound like a stutter). It plays AFTER the animated first-hand cards, so it is the last beat
		# of the deal - the family batch is the sound that says "your family is there, your turn".
		# It lands after them for the same reason: `play()` restarts the stream, so a batch sound played
		# BEFORE the deals would be cut off by the first first-hand card.
		if seat > 0:
			deal_sound()
	else:
		# Classic mode never deals a family, and a game is not the only state this node has ever known:
		# the mode is picked PER GAME and never persisted, so a classic game can start right after a
		# variant one (Exit-to-menu -> PLAY -> CLASSIC). Family data left over from that game is inert -
		# no classic path reads it - but it is NOT invisible: the human seat's stack is rendered from it
		# (`Player.render_family()`), so a stale family would sit on the table through a classic game.
		# Clearing here is a no-op in a classic-only app (the arrays are empty), so classic is untouched.
		for p in _players:
			p.clear_family()
		_deck.prepare(_player_count)
		for p in _players:
			if p.is_active():
				await deal_card(p)
	new_turn()


# Todo step 23: the deal's sound, asked for in ONE place. The rule it encodes is the batch rule: a
# slide belongs to a deal EVENT, not to a card. A flying card asks for one (`deal_card`,
# `deal_from_family`), and the Noble Family batch - 5/4/3 cards per seat appearing as data plus a
# face-up stack in a single instant - asks for exactly ONE for the whole batch, because `play()`
# restarts its stream, so a slide per family card in one frame would cut itself off into a stutter.
# Every deal sound in the game goes through here, which is also what makes "one sound for the batch"
# a countable property (see `CountingMain.deal_sound`).
func deal_sound() -> void:
	_deal_audio_player.play()


# When `card_type` is given, deal that exact card instead of popping the top of the deck:
# the Noble Family first-hand cards are pre-dealt by Deck.prepare_noble(). Nothing is
# popped and `_left` is untouched - a first-hand card leaves the supply only when it is played.
func deal_card(p: Player, allow_widow: bool = false, card_type: Deck.CardType = Deck.CardType.Unknown) -> void:
	deal_sound()
	var src: Sprite2D
	if card_type == Deck.CardType.Unknown:
		var result := _deck.pop(allow_widow)
		card_type = result["type"]
		src = result["src"]
	else:
		src = _deck._main
	var is_faceup = p.idx == 0
	var c = card_scene.instantiate()
	_animation_layer.add_child(c)
	c.type = card_type
	c.faceup = is_faceup
	c.global_position = src.global_position
	_deck.update_piles()
	var dst := p.drawn_card_position()
	await Animator.move_card(c, dst)
	p.add_card(c)
	c.position = p.hand.to_local(dst)


# Noble Family variant: the draw from a seat's own private family - the mandatory turn-start
# draw (step 7) and the Prince redraw (step 15).
#
# The family is private and already out of the main pile, so a family draw touches nothing in
# Deck: nothing is popped, `_left` is NOT decremented and `update_piles()` is not called. A
# family card leaves the supply only when it is played (`discard()`), which is what keeps the
# step 17 invariant `sum(_left) == 16 - played_cards` true: family cards are counted in `_left`
# while they sit in the family. The popped type is handed straight to the card node, so no
# `Deck.pop()` and no `_deck._cards` involvement at all.
func deal_from_family(p: Player, family_idx: int) -> void:
	# Todo step 22's exclusivity rail: the ONLY family draw that may happen while a modal is open is
	# the modal's own, and that one runs AFTER `_drawing` is cleared (see `human_draw_from_family`).
	# The play chain is single-threaded, so a draw here with a modal open means a nested chain - the
	# card the seat is choosing would be popped from under him. Warn loudly, and keep drawing: silently
	# skipping a mandatory draw is the deadlock this step is guarding against.
	if _drawing:
		push_warning("deal_from_family: seat " + str(p.idx) + " draws family[" + str(family_idx)
			+ "] while a family modal is open - the seat that is choosing is the only one allowed to draw")
	deal_sound()
	var card_type: Deck.CardType = p.pop_family(family_idx)
	# the stack is a view of the data, so it shrinks with the pop - before the card starts to fly,
	# so what is left in the stack is exactly what the seat still holds
	p.render_family()
	var c = card_scene.instantiate()
	_animation_layer.add_child(c)
	c.type = card_type
	c.faceup = p.idx == 0
	# The family lives in the seat's own stack (`$Family`, rendered by `Player.render_family()`), so the
	# card flies from the seat to the hand slot, exactly like a deal from a pile.
	c.global_position = p.global_position
	var dst := p.drawn_card_position()
	await Animator.move_card(c, dst)
	p.add_card(c)
	c.position = p.hand.to_local(dst)


# Noble Family (todo steps 20 + 21): the human seat's mandatory family draw, taken in the `FamilySelector`
# modal. The panel shows HIS OWN family and reports a family INDEX; `Main` pops `p.family[idx]`, so the
# seat's data stays the single source of truth and the modal can only choose among cards he has (it can
# invent, add, reorder or duplicate none of them).
#
# The Table is hidden while the panel is open: the draw comes BEFORE any play, so the played-card slot
# and the piles have nothing to do with the choice, and a human turn has exactly one interactive surface
# at a time (the type/target selectors are hidden here, they belong to the play that follows).
#
# `await signal` is one-shot by construction (it disconnects on the resume) and the panel disarms itself
# on the commit, so one open() yields exactly one draw - and the draw is mandatory: the panel has no
# cancel path, so the only way out of it is tapping a card the seat owns.
#
# Todo step 22 put the exclusivity of this moment here, because this is the ONLY place a modal is ever
# opened, so it is the only place that has to make it exclusive:
#
# - it opens ONLY when a human must draw: a human seat, a non-empty family, and no draw already pending.
#   A nested request (the same chain asking twice) returns without touching the panel, so there is one
#   modal on screen at a time and the row the seat is looking at is never re-built from under him;
# - it opens ALONE: the Table, the type selector, the two target labels and the player-selection sprite
#   are hidden and the seat's state goes IDLE, so a tap on his own hand card, on a seat, on the table or
#   on a type has nothing to act on (Player gates card taps on `_state`; a seat tap lands in a `_state`
#   match that accepts nothing; the Table's Area2D is not pickable under a hidden parent);
# - the draw happens EXACTLY ONCE: the panel disarms on its commit (one emission per open()), the
#   guarded listener drops every emission that is not the pending draw, and the index Main pops is the
#   index the seat tapped;
# - it CLOSES on every path out of it, and it cannot stall the mandatory draw: a tap can only report an
#   index of its own row, so the only way Main is handed an index it cannot pop is a panel emitting out
#   of the blue (a harness sabotage) - then the seat takes family[0], because a turn that never draws
#   never ends and the turn-start draw (step 7) is not optional.
func human_draw_from_family(p: Player) -> void:
	assert(noble_family, "family draw for seat " + str(p.idx) + " outside the Noble Family variant")
	assert(p.is_human(), "family draw for seat " + str(p.idx) + ", who is not a human seat")
	if _drawing:
		push_warning("human_draw_from_family: seat " + str(p.idx) + " is already choosing in the modal,"
			+ " the nested request is ignored (a family draw happens exactly once)")
		return
	if p.family.is_empty():
		# Main owns the round-over / elimination decisions; a modal with no card to tap is a stalled
		# turn, so an empty family is not a page - the caller takes the round-over (turn start) or the
		# widow/elimination chain (Prince, step 21) branch instead.
		push_warning("human_draw_from_family: player " + str(p.idx) + " has no family card to draw")
		return
	# The listener rail: in the real scene the panel is connected once in `_ready()`; a harness that
	# swaps `_family_selector` for a fresh instance must not end up opening a modal nobody listens to,
	# which is the same bug as a double listener, one frame later (the draw never lands).
	if not _family_selector.draw_selected.is_connected(_on_family_draw_selected):
		_family_selector.draw_selected.connect(_on_family_draw_selected)
	# ONE interactive surface at a time: everything the PLAY needs is put away for the length of the
	# draw (the type selector and the target labels belong to the play that follows, the player
	# selection sprite to the effect that follows).
	_table.hide()
	_type_selector.hide()
	_select_other_player.hide()
	_select_any_player.hide()
	_player_selection.visible = false
	# Taps outside the panel do nothing, and the seat's OWN cards are the ones that have to prove it: a
	# card tap in SELECT_CARD emits `card_played` and starts a play chain on a hand that is about to
	# grow. The seat's state IS his tap gate (`Player._on_card_input_event` accepts a card tap in
	# SELECT_CARD only), so the modal closes it for the length of the choice and restores what the
	# caller left behind: `_begin_play_selection()` re-opens it at a turn start, the Prince chain has no
	# tap to open.
	var prev_state: Player.State = p._state
	p._state = Player.State.IDLE
	_drawing = true
	_draw_idx = -1
	_family_selector.open(p.family)
	print("Family draw: player " + str(p.idx) + " chooses a family card")
	var family_idx: int = await _family_selector.draw_selected
	# The draw is COMMITTED: the pending state drops before the card flies, so the modal is closed and
	# the play surface is open again with nothing left to tap into. Closing first is the anti-deadlock
	# order - a panel that stayed open across the draw animation would be a stuck overlay.
	_drawing = false
	var latched: int = _draw_idx
	_draw_idx = -1
	_family_selector.close()
	_table.show()
	p._state = prev_state
	if latched != family_idx:
		push_warning("family draw of seat " + str(p.idx) + ": the panel reported index " + str(family_idx)
			+ " and the guarded listener latched " + str(latched) + " - the modal emitted twice")
	if family_idx < 0 or family_idx >= p.family_size():
		push_warning("family draw of seat " + str(p.idx) + ": the panel reported index " + str(family_idx)
			+ " and the seat has " + str(p.family_size()) + " family cards - the draw is mandatory, so"
			+ " seat " + str(p.idx) + " takes family[0] (no tap can produce this: the panel only emits an"
			+ " index of its own row)")
		family_idx = 0
	print("Family draw: player " + str(p.idx) + " drew family[" + str(family_idx) + "] = "
		+ Deck.card_names[int(p.family[family_idx])])
	await deal_from_family(p, family_idx)


func new_turn():
	print("\nnew_turn for Player " + str(_cur_player) + ", level " + str(_players[_cur_player].ai_level))
	if get_parent().print_memory:
		for p in _players:
			p.print_memory()
		for i in _deck._left.size():
			print("Left " + Deck.card_names[i] + ": " + str(_deck._left[i]))
		if noble_family:
			var fams := "Families: "
			for pl in _players:
				fams += str(pl.idx) + "=" + str(pl.family_size()) + " "
			print(fams)
	var p = _players[_cur_player]
	p.protected = false
	_other_protected = true
	for pl in _players:
		if pl.is_active() and !pl.protected and pl.idx != _cur_player:
			_other_protected = false
	_target_player = -1
	_target_type = Deck.CardType.Unknown
	# Noble Family: the round ends at turn start when the seat to act has no family card left,
	# and the mandatory draw comes from his own family (never from the main pile, which this
	# variant never draws from).
	if noble_family:
		if p.family.is_empty():
			print("Round over: player " + str(p.idx) + " has no family card to draw")
			round_over()
			return
		if p.is_human():
			# The human's mandatory family draw is HIS choice, taken in the modal (step 20): the seat's
			# stack is display-only, so no path auto-picks a family card for a human seat.
			await human_draw_from_family(p)
			_begin_play_selection(p)
		else:
			# An AI seat does NOT draw here: the family draw is part of the move, enumerated by
			# find_valid_moves() (step 11) and animated by _on_move_chosen() (step 13). The seat
			# decides over the pair (his active card, family[f]) while his hand holds 1 card.
			_begin_play_selection(p)
		return
	if _deck._main.visible:
		await deal_card(p)
		#_players[_cur_player].hand.get_child(0).type = Deck.CardType.Baron
		#_players[_cur_player].hand.get_child(1).type = Deck.CardType.King
		_begin_play_selection(p)
	else:
		round_over()


# The shared tail of new_turn(): in classic the seat has just drawn his second card from the main
# pile (hand = 2 cards, he chooses which one to play); in the Noble Family variant an AI seat has
# 1 card in hand and chooses the whole (draw, play, target) triple, while the human seat is still
# dealt a placeholder family draw at turn start (step 20) and keeps the 2-card choice.
func _begin_play_selection(p: Player) -> void:
	p.current_mark.show()
	if p.is_human():
		var valid_moves = find_valid_moves()
		p.eval_moves(valid_moves, _deck._left)
		if get_parent().print_valid_moves:
			for m in valid_moves:
				print("\t" + str(m))
		p._state = Player.State.SELECT_CARD
		var countess_idx := p.countess_restricted()
		if countess_idx != -1:
			p.hand.get_child(1 - countess_idx).modulate.a = 0.25
	else:
		var valid_moves = find_valid_moves()
		if valid_moves.is_empty():
			# No legal (draw, play, target) triple: the seat holds only types that need a target
			# (Guard / Priest / Baron / King) and every opponent is protected. Classic has the same
			# dead end for a human (the target selection simply never accepts a tap), so the rule is
			# not invented here; the AI must not crash on `valid_moves[0]`, so the round ends.
			push_warning("Player " + str(p.idx) + " has no legal move, ending the round")
			round_over()
			return
		p.ai_move(valid_moves, _deck._left)


func _on_card_played(card: Card) -> void:
	if interrupted:
		return
	# Todo step 22: the modal owns the screen while a family draw is pending, so a play that arrives in
	# that window is a tap that got through - it must not start a second chain (a played card, a target
	# pick and an effect running under a panel that is still asking for a draw).
	if _drawing:
		push_warning("Ignored a card play by seat " + str(_cur_player) + " while the family draw modal is"
			+ " open (one interactive surface at a time)")
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
	# A belief about the playing player names the card he was holding before he drew, and an
	# observer sees only the played card, never which of his two cards it was. A play of the
	# believed type therefore makes the belief's referent ambiguous - and mostly kills it: it
	# stays true only when the player held both copies of that type and played the one he has
	# just drawn (1 561 of 16 369 such plays, ~9.5%, see tests/prince_memory_sim.py). Clearing
	# on the played type is the sound inference; keeping the belief would mean knowing which
	# slot the card came from, which no seat can see.
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
		await resolve_effect()


func _on_target_player_selected(idx: int) -> void:
	if interrupted:
		return
	if _drawing:
		push_warning("Ignored a target-player tap on seat " + str(idx) + " while the family draw modal is"
			+ " open (the target pick belongs to the play that follows the draw)")
		return
	if _players[idx].is_active():
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
							await Animator.delay(1)
							await resolve_effect()
			Player.State.INPUT_ANY_P:
				if !_players[idx].protected:
					_target_player = idx
					_select_any_player.hide()
					await resolve_effect()


func _on_target_type_selected(type: Deck.CardType) -> void:
	if interrupted:
		return
	if _drawing:
		push_warning("Ignored a target-type tap for " + Deck.card_names[type] + " while the family draw"
			+ " modal is open")
		return
	_type_selector.set_selection(type)
	await Animator.delay(1)
	_table.show()
	_type_selector.hide()
	_target_type = type
	await resolve_effect()


func _on_move_chosen(move: Move) -> void:
	if interrupted:
		return
	if _drawing:
		# A seat CANNOT choose while the human's modal is open - the play chain is single-threaded and
		# it is suspended in the modal - so this rail has no legitimate path: it fires only if a tap or a
		# stale signal drives a chain under the panel, which is the double-draw shape step 22 is about.
		push_warning("Ignored a chosen move of seat " + str(_cur_player) + " while the family draw modal"
			+ " is open (nothing draws from a family while the modal is open)")
		return
	await Animator.delay(1)
	if get_parent().print_valid_moves:
		print("My " + str(move))
	if move.is_noble():
		# The mandatory family draw is part of the move: it animates first, so the played card is
		# the active one (`_played_card_idx` 0) or the card that was just drawn (1).
		var p := _players[_cur_player]
		await deal_from_family(p, move._drawn_family_idx)
		move._drawn_card = p.hand.get_child(1)
		if move._played_card_idx == 1:
			move._played_card = move._drawn_card
	await _on_card_played(move._played_card)
	if move._target_player != -1:
		await Animator.delay(1)
		await _on_target_player_selected(move._target_player)
	if move._target_type != Deck.CardType.Unknown:
		await Animator.delay(1)
		await _on_target_type_selected(move._target_type)


func set_inactive(p: Player, reveal_hand: bool = true):
	p.active = false
	# The seat is out of the round: beliefs about its card are worthless (no move can
	# target it any more), and its own beliefs will never guide a move again.
	for pl in _players:
		pl.update_memory(p.idx)
	for j in 4:
		p._memory[j] = Deck.CardType.Unknown
	_inactive_audio_player.play()
	if reveal_hand:
		await Animator.reveal_hand(p, false)
	# Noble Family: an out seat's private family becomes public together with his hand and then
	# leaves play. The revealed types resolve NO effects - the family cards are shown, counted into
	# the discard pile and freed, they are never played.
	# The family ALWAYS leaves play with its owner (the fixed rule), so its cards are materialized and
	# discarded in EVERY elimination - only the flip is gated by the very same flag as the hand:
	# `reveal_hand == false` means the hand card is already public knowledge (a Baron lost to a seat
	# that SAW both cards, a Prince victim whose card the Prince effect flipped face-up before
	# discarding it), so the family leaves face-down: the variant never publishes more about the same
	# cards than the classic rules already publish.
	# The family data is cleared here, not in `_new_round()`, so every snapshot taken after the
	# elimination (round end, the next effect) sees an out seat with 0 family cards, and the
	# `_left` identity "main pile + widow + families + hands + table" keeps holding.
	if noble_family:
		var family_pile: Node2D = await reveal_out_family(p, reveal_hand)
		if family_pile != null:
			# `discard()` is the ONLY `_left` decrement in the game, and each revealed card is a Card
			# node under the stack exactly once, so family cards are counted exactly once here
			# (a family draw never decremented `_left`, they are still in the supply).
			await discard(family_pile)
			# NO queue_free(): the stack is the seat's own scene node (step 18) - the human's private
			# menu all round and the reveal surface at elimination. `discard()` already removed and
			# freed the Card children, `clear_family()` below drops the data; the empty node lives on.
		p.clear_family()
	discard(p.hand)
	p._inactive.visible = true
	await Animator.delay(1)


# Noble Family, steps 16 + 18: materialize the out seat's family IN HIS OWN STACK
# (`Player.family_root`, the node the human seat looks at all round), cascade-style, face-up when
# `show` (his hand is revealed too). Returns the stack node the cards sit in (null when the family is
# empty), so the caller discards those exact nodes through the regular discard path - that discard is
# what counts the family cards into `_left`.
#
# `force` is what makes a stack appear on a seat that never shows one: the family is private, so an
# AI seat renders NOTHING (his `family_size()` cards are data only) until he leaves the round. The
# cascade direction mirrors on the `right_score` seats (2 and 3, x 68), whose stack starts at
# FAMILY_STACK_MIRROR and grows left, because a right-growing 5-card stack would leave the 84 px board.
func reveal_out_family(p: Player, show: bool = true) -> Node2D:
	if p.family.is_empty():
		return null
	# snapshot of the as-dealt order: the data is cleared by the caller, the nodes are what a
	# harness can assert on (type, faceup, cascade positions)
	var types: Array[Deck.CardType] = p.family.duplicate()
	# the stack renders `p.family`, and the data is cleared only by the caller, so the render is the
	# whole materialization: same origin, same cascade step, one node per card, in as-dealt order.
	# FACE-DOWN first - the flip below IS the visible reveal.
	p.render_family(false, true)
	var root: Node2D = p.family_root
	if show:
		for i in types.size():
			await Animator.flip(root.get_child(i) as Card, true)
		await Animator.delay(1)  # let the player read the revealed family
	return root


func resolve_effect() -> void:
	var p := _players[_cur_player]
	p.hand.get_child(0).modulate.a = 1
	if interrupted:
		return
	var tp = null if _target_player == -1 else _players[_target_player]
	p._state = Player.State.IDLE
	print("resolve_effect for " + 
		Deck.CardType.keys()[_played_card] +
		", player " + str(_target_player) + 
		", type " + Deck.CardType.keys()[_target_type])

	_player_selection.hide()

	if tp == null or !tp.protected:
		match _played_card:
			
			Deck.CardType.Guard:
				if tp.hand.get_child(0).type == _target_type:
					await set_inactive(tp)
			Deck.CardType.Priest:
				if p.is_human():
					await Animator.reveal_hand(tp)
				p.update_memory(tp.idx, tp.hand.get_child(0).type)
				print("Priest: reveal hand")
			Deck.CardType.Baron:
				if p.is_human():
					await Animator.reveal_hand(tp)
				elif tp.is_human():
					await Animator.reveal_hand(p)
				var my_type = p.hand.get_child(0).type
				var their_type = tp.hand.get_child(0).type
				if my_type > their_type:
					await set_inactive(tp, !p.is_human())
				elif my_type < their_type:
					await set_inactive(p, !tp.is_human())
				else:
					p.update_memory(tp.idx, their_type)
					tp.update_memory(p.idx, my_type)
					for pl in _players:
						if pl.idx != p.idx and pl.idx != tp.idx:
							if pl._memory[p.idx] != Deck.CardType.Unknown:
								pl.update_memory(tp.idx, pl._memory[p.idx])
							elif pl._memory[tp.idx] != Deck.CardType.Unknown:
								pl.update_memory(p.idx, pl._memory[tp.idx])
				print("Baron: compare cards")
			Deck.CardType.Handmaid:
				p.protected = true
				print("Handmaid: protected on")
			Deck.CardType.Prince:
				var type = tp.hand.get_child(0).type
				await Animator.reveal_hand(tp, false)
				await discard(tp.hand)
				if type == Deck.CardType.Princess:
					await set_inactive(tp, false)
				else:
					# Noble Family: a Prince redraw draws from the target's own family first
					# (an AI seat takes the as-dealt index 0, a human seat PICKS in the modal - step 21),
					# the widow is the fallback pile, and a target with an empty family and no widow
					# (4p burns nothing, so no widow exists) is eliminated. The widow is never
					# drawable at a turn start - only here.
					if noble_family:
						if not tp.family.is_empty():
							if tp.is_human():
								# Todo step 21: a human target chooses HIS OWN family card in the same modal a
								# turn start uses, so a mid-effect draw is HIS choice in both shapes this branch
								# can reach: a self-Prince (tp == p) and an AI's Prince aimed at him. No path here
								# auto-picks a family card for a human seat, and an empty family is never a page -
								# the widow / elimination chain below runs INSTEAD of the panel.
								await human_draw_from_family(tp)
							else:
								await deal_from_family(tp, 0)
						elif not _deck._widow_cards.is_empty():
							await deal_card(tp, true)
						else:
							# No family card left and no widow (4p): the target is out of the round.
							# No early return - resolve_effect() must still discard the played card,
							# run the 1-card hand invariant and pick the next seat.
							await set_inactive(tp, false)
					else:
						await deal_card(tp, true)
					# The target's card left the game, so every belief about him is dead.
					# The Prince player's own hand card never changed, so beliefs about him
					# stay valid; when he Prince-plays himself (tp == p) his own card did
					# leave, and this loop covers that case too.
					for pl in _players:
						pl.update_memory(tp.idx)  # hand is unknown now
				print("Prince: discard and redraw")
			Deck.CardType.King:
				var my_card: Card = p.hand.get_child(0)
				var their_card: Card = tp.hand.get_child(0)
				# Seat 0 keeps its cards face up, whoever plays it.
				my_card.faceup = tp.idx == 0
				their_card.faceup = p.idx == 0
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
						var tmp = pl._memory[p.idx]
						pl.update_memory(p.idx, pl._memory[tp.idx])
						pl.update_memory(tp.idx, tmp)
				print("King: trade hands")
			Deck.CardType.Princess:
				await set_inactive(p)
				print("Princess: discarded")
	else:
		print("Player " + str(tp.idx) + " protected, no effect")

	if interrupted:
		return
	await discard(_table)
	var active_count := 0
	for pl in _players:
		if pl.is_active():
			assert(pl.hand.get_child_count() == 1, "Player " + str(pl.idx) +
				" has " + str(pl.hand.get_child_count()) + " cards")
			active_count += 1
	if active_count == 1:
		round_over()
	else:
		var next_player := _cur_player
		while true:
			next_player = (next_player + 1) % len(_players)
			if _players[next_player].is_active():
				break
		_cur_player = next_player
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
		if p.is_active():
			p.protected = false
			Animator.reveal_hand(p, false)
			max_type = max(max_type, p.hand.get_child(0).type)
	var round_winners: Array[int]
	var round_winners_str := ""
	var game_winners : Array[int]
	var game_winners_str := ""
	for p in _players:
		round_finished.emit(p.ai_level)
		if p.is_active() and p.hand.get_child(0).type == max_type:
			p.score += 1
			p.total_score += 1
			if !round_winners_str.is_empty():
				round_winners_str += ", "
			round_winners_str += str(p.idx)
			round_winners.append(p.idx)
			round_won.emit(p.ai_level)
			if p.score >= _max_score:
				if !game_winners_str.is_empty():
					game_winners_str += ", "
				game_winners_str += str(p.idx)
				game_winners.append(p.idx)
	save_stats.emit()
	if !game_winners.is_empty():
		flash_winners(game_winners)
		if 0 in game_winners:
			_game_won_audio_player.play()
		else:
			_game_over_audio_player.play()
		var s := "Game " + str(game_counter) + " over! Winners: " + game_winners_str + ". Total scores: "
		for p in _players:
			s += str(p.total_score) + ", "
		push_warning(s)
		_game_over_label.show()
		if !_players[0].is_human():
			await Animator.delay(8)
			_on_game_over_pressed()
	elif !round_winners.is_empty():
		flash_winners(round_winners)
		if 0 in round_winners:
			_round_won_audio_player.play()
		else:
			_round_over_audio_player.play()
		print("Round over! Winners are " + round_winners_str)
		_cur_player = round_winners[randi() % len(round_winners)]
		_round_over_label.show()
		if !_players[0].is_human():
			await Animator.delay(2)
			_on_round_over_pressed()


func flash_winners(indices: Array[int]) -> void:
	var nodes: Array[Node]
	for i in indices:
		nodes.append(_players[i].hand)
	await Animator.flash(500, nodes)


func _on_round_over_pressed() -> void:
	await Animator.flash(0, [])
	_round_over_label.hide()
	_new_round()


func _on_game_over_pressed() -> void:
	await Animator.flash(0, [])
	_game_over_label.hide()
	if _random_seed:
		_random_seed += 1
	_new_game()


# The move list. Classic: the seat holds 2 cards and chooses which one to play.
# Noble Family: the seat holds 1 card (the active one) and the mandatory family draw is part of
# the move, so a move is a (draw, play, target) triple enumerated over the pairs
# (active card, family[f]). A seat whose hand holds 2 cards in the variant is the human seat that
# was dealt its placeholder draw at turn start (step 20 replaces that with the modal), so it keeps
# the classic 2-card enumeration.
func find_valid_moves() -> Array[Move]:
	var result: Array[Move]
	var cp = _players[_cur_player]
	if noble_family and cp.hand.get_child_count() == 1:
		return _find_noble_moves(cp)
	var countess_idx = cp.countess_restricted()
	var cards: Array[Card] = [cp.hand.get_child(0), cp.hand.get_child(1)]
	if countess_idx != -1:
		# the Countess rule forces which card of the hand is played
		_append_play_moves(result, cp, cards[countess_idx], countess_idx, cards[1 - countess_idx].type)
	else:
		for i in cards.size():
			_append_play_moves(result, cp, cards[i], i, cards[1 - i].type)
	return result


# Noble Family: every (draw, play, target) triple for the seat holding 1 hand card. Family order
# is as-dealt (never sorted), which is what makes level 1 (`valid_moves[0]`) deterministic.
# `_played_card_idx`: 0 = the active card is played, 1 = the drawn family card is played.
func _find_noble_moves(cp: Player) -> Array[Move]:
	var result: Array[Move]
	var active: Card = cp.hand.get_child(0)
	var active_type: Deck.CardType = active.type
	for f in cp.family_size():
		var drawn_type: Deck.CardType = cp.family[f]
		# the Countess rule over the pair (active, family[f]) forces which card is played
		var forced: int = cp.countess_restricted_types(active_type, drawn_type)
		for play_idx in range(2):
			if forced != -1 and forced != play_idx:
				continue
			var played_card: Card = active if play_idx == 0 else null
			var leftover_type: Deck.CardType = drawn_type if play_idx == 0 else active_type
			_append_play_moves(result, cp, played_card, play_idx, leftover_type, f, drawn_type)
	return result


# Append every legal (target, type) move for playing one card of the pair, keeping `leftover_type`
# in hand. Shared by the classic enumeration (`played_card` is a real node, `drawn_family_idx` -1)
# and by the Noble Family joint enumeration (`played_card` is null when the DRAWN family card is
# the card being played, so its type is `drawn_type`). The target rules are the same for both:
# Guard -> active non-protected opponents x every guessable type, Priest/Baron/King -> active
# non-protected opponents, Handmaid/Countess -> self, Prince -> any active non-protected (self
# included). Princess is enumerated in the variant only: an AI never plays a Princess voluntarily,
# but a variant pair of two Princesses leaves nothing else, so it must be a legal move.
func _append_play_moves(result: Array[Move], cp: Player, played_card: Card, play_idx: int,
		leftover_type: Deck.CardType, drawn_family_idx: int = -1,
		drawn_type: Deck.CardType = Deck.CardType.Unknown) -> void:
	var played_t: Deck.CardType = played_card.type if played_card != null else drawn_type
	match played_t:
		Deck.CardType.Guard:
			for p in _players:
				if p.idx != cp.idx and p.is_active() and (!p.protected or _other_protected):
					for t in range(Deck.CardType.Priest, Deck.CardType.Unknown):
						result.append(Move.new(played_card, play_idx, p.idx, t,
							drawn_family_idx, drawn_type, leftover_type))
		Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
			for p in _players:
				if p.idx != cp.idx and p.is_active() and (!p.protected or _other_protected):
					result.append(Move.new(played_card, play_idx, p.idx, Deck.CardType.Unknown,
						drawn_family_idx, drawn_type, leftover_type))
		Deck.CardType.Handmaid, Deck.CardType.Countess:
			result.append(Move.new(played_card, play_idx, -1, Deck.CardType.Unknown,
				drawn_family_idx, drawn_type, leftover_type))
		Deck.CardType.Prince:
			for p in _players:
				if p.is_active() and !p.protected:
					result.append(Move.new(played_card, play_idx, p.idx, Deck.CardType.Unknown,
						drawn_family_idx, drawn_type, leftover_type))
		Deck.CardType.Princess:
			if drawn_family_idx != -1:
				result.append(Move.new(played_card, play_idx, -1, Deck.CardType.Unknown,
					drawn_family_idx, drawn_type, leftover_type))


func _on_menu_button_pressed() -> void:
	menu_pressed.emit()
