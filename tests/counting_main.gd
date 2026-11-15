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

# ─── Step 23: the family deal presentation ──────────────────────────────────────────────────
# What step 23 promises is a property of the DEAL, so it is recorded from inside the deal:
#
# 1. ONE slide sound for the whole family batch (`Main.deal_sound()` in `_new_round()`, not one per
#    family card). Counting it needs a seam, and the seam production already has: EVERY deal sound in
#    the game is asked for through `Main.deal_sound()`, so the harness overrides THAT and counts the
#    calls, then calls `super()` - the real `AudioStreamPlayer` plays, at the real call sites, on the
#    real path. (A `play()` override on an AudioStreamPlayer subclass is not an option: Godot 4.7
#    rejects it - "The method play() overrides a method from native class AudioStreamPlayer" is a
#    warning treated as an error - so the only way to count a sound is to count the call that asks for
#    it, which is exactly what a batch rule is about.)
#    Per round: `sounds == first_hand + pile_draws + family_draws + family_batch`, and the variant's
#    batch term is EXACTLY 1 (the classic branch has no families, so its batch term is 0 - the pair is
#    what pins "one sound for the batch": a per-card batch would make the term 12).
# 2. How long the deal takes, at the speed the game is played at. `_new_round()` IS the deal and the
#    round's FIRST turn is the first thing that runs after it settled, so the gap between those two
#    stamps is what a player waits through. The noble deal animates ONLY the first-hand cards (the
#    families are data + a stack, materialized in one instant), so the noble gap equals the classic
#    gap: the family batch adds 0 ms of animation. Measured at `_speed = 2` (the setting menu calls
#    speed 1) and at `_speed = 5`, plus the classic control at the same speed and seat count.
# 3. How many card flights ever run at once. Every deal/draw path animates one card at a time
#    (`deal_card`, `deal_from_family`), so the peak is 1; an animated family deal would show 5/4/3.
#    It is a counter around `super()`, not a frame sampler: at `_speed = 0` a whole round can resolve
#    inside ONE frame, so a per-frame peak reads 0 (the progress-notes lesson).
var deal_sounds: int = 0  # every `deal_sound()` call of the game (the batch term is the part of it no card flight asked for)
var setup_ms: Array[int] = []  # per round: ms from `_new_round()` entry to that round's FIRST turn
var deal_states: Array = []  # per round: what the DEAL left behind, sampled at that round's FIRST turn
var round_deal_stats: Array = []  # per round end: {audio, first_hand, pile_draws, family_draws, batch, setup_ms}
var inflight_max: int = 0  # the most card flights that ever ran at the same time
var _setup_t0: int = -1
var _inflight: int = 0
var _base_audio: int = 0  # the counters as `_new_round()` found them (a round's own deal is INSIDE
var _base_fh: int = 0     # its own delta, so the base is taken BEFORE the deal, at `_new_round()` entry)
var _base_pile: int = 0
var _base_fam: int = 0


# Todo step 23: the deal's sound, counted at the seam production asks for it through. `super()` runs,
# so the sound itself is the production one, played at the production call sites.
var left_audits_total: int = 0  # cumulative `left_audits` at every audit - TEST M reports it


# TEST M (todo step 25) seam: the mode must be set BEFORE the deal is decided, because `_new_round()`
# reads `noble_family` exactly once, there. `init_players()` is the call that decides a deal, so the
# flag is recorded on its ENTRY - a handler that set the mode after the call records the old value.
# The panel state is recorded in the same snapshot: the deal must not run under an open menu.
var init_calls: int = 0
var init_seams: Array = []  # per init_players() ENTRY: {noble, interrupted, main_visible,
# picker_visible, start_visible, rows_in_tree} (-1 = this Main has no mode picker around it)


