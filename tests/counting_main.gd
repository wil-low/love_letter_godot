extends Main
# Test-only `Main` subclass (same technique as tests/fake_deck.gd: installed with `set_script`,
# no production file is touched). It records the events a harness cannot see by polling:
# eliminations (`set_inactive`), round ends (`round_over`, with the seat that was to act) and
# family draws (`deal_from_family`, per seat, with the family INDEX each draw used).
#
# It also pairs moves with draws from INSIDE the play chain (`_on_move_chosen`, step 11): the family
# card a move enumerated must be the card that the same chain draws for that seat. That pairing
# cannot be made by polling the finished round - `move_chosen` fires before the chain animates the
# draw, so a sampler always sees the moves one ahead of the draws.
#
# Why polling fails: at `Animator._speed = 0` the whole chain
# "family draw -> play -> effect -> next turn" - and even "eliminate -> round_over -> label ->
# _new_round -> active = true" - can resolve inside a single frame, so hand sizes, `Player.active`
# and the round-over label all look unchanged between two samples, and events are dropped.

var eliminations: int = 0
var eliminated_seats: Array[int] = []
var round_end_actor: Array[int] = []
var family_draws: Array[int] = [0, 0, 0, 0]  # per seat, cumulative
var family_draw_idx: Array = [[], [], [], []]  # per seat, cumulative family INDICES drawn
var draw_mismatches: Array[String] = []  # moves whose draw did not deliver the named family card
var draws_checked: int = 0  # noble moves verified (move named index == index drawn)
var pile_draws: int = 0  # real pile draws (Deck.pop from the main pile / the widow): the variant never does this at turn start
var first_hand_deals: int = 0  # deal_card() with an explicit type = the animated first-hand card per seat
var round_start_actor: Array[int] = []  # per round: the seat that took the FIRST turn of that round
var round_end_turns: Array = []  # per round end: per-seat turn counts (cumulative)
# Snapshots taken INSIDE round_over(): the state a harness can never recover by polling, because
# `_on_round_over_pressed()` -> `_new_round()` re-deals families and re-builds `_left`, and at
# `_speed = 0` that can happen in the same frame the round ended.
var round_end_families: Array = []  # per round end: family size per seat
var round_end_hands: Array = []  # per round end: hand card count per seat
var round_end_left: Array = []  # per round end: a copy of Deck._left
var _round_start: int = -1  # the seat that opened the running round (-1 = round_over seen, no turn yet)
var _turn_counts: Array[int] = [0, 0, 0, 0]  # per seat, cumulative
# Per-effect snapshots (step 15: the Prince paths). `resolve_effect()` runs exactly ONCE per play,
# so one record == one play, in play order. The BEFORE snapshot is the state the effect acts on -
# the played card already sits on the table (so `_left` is not decremented yet) and the target's
# hand card is still in his hand. The AFTER snapshot is the settled state: the played card is
# discarded, the target has redrawn (family / widow / eliminated). That pair is what pins
# "the target's family size AT THE HIT" - a harness cannot read it by polling, because the whole
# effect chain resolves inside a few frames at `Animator._speed = 0`.
var effect_log: Array = []  # per play: {played, target, before, after, plays, prince_hits}


func set_inactive(p: Player, reveal_hand: bool = true) -> void:
	eliminations += 1
	eliminated_seats.append(p.idx)
	# must await: every caller in main.gd does `await set_inactive(...)`, and calling a coroutine
	# without await would let the game run on past the elimination
	await super(p, reveal_hand)


func round_over() -> void:
	# new_turn() / resolve_effect() call this without awaiting it, so a plain super() call keeps
	# the production flow exactly as it is
	round_end_actor.append(_cur_player)
	round_start_actor.append(_round_start)
	round_end_turns.append(_turn_counts.duplicate())
	_round_start = -1
	var fams: Array = []
	var hands: Array = []
	for p in _players:
		fams.append(p.family_size())
		hands.append(p.hand.get_child_count())
	round_end_families.append(fams)
	round_end_hands.append(hands)
	var left: Array = []
	for n in _deck._left.size():
		left.append(_deck._left[n])
	round_end_left.append(left)
	super()


