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
var effect_log: Array = []  # per play: {played, target, target_type, before, after, plays, prince_hits}
# Step 16 (elimination reveal) recorders. `Main.reveal_out_family()` materializes the out seat's
# family as Card nodes IN HIS OWN STACK (`Player.family_root`, the node step 18 makes the human seat's
# private menu), so the only way to see them is from INSIDE the call: production discards those exact
# nodes right after it returns, and at `_speed = 0` the whole reveal + discard chain can settle within
# one frame (the stack NODE lives on - it is part of the seat scene). One record per CALL (an empty
# family records 0 cards), which is also the proof that the reveal is called exactly once per
# elimination.
var reveal_log: Array = []  # per reveal call: {seat, shown, family_size, container, pos, parent_is_seat, cards}
var reveal_calls: int = 0  # every call, empty families included
# Every card that left play through `Main.discard()` - the ONLY `_left` decrement in the game.
# Summing it and comparing with the scripted supply minus `_left` is what proves a card is counted
# exactly once (the "no double decrement" gate) - `_left` alone cannot show it.
var discard_log: Array = []  # per discard() call that had cards: {container, cards: [{type, faceup}], kind}
var discarded: Array[int] = [0, 0, 0, 0, 0, 0, 0, 0]  # per CardType, cumulative
var debug_discards: bool = false  # per-call `_left` trace, for a fixture that needs to SEE the decrements

# ─── Step 17: the continuous `_left` audit ─────────────────────────────────────────────────
# The accounting rule the whole variant rests on, stated as something a harness can check at ANY
# moment (the todo's `sum(_left) == 16 - played` is only true on a round with no Prince hit and no
# elimination, so it is not the invariant - see the derivation below):
#
#   1. `Main.discard()` is the ONLY decrement of `Deck._left` in the game (`Deck.pop()` hands a card
#      out of the main pile / the widow and decrements NOTHING, and a family pop touches the Deck
#      not at all), and `Deck._build_deck()` resets `_left` to the full 16-card supply at the start
#      of every round, so for every type t, at every settled moment of a round:
#          _left[t] == supply_at_round_deal[t] - (cards of type t discarded since that deal)
#      Per TYPE, not just as a sum: a double decrement of Guard and a missed decrement of Priest
#      cancel out in a sum check and are invisible there. `discarded[]` (above) is the discard side.
#      The identity is exactly todo step 4's "a family draw decrements nothing" plus step 16's "a
#      revealed family is discarded through `discard()`, exactly once": the supply shrinks exactly as
#      fast as cards leave play, never faster, never slower.
#   2. Every card counted in `_left` sits in exactly ONE home, and every home holds exactly one
#      `_left` card:
#          sum(_left) == main pile + widow + every family + every hand + the table + cards in flight
#      Family cards ARE in `_left` (a family draw pops the data and touches nothing in the Deck);
#      a played card stays in `_left` until its `discard()` runs. So this identity catches a card
#      that left the supply without being discarded (an invented card) and a card that vanished
#      (a family pop that materialized no node), which identity 1 alone cannot see.
#
# The supply baseline is read from `_deck._left` at the running round's FIRST TURN (the state
# `_new_round()` leaves behind: deck rebuilt, families dealt, one first-hand card per seat, the
# previous round's table and hands discarded) and the cumulative counters are snapshotted at the
# same moment, so the identity is measured per round and holds at every audit point in between.
#
# Why the audit skips: inside `discard()` the decrement happens card by card at the START of each
# card's animation while the card node is still a child of its container, and
# `reveal_out_family()` materializes nodes for cards that are still in `p.family` - so both views
# double-count for a moment. An audit taken there would be a false positive, so the audit is
# skipped while a `discard()` / `reveal_out_family()` call is in flight and `left_skips` counts
# those skips (a suite that reports 0 audits, or a huge skip count, is not auditing anything).
#
# Two more deliberate skips, both counted: (a) BETWEEN the rounds - `_new_round()` is mid-flight
# (discarding the table and the live hands, re-dealing, animating the first-hand cards), so there is
# no settled supply to measure and a baseline taken there would capture a half-dealt state; only
# `new_turn()` opens a round; (b) on a SCRIPTED deck - the `FakeDeckScript` of
# `tests/noble_family_rules.gd` is a hand-written fiction whose `_left` is a SHAPE its fixtures
# assert: its `deal_card()` decrements `_left.find(true)` (the type with the most left, NOT the type
# it hands out) and its supply is an arbitrary multiset. Identity 1 is a statement about the REAL
# deck's accounting, so on a scripted deck the audit skips; those fixtures keep their own exact
# per-type end checks (`NOBLE_ROUND_END_LEFT`, `END_LEFT`, ...), written against that shape.
var left_violations: Array[String] = []  # every failed identity, with the audit point's tag
var left_audits: int = 0  # audits that ran the identities to completion
var left_skips: int = 0  # audits skipped because a discard / reveal animation was in flight
var discards_by_kind: Array[int] = [0, 0, 0, 0]  # cumulative, per discard() container: 0 = table (played cards), 1 = a seat's hand, 2 = a revealed family, 3 = anything else
var round_end_records: Array = []  # per round end: {left, discarded, kinds, base_left, base_discarded, base_kinds, audited, settled, pile_draws, left_sum, base_sum}
var _base_left: Array[int] = []  # `_left` as dealt at the running round's first turn
var _base_discarded: Array[int] = []  # `discarded` at that same moment
var _base_kinds: Array[int] = []  # `discards_by_kind` at that same moment
var _round_open: bool = false  # the running round has a baseline
var discard_depth: int = 0  # >0: a discard() animation is in flight (transient double view)
var reveal_depth: int = 0  # >0: revealed family nodes exist next to the family data