# A coroutine override that AWAITS the parent: production calls `init_players()` WITHOUT `await` (in
# `Application.start_game()` and in the `speed_run` boot path) and the parent IS a coroutine, so that
# stays exactly as it was; but the fixtures call `await main.init_players(seed)` and depend on the await
# covering the whole deal chain. A plain `super()` here makes the override non-coroutine, the await
# returns at once, and every deal-settling fixture reads a game that has not been dealt yet (it showed
# up as empty families and `575 plays`). `await super(...)` keeps the parent's coroutine resumable.
func init_players(random_seed: int) -> void:
	init_calls += 1
	var par: Node = get_parent()
	var gm: Node = null
	var st: Node = null
	if par != null:
		gm = par.get_node_or_null("GameMode")
		st = par.get_node_or_null("Start")
	var rows := -1
	if gm != null:
		rows = 0
		for row: String in ["ClassicRow", "NobleRow", "BackRow"]:
			var r: Node = gm.get_node_or_null(row)
			if r != null and (r as Control).is_visible_in_tree():
				rows += 1
	init_seams.append({
		"noble": noble_family,
		"interrupted": interrupted,
		"main_visible": visible,
		"picker_visible": (gm != null and gm.visible),
		"start_visible": (st != null and st.visible),
		"rows_in_tree": rows,
	})
	await super(random_seed)


func deal_sound() -> void:
	deal_sounds += 1
	super()


func _family_draw_sum() -> int:
	var n: int = 0
	for i in family_draws.size():
		n += int(family_draws[i])
	return n


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
# The step 23 deal record: the deltas of this round's counters, measured against the stamps
# `_new_round()` took at its own entry (so the round's OWN deal - the animated first-hand cards, the
# family batch sound and every family draw of the round - is inside the delta), plus the wall-clock of
# the deal that opened this round.
func _record_deal_stats() -> void:
	var fam_sum: int = _family_draw_sum()
	var audio: int = deal_sounds - _base_audio
	var fh: int = first_hand_deals - _base_fh
	var pile: int = pile_draws - _base_pile
	var fam: int = fam_sum - _base_fam
	round_deal_stats.append({
		"audio": audio,
		"first_hand": fh,
		"pile_draws": pile,
		"family_draws": fam,
		"batch": audio - fh - pile - fam,  # the sound(s) the deal made that NO card animation asked for
		"setup_ms": setup_ms[setup_ms.size() - 1] if not setup_ms.is_empty() else -1,
	})


func _record_round_end() -> void:
	_record_deal_stats()
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
	# Todo step 23: the elimination is a WINDOW, not an instant - `set_inactive` clears the seat's face,
	# then reveals the hand, then the family, then discards both, then clears the family data, and every
	# one of those steps leaves a state a frame sampler could read as "the stack does not mirror the
	# data" (an out seat with 3 family cards and no nodes exists for the frames before `reveal_family`
	# runs). The per-frame mirror watcher skips these frames (step 16/19 own the reveal window); the
	# `_left` audit already skips them for the same reason.
	reveal_depth += 1
	# must await: every caller in main.gd does `await set_inactive(...)`, and calling a coroutine
	# without await would let the game run on past the elimination
	await super(p, reveal_hand)
	reveal_depth -= 1


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


# The state a round's DEAL leaves behind (todo step 23). The counters are cumulative on purpose: a
# round's own deal is inside them, so the harness takes the delta against `round_deal_stats`.
func _deal_snapshot() -> Dictionary:
	var fams: Array = []
	var stacks: Array = []
	var hands: Array = []
	for p in _players:
		fams.append(p.family_size())
		stacks.append(p.family_root.get_child_count())
		hands.append(p.hand.get_child_count())
	var left: Array = []
	var left_sum: int = 0
	for n in _deck._left.size():
		left.append(_deck._left[n])
		left_sum += int(_deck._left[n])
	return {
		"fams": fams,
		"stacks": stacks,
		"hands": hands,
		"main_pile": _deck._cards.size(),
		"widow": _deck._widow_cards.size(),
		"widow_visible": bool(_deck._widow.visible),
		"left": left,
		"left_sum": left_sum,
		"audio": deal_sounds,
		"first_hand": first_hand_deals,
		"setup_ms": setup_ms[setup_ms.size() - 1] if not setup_ms.is_empty() else -1,
	}


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
	_inflight += 1
	inflight_max = maxi(inflight_max, _inflight)
	await super(p, allow_widow, card_type)
	_inflight -= 1