# Every draw that comes from a pile (main pile / widow) - the Noble Family variant must never do
# this at turn start, it is how a harness proves the turn-start draw is a FAMILY draw only.
# An explicit `card_type` is the Noble Family FIRST-HAND deal (`_new_round` deals it through the
# animated deal path without popping anything), so it is counted separately.
func resolve_effect() -> void:
	var before := _snapshot()
	var played: int = _played_card
	var target: int = _target_player
	await super()
	var after := _snapshot()
	var hits := 0
	for r in effect_log:
		if int(r["played"]) == Deck.CardType.Prince:
			hits += 1
	if played == Deck.CardType.Prince:
		hits += 1
	effect_log.append({
		"played": played,
		"target": target,
		"before": before,
		"after": after,
		"plays": effect_log.size() + 1,  # this play is #N in the log, 1-based
		"prince_hits": hits,  # Prince plays in the log INCLUDING this one
	})


func _snapshot() -> Dictionary:
	var fams: Array = []
	var hands: Array = []
	var active: Array = []
	for p in _players:
		fams.append(p.family_size())
		hands.append(p.hand.get_child_count())
		# is_active(), not `active`: a Disabled seat keeps `active == true` (`_new_round` sets it for
		# every seat) and holds no card at all - only a live seat owes the 1-card hand invariant
		active.append(p.is_active())
	var left: Array = []
	var left_sum := 0
	for n in _deck._left.size():
		left.append(_deck._left[n])
		left_sum += int(_deck._left[n])
	var fam_sum: int = 0
	var hand_sum: int = 0
	for i in fams.size():
		fam_sum += int(fams[i])
		hand_sum += int(hands[i])
	# A played card sits on the table until `discard(_table)` runs, and `Deck.discard()` is the ONLY
	# thing that decrements `_left`, so:
	#   _left == main pile + widow + every family + every hand + the cards on the table
	# which is what makes the main pile size (that Deck exposes no accessor for) derivable.
	var on_table := 0
	for ch in _table.get_children():
		if ch is Card:
			on_table += 1
	return {
		"fams": fams,
		"hands": hands,
		"active": active,
		"widow": _deck._widow_cards.size(),
		"widow_visible": _deck._widow.visible,
		"on_table": on_table,
		"left": left,
		"left_sum": left_sum,
		"main_pile": left_sum - _deck._widow_cards.size() - fam_sum - hand_sum - on_table,
	}


func deal_card(p: Player, allow_widow: bool = false,
		card_type: Deck.CardType = Deck.CardType.Unknown) -> void:
	if card_type == Deck.CardType.Unknown:
		pile_draws += 1  # this one pops the main pile / the widow
	else:
		first_hand_deals += 1
	await super(p, allow_widow, card_type)


# Turn counting, so a harness can say how long a round was: `new_turn()` is called once per turn,
# and the family-out rule makes the LAST call of a round the one that ends it (13 in a 4p round of
# 3-card families: 12 plays + the turn that found an empty family).
func new_turn():
	if _round_start < 0:
		_round_start = _cur_player
	_turn_counts[_cur_player] += 1
	super()


func deal_from_family(p: Player, family_idx: int) -> void:
	family_draws[p.idx] += 1
	family_draw_idx[p.idx].append(family_idx)
	# the index too: a Noble Family move names the family card it draws (step 11), so a harness can
	# compare the indices a seat's played moves named with the indices actually drawn. A seat's
	# family reveal on elimination is `reveal_family`, which draws every remaining card in order
	await super(p, family_idx)


# The move/draw pairing, checked INSIDE the play chain (`Main` calls its own method, so the
# subclass override is the one that runs): the family card this move enumerated must be exactly the
# card that this chain draws for this seat. Sampling from the harness cannot make this pairing -
# the `move_chosen` signal fires before the chain animates the draw, so at any sample point the
# recorded moves are one ahead of the recorded draws. A chain abandoned by a round end never
# resumes, so such a move is not counted (its draw never happened either).
func _on_move_chosen(move: Move) -> void:
	var seat: int = _cur_player
	var named: int = move._drawn_family_idx
	var pos: int = family_draw_idx[seat].size()
	await super(move)
	if named < 0:  # a classic Move (the eliminated seat's forced resign play) draws no family card
		return
	draws_checked += 1
	if family_draw_idx[seat].size() <= pos:
		draw_mismatches.append("seat " + str(seat) + " played a move naming family index " + str(named) +
			" and the play chain drew NO family card")
	elif family_draw_idx[seat][pos] != named:
		draw_mismatches.append("seat " + str(seat) + " played a move naming family index " + str(named) +
			" but the play chain drew family index " + str(family_draw_idx[seat][pos]))


# `draw_mismatches` is TYPED, so a harness must not assign a plain [] to it: Godot rejects the
# untyped array ("Invalid assignment of property or key 'draw_mismatches'"), and the script error
# kills the caller's frame - which silently skips everything after the assignment in that frame.
# Reset it through a method call instead.
func clear_draw_mismatches() -> void:
	draw_mismatches.clear()