func _copy_ints(src) -> Array[int]:
	# elementwise copy: the source is often a Variant Array read from a snapshot
	var out: Array[int] = []
	for v in src:
		out.append(int(v))
	return out


func _count_cards(node: Node) -> int:
	var n: int = 0
	if node == null:
		return 0
	for ch in node.get_children():
		if ch is Card:
			n += 1
	return n


func _discard_kind(from: Node2D) -> int:
	if from == _table:
		return 0  # the played card(s) on the table
	for p in _players:
		if from == p.family_root:
			return 2  # the revealed family stack (step 16) - the seat's own $Family node (step 18)
		if from == p.hand:
			return 1  # a Prince victim's hand card, a revealed (out) seat's hand card
	return 3  # anything else: a harness container (the fixtures discard hand nodes of their own)


# The baseline is the state the round's supply starts from: `_left` as the deck dealt it, plus the
# cumulative discard counters. Taken at the round's FIRST turn, i.e. after `_build_deck()` and after
# `_new_round()`'s own discards of the previous round's table/hands (which land in the cumulative
# counters and are therefore subtracted out by this baseline).
func _take_left_baseline() -> void:
	_base_left = _copy_ints(_deck._left)
	_base_discarded = _copy_ints(discarded)
	_base_kinds = _copy_ints(discards_by_kind)
	_round_open = true


# The audit is a statement about the REAL deck's accounting (see the header). A fixture that runs
# `FakeDeckScript` has a `_left` that is scripted rather than counted, so there is nothing to audit.
func audit_applies() -> bool:
	return _deck.get_script() == load("res://deck/deck.gd")