# Todo step 23: the round's deal. The wall-clock stamps and the per-round counter bases are taken at
# its ENTRY (before `_build_deck()`/`prepare_noble()` and before the animated first-hand cards), the
# deal is measured around `super()`, and the flight peak is a counter, not a frame sample.
func _new_round() -> void:
	_setup_t0 = Time.get_ticks_msec()
	_base_audio = deal_sounds
	_base_fh = first_hand_deals
	_base_pile = pile_draws
	_base_fam = _family_draw_sum()
	await super()


# Turn counting, so a harness can say how long a round was: `new_turn()` is called once per turn,
# and the family-out rule makes the LAST call of a round the one that ends it (13 in a 4p round of
# 3-card families: 12 plays + the turn that found an empty family).
func new_turn():
	if _round_start < 0:
		_round_start = _cur_player
		if _setup_t0 >= 0:
			# the deal of this round, measured on the wall clock: `_new_round()` entry -> its FIRST turn
			setup_ms.append(Time.get_ticks_msec() - _setup_t0)
			_setup_t0 = -1
		# The deal as the round's first seat sees it before it draws anything: family sizes, stack node
		# counts, the piles the burn left behind, `_left`, and the deal's sound count. Sampled HERE
		# (`new_turn()` runs at the tail of `_new_round()`, before the seat draws or plays) because at
		# `_speed = 0` the whole deal + the first turn can resolve inside one frame, so a harness poll
		# cannot catch the dealt state from outside.
		deal_states.append(_deal_snapshot())
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
	if noble_family and !p.is_human() and p.hand.get_child_count() == 1:
		# step 31: the ENUMERATED list is checked in the very state production enumerates it from
		check_enumeration(p)
	super(p)


func deal_from_family(p: Player, family_idx: int) -> void:
	family_draws[p.idx] += 1
	family_draw_idx[p.idx].append(family_idx)
	_inflight += 1
	inflight_max = maxi(inflight_max, _inflight)
	# the index too: a Noble Family move names the family card it draws (step 11), so a harness can
	# compare the indices a seat's played moves named with the indices actually drawn. A seat's
	# family reveal on elimination is `reveal_family`, which draws every remaining card in order
	await super(p, family_idx)
	_inflight -= 1


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
	# step 31: the play log is the log a determinism check compares, so it is recorded at the SAME
	# seam the legality rail uses - the committed triple, before the chain animates anything.
	move_log.append("s" + str(seat) + " lvl" + str(int(_players[seat].ai_level)) + " " + str(move))
	if named >= 0:
		rail_checks += 1
		for msg in joint_legality(move, seat):
			rail_failures.append("committed move s" + str(seat) + " " + str(move) + ": " + msg)
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


# ─── Step 31 (todo §D.31): joint move legality in REAL games, and the play log ───────────────
# The todo's step 31 line is "joint move legality (every enumerated move plays a card the seat can
# legally play, Countess forced when required); L1 determinism under a fixed seed". Two rails:
#
# 1. `check_enumeration()` runs on the ENUMERATED LIST, at the seam production decides in
#    (`_begin_play_selection`, i.e. `find_valid_moves()` -> `ai_move()` on the live board). A list
#    is a joint move list only in the variant with a 1-card hand, so a classic enumeration and a
#    human's post-modal 2-card enumeration are out of its scope (TEST B and TEST H pin those).
#    Every emitted move is checked, and every family index whose pair is a Countess + man pair is
#    counted with the flavour of the force (play the ACTIVE Countess / play the DRAWN Countess) -
#    that is what makes "forced when required" a measured number and not a code reading.
# 2. `joint_legality()` runs on the COMMITTED move, at `_on_move_chosen` BEFORE the chain animates
#    the draw, so the family array and the 1-card hand it reads are the state the move was chosen
#    from. `move_log` records the same triple, in commit order: the determinism gate compares logs.
#
# THE RULE IS STATED HERE, NOT READ OFF `Main`: a rail that reads `_other_protected` agrees with a
# buggy enumerator by construction, so the protection rule is restated from the rules - naming a
# protected opponent is LEGAL only when every other active seat is protected (the classic
# everyone-hid-behind-a-Handmaid case).
var rail_checks: int = 0
var rail_failures: Array[String] = []
var enum_decisions: int = 0
var enum_moves_checked: int = 0
var enum_forced_pairs: int = 0
var enum_forced_active: int = 0   # the pair forces the ACTIVE card (the Countess sits in hand)
var enum_forced_drawn: int = 0     # the pair forces the DRAWN card (the Countess is the family card)
var enum_failures: Array[String] = []
var move_log: Array[String] = []  # one line per COMMITTED move, in commit order


