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