func audit_left(tag: String) -> void:
	if discard_depth > 0 or reveal_depth > 0:
		left_skips += 1
		return
	if not audit_applies():
		left_skips += 1
		return
	if not _round_open:
		# between the rounds: `_new_round()` is mid-flight (it discards the table and the live hands,
		# re-deals the families and animates the first-hand cards), so there is no supply to measure
		# against and a baseline taken here would capture a half-dealt state. Only `new_turn()` opens
		# a round, and it is the first thing that runs after the deal settled.
		left_skips += 1
		return
	left_audits += 1
	var bad: Array[String] = []
	var supply: int = 0
	for t in _deck._left.size():
		var used: int = int(discarded[t]) - int(_base_discarded[t])
		var want: int = int(_base_left[t]) - used
		supply += int(_deck._left[t])
		if used < 0:
			bad.append("more cards of type " + Deck.card_names[t] + " discarded (" + str(used)
				+ ") inside the running round than the baseline records: the discard counter moved"
				+ " backwards")
		if int(_deck._left[t]) != want:
			bad.append(Deck.card_names[t] + ": _left == " + str(_deck._left[t]) + ", expected "
				+ str(want) + " (dealt " + str(_base_left[t]) + " - " + str(used)
				+ " discarded). Per-type is the point: a double decrement of one type and a missed one"
				+ " of another cancel in a sum")
		if int(_deck._left[t]) < 0:
			bad.append(Deck.card_names[t] + ": _left is negative (" + str(_deck._left[t]) + ")")
	# identity 2: every `_left` card has exactly one home right now
	var main_pile: int = _deck._cards.size()
	var widow: int = _deck._widow_cards.size()
	var fams: int = 0
	var hands: int = 0
	for p in _players:
		fams += p.family_size()
		hands += p.hand.get_child_count()
	var on_table: int = _count_cards(_table)
	var inflight: int = _count_cards(_animation_layer)
	var homes: int = main_pile + widow + fams + hands + on_table + inflight
	if supply != homes:
		bad.append("sum(_left) == " + str(supply) + " but the supply has " + str(homes)
			+ " card(s): main pile " + str(main_pile) + ", widow " + str(widow) + ", families "
			+ str(fams) + ", hands " + str(hands) + ", table " + str(on_table) + ", in flight "
			+ str(inflight) + " - a card was counted into _left twice, destroyed twice, or"
			+ " materialized out of nowhere")
	for msg in bad:
		left_violations.append("[" + tag + "] " + msg)


# The per-round-end record the harness needs to make the same two identities assertable AFTER the
# round (the live `_deck._left` is already re-dealt by then): the supply at the round's deal, the
# cumulative discard counters at the round end, and whether a discard/reveal animation made the
# moment transient (then the harness skips the accounting checks for that round and counts it).
func _record_round_end() -> void:
	var left: Array[int] = _copy_ints(_deck._left)
	var left_sum: int = 0
	for v in left:
		left_sum += int(v)
	var base_sum: int = 0
	for v in _base_left:
		base_sum += int(v)
	round_end_records.append({
		"left": left,
		"discarded": _copy_ints(discarded),
		"kinds": _copy_ints(discards_by_kind),
		"base_left": _copy_ints(_base_left),
		"base_discarded": _copy_ints(_base_discarded),
		"base_kinds": _copy_ints(_base_kinds),
		"audited": audit_applies(),
		"pile_draws": pile_draws,
		"settled": discard_depth == 0 and reveal_depth == 0,
		"left_sum": left_sum,
		"base_sum": base_sum,
	})
	# the round is over: the NEXT round's first turn takes the next baseline (after `_new_round()`
	# discarded the table + hands and `_build_deck()` reset `_left`)
	_round_open = false


# The baseline the running round's accounting is measured against (`audit_left` takes it at the
# round's first turn). A fixture reads it to assert that the baseline IS the deal: on the real deck
# that is `Deck.card_count`, the 16-card supply, with nothing discarded yet.
func baseline_left() -> Array[int]:
	return _base_left


func baseline_kinds() -> Array[int]:
	return _base_kinds


func clear_left_violations() -> void:
	# TYPED, like `draw_mismatches`: a harness must not assign [] to it (see clear_draw_mismatches)
	left_violations.clear()


func reset_audit() -> void:
	left_audits = 0
	left_skips = 0
	clear_left_violations()
	discard_depth = 0
	reveal_depth = 0
	_round_open = false
	for i in discards_by_kind.size():
		discards_by_kind[i] = 0
	round_end_records = []
	_base_left = []
	_base_discarded = []
	_base_kinds = []


func set_inactive(p: Player, reveal_hand: bool = true) -> void:
	eliminations += 1
	eliminated_seats.append(p.idx)
	# must await: every caller in main.gd does `await set_inactive(...)`, and calling a coroutine
	# without await would let the game run on past the elimination
	await super(p, reveal_hand)