# Every property one joint move must have, on the live board, in the state its seat decided from.
func joint_legality(m: Move, seat: int) -> Array[String]:
	var p: Player = _players[seat]
	var v: Array[String] = []
	if not m.is_noble():
		v.append("names no family draw (_drawn_family_idx == -1), so it is not a joint move")
	var fam_idx: int = m._drawn_family_idx
	var drawn_t: Deck.CardType = m._drawn_type
	if fam_idx < 0 or fam_idx >= p.family_size():
		v.append("names family index " + str(fam_idx) + " of a family of " + str(p.family_size()))
	elif p.family[fam_idx] != drawn_t:
		v.append("names family[" + str(fam_idx) + "] as " + Deck.card_names[int(drawn_t)]
			+ ", that slot is " + Deck.card_names[int(p.family[fam_idx])])
	var hand_n: int = p.hand.get_child_count()
	if hand_n != 1:
		v.append("decides with " + str(hand_n) + " cards in hand, the variant seat holds the 1 active card")
	var active_t: Deck.CardType = Deck.CardType.Unknown
	if hand_n > 0:
		active_t = p.hand.get_child(0).type
	var idx: int = m._played_card_idx
	var played_t: Deck.CardType = m.played_type()
	if idx != 0 and idx != 1:
		v.append("_played_card_idx == " + str(idx) + ", 0 = the active card / 1 = the drawn one")
	if played_t != active_t and played_t != drawn_t:
		v.append("plays " + Deck.card_names[int(played_t)] + ", which is neither the active card ("
			+ Deck.card_names[int(active_t)] + ") nor the drawn one (" + Deck.card_names[int(drawn_t)] + ")")
	var keep: Deck.CardType = drawn_t if idx == 0 else active_t
	if m._leftover_type != keep:
		v.append("keeps " + Deck.card_names[int(m._leftover_type)] + ", the pair leaves "
			+ Deck.card_names[int(keep)])
	var forced: int = p.countess_restricted_types(active_t, drawn_t)
	if forced != -1 and forced != idx:
		v.append("plays the man of a Countess + man pair (the Countess is forced, forced idx "
			+ str(forced) + ", played idx " + str(idx) + ")")
	if idx == 1 and m._played_card != null:
		v.append("carries a hand node for a play of the DRAWN card, which has no node at decision time")
	if idx == 0 and (m._played_card == null or m._played_card.get_parent() != p.hand):
		v.append("plays the active card without naming this seat's hand node")
	var tgt: int = m._target_player
	var all_others_protected: bool = true
	for pl in _players:
		if pl.is_active() and !pl.protected and pl.idx != seat:
			all_others_protected = false
	match played_t:
		Deck.CardType.Guard:
			if tgt == seat or tgt < 0 or tgt >= _players.size():
				v.append("a Guard probes seat " + str(tgt) + ", which is not an opponent")
			elif tgt >= 0 and tgt < _players.size() and _players[tgt].protected \
						and not all_others_protected:
					v.append("a Guard probes protected seat " + str(tgt)
						+ " while an unprotected opponent is available")
			elif m._target_type < Deck.CardType.Priest or m._target_type > Deck.CardType.Princess:
				v.append("a Guard names " + Deck.card_names[int(m._target_type)]
					+ ", the guessable types are Priest..Princess")
		Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
			if tgt == seat or tgt < 0 or tgt >= _players.size():
				v.append(Deck.card_names[int(played_t)] + " targets seat " + str(tgt)
					+ ", which is not an opponent")
			elif tgt >= 0 and tgt < _players.size() and _players[tgt].protected \
						and not all_others_protected:
					v.append(Deck.card_names[int(played_t)] + " targets protected seat " + str(tgt)
						+ " while an unprotected opponent is available")
		Deck.CardType.Prince:
			if tgt < 0 or tgt >= _players.size():
				v.append("a Prince targets seat " + str(tgt)
					+ ", any active seat including self")
			elif _players[tgt].protected:
				v.append("a Prince targets protected seat " + str(tgt))
		Deck.CardType.Handmaid, Deck.CardType.Countess, Deck.CardType.Princess:
			if tgt != -1:
				v.append(Deck.card_names[int(played_t)] + " targets seat " + str(tgt)
					+ ", this card is played on self")
	if tgt >= 0 and tgt < _players.size() and not _players[tgt].is_active():
		v.append("targets seat " + str(tgt) + ", who is out of the round")
	return v


# The enumerated list of the seat that is about to decide, checked move by move. Production calls
# `find_valid_moves()` itself inside `super(p)`; calling it here costs one extra list build and no
# state change (it reads the board and allocates Moves), so the list checked is the list played.
func check_enumeration(p: Player) -> void:
	enum_decisions += 1
	var moves: Array[Move] = find_valid_moves()
	var active_t: Deck.CardType = p.hand.get_child(0).type
	# family index -> {forced, plays, bad}, `plays` counts the moves the enumeration emits for that
	# draw and `bad` the ones that play a card other than the forced one
	var per_draw: Dictionary = {}
	for m in moves:
		enum_moves_checked += 1
		for msg in joint_legality(m, p.idx):
			enum_failures.append("enumerated move s" + str(p.idx) + " " + str(m) + ": " + msg)
		var f: int = m._drawn_family_idx
		if not per_draw.has(f):
			per_draw[f] = {"forced": p.countess_restricted_types(active_t, m._drawn_type),
				"plays": 0, "bad": 0}
		per_draw[f]["plays"] = int(per_draw[f]["plays"]) + 1
		if int(per_draw[f]["forced"]) != -1 and int(per_draw[f]["forced"]) != m._played_card_idx:
			per_draw[f]["bad"] = int(per_draw[f]["bad"]) + 1
	for f in per_draw.keys():
		var forced: int = int(per_draw[f]["forced"])
		if forced == -1:
			continue
		enum_forced_pairs += 1
		if forced == 0:
			enum_forced_active += 1
		else:
			enum_forced_drawn += 1
		if int(per_draw[f]["bad"]) > 0:
			enum_failures.append("family[" + str(f) + "] of seat " + str(p.idx) + " is a Countess + man"
				+ " pair and " + str(int(per_draw[f]["bad"])) + " of its " + str(int(per_draw[f]["plays"]))
				+ " enumerated moves play the man")


# ─── Step 31: a fixture-side way to END a game ───────────────────────────────────────────────
# A Noble Family game runs forever: `round_over()` auto-presses its own round-over label in an AI
# game, `_on_round_over_pressed()` -> `_new_round()` -> the next deal, and the production stop is
# `max_games` (a const, 1000 games). A determinism fixture builds several whole games in ONE frame,
# so a game that is never stopped keeps churning rounds for the rest of the suite - and a round end
# spends global RNG (`_cur_player = round_winners[randi() % len(...)]`), so churning fixtures move
# the RNG stream of every later fixture. `Main` exposes no stop, so the harness gates the two
# presses the game loop is made of: once the fixture has the rounds it asked for, the gate returns
# WITHOUT starting the next round and the main goes idle with no suspended coroutine, which is the
# state a fixture can safely `remove_child()` + `queue_free()` from.
# `stop_after_rounds == 0` (the default, every fixture that does not ask) leaves both presses
# exactly as they were.
var stop_after_rounds: int = 0
var stopped: bool = false


func _on_round_over_pressed() -> void:
	if stop_after_rounds > 0 and round_end_actor.size() >= stop_after_rounds:
		stopped = true
		return
	await super()


func _on_game_over_pressed() -> void:
	if stop_after_rounds > 0 and round_end_actor.size() >= stop_after_rounds:
		stopped = true
		return
	await super()