func reveal_out_family(p: Player, show: bool = true) -> Node2D:
	var family_size: int = p.family_size()
	reveal_depth += 1  # the materialized nodes sit NEXT TO the family data until the caller discards
	var root: Node2D = await super(p, show)
	reveal_depth -= 1
	reveal_calls += 1
	var rec := {
		"seat": p.idx,
		"shown": show,
		"family_size": family_size,
		"container": "null",
		"pos": Vector2(-1, -1),
		"parent_is_seat": false,
		"cards": [],
		"faceups": 0,  # how many revealed cards ended face-up
		"input_connections": 0,  # a display-only stack must connect no input_event at all
	}
	if root != null:
		rec["container"] = root.name
		rec["pos"] = root.position
		rec["parent_is_seat"] = root.get_parent() == p
		rec["is_seat_stack"] = root == p.family_root  # step 18: the reveal renders INTO the seat's own stack
		for c in root.get_children():
			if c is Card:
				if bool(c.faceup):
					rec["faceups"] = int(rec["faceups"]) + 1
				rec["input_connections"] = int(rec["input_connections"]) \
					+ c.input_event.get_connections().size()
				rec["cards"].append({
					"type": int(c.type),
					"faceup": bool(c.faceup),
					"x": int(c.position.x),
					"in_container": c.get_parent() == root,
					"global_x": int(c.global_position.x),
					"global_y": int(c.global_position.y),
				})
	reveal_log.append(rec)
	return root


func discard(from: Node2D) -> void:
	# snapshot BEFORE super(): production removes and frees these children as it animates them
	var cards: Array = []
	var types: Array = []
	for ch in from.get_children():
		if ch is Card:
			cards.append({"type": int(ch.type), "faceup": bool(ch.faceup)})
			types.append(int(ch.type))
			discarded[int(ch.type)] += 1
	var kind: int = _discard_kind(from)
	discards_by_kind[kind] += cards.size()
	discard_depth += 1  # from here the cards are decremented in _left AND still children of `from`
	var before: Array = _deck._left.duplicate(true)
	await super(from)
	discard_depth -= 1
	if debug_discards:
		print("  [discard] " + str(from.name) + " types=" + str(types) + " left " + str(before) + " -> "
			+ str(_deck._left))
	if !cards.is_empty():
		discard_log.append({"container": from.name, "cards": cards, "kind": kind})


func reset_step16() -> void:
	# TYPED fields (`discarded`) cannot be reset from a harness with `= []` - a typed-array
	# assignment is a runtime script error and it kills the rest of that frame.
	reveal_log = []
	discard_log = []
	reveal_calls = 0
	for i in discarded.size():
		discarded[i] = 0


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
	_record_round_end()  # the step 17 accounting snapshot of THIS round end (see audit_left)
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
	audit_left("effect #" + str(effect_log.size() + 1) + " before (the played card is on the table)")
	var played: int = _played_card
	var target: int = _target_player
	# `_target_type` must be read BEFORE super(): `resolve_effect()` ends with `new_turn()`, which resets
	# it to Unknown for the next turn, and at `_speed = 0` the whole next turn runs synchronously inside
	# that call - reading it after super() reports the NEXT turn's value, not this play's declaration.
	var target_type: int = _target_type
	await super()
	audit_left("effect #" + str(effect_log.size() + 1) + " after (the effect settled, next seat chosen)")
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
		"target_type": target_type,  # the Guard's declared type, captured inside this play's chain
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
	if not _round_open:
		# the FIRST turn of a round: `_new_round()` has dealt the supply and discarded the previous
		# round's cards, so this is the baseline the whole round's accounting is measured against
		_take_left_baseline()
	# every turn starts with a decision, so this is the "at every decision" hook the todo asks for:
	# the state the deciding seat reads (hand, family, `_left`) before it draws or plays anything
	audit_left("turn start, seat " + str(_cur_player))
	super()


# The pre-decision state: `find_valid_moves()` / `eval_moves()` / `ai_move()` all run inside this
# call, on exactly this board (for an AI seat in the variant the hand is 1 card and the family is
# the draw menu, and `_deck._left` is what `eval_moves` scores Guard guesses against).
func _begin_play_selection(p: Player) -> void:
	audit_left("pre-decision, seat " + str(p.idx) + " (hand " + str(p.hand.get_child_count())
		+ " cards, family " + str(p.family_size()) + ")")
	super(p)


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
	# the moment the seat COMMITS its (draw, play, target) triple, before the chain draws anything
	audit_left("decision, seat " + str(seat) + " plays " + Deck.card_names[int(move.played_type())]
		+ " and draws family #" + str(named))
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
