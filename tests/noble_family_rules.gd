extends Node2D
# Noble Family rules suite (docs/noble-family-todo.md §A.4).
#
# TEST A pins the deal table produced by Deck.prepare_noble():
#   burn/widow 3 / 1 / 0 for 2 / 3 / 4 players (4p has NO widow pile),
#   1 first-hand card per seat (not part of the family),
#   family 5 / 4 / 3 per seat, main pile leftovers 1 / 0 / 0,
#   conservation burn + first_hand + families + main_left == 16,
#   `_left` untouched at full counts (family / first-hand / widow cards are out of
#   the main pile only, not out of play),
#   the four piles together are an exact permutation of the 16-card deck - no card
#   duplicated, no card lost, no `Unknown` type in play.
#
# TEST B pins the joint (draw, play, target) enumeration of Main.find_valid_moves() in the
# variant: one state per scripted (active card, family, protection) setup, every emitted move
# checked against the pair it plays and against the target rules, with the total move counts
# written down by hand (68 / 4 / 17 / 2) instead of recomputed from the production code, plus the
# level 1-4 draw policies over an enumerated list.
#
# TEST C (todo step 14) runs a real 4-player variant GAME on a scripted deal with every seat on
# level 1 (deterministic: `valid_moves[0]` = draw family index 0, play the active card), with the
# `tests/fake_deck.gd` scripted-deal technique. The scripted 16 cards are Guard / Handmaid /
# Countess only, so NO play can ever eliminate anybody (a Guard probe declares Priest and no seat
# ever holds a Priest): the round can only end by the family-out rule, which is what the step 14
# gate asks for.
#
# Later steps append to this file: step 15 (Prince: family draw -> widow fallback -> elimination),
# step 16 (elimination reveal + discard accounting), step 31 (joint move legality, L1
# determinism). Those cases use the `tests/fake_deck.gd` scripted-deal technique;
# TEST A deliberately needs no Main scene at all, so the deal table is pinned
# independently of the game loop.
#
# Run:  godot --headless --path . tests/noble_family_rules.tscn
#       echo $?      # 0 = every check passed, 1 = a check failed

const DeckScene := preload("res://deck/deck.tscn")
const MainScene := preload("res://main/main.tscn")
const FakeDeckScript := preload("res://tests/fake_deck.gd")
const CountingMainScript := "res://tests/counting_main.gd"  # load()ed at runtime: preload() of a
# script that extends Main is a cyclic dependency (this harness preloads main.tscn)

const TRIALS: int = 200
const SEED: int = 20260607
const TOTAL_CARDS: int = 16

# TEST C: the scripted 4-player supply, in DEAL ORDER (Deck.prepare_noble() pops it as
# burn 0 -> first-hand seat 0..3 -> family column 0 seat 0..3 -> column 1 -> column 2).
# Slot i of a seat's family is played on his i-th turn and his last card is never played, so the
# played multiset is 5 Guard + 3 Handmaid + 4 Countess = 12 = 4 seats x family size 3.
const NOBLE_SCRIPTED: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Handmaid, Deck.CardType.Handmaid,
	Deck.CardType.Handmaid, Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Countess,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Countess,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Countess,
]
const NOBLE_SCRIPTED_LEFT: Array[int] = [8, 0, 0, 3, 0, 0, 5, 0]  # == the scripted multiset
const NOBLE_ROUND_END_LEFT: Array[int] = [3, 0, 0, 0, 0, 0, 1, 0]  # 16 - 12 plays

var _failed: int = 0
var _deck: Deck
var _c_plays: Array[int] = [0, 0, 0, 0]  # TEST C: plays per seat, counted on `move_chosen`
# main.gd / player.gd read these off the game's parent node, so the harness must expose them
var print_memory: bool = false
var print_valid_moves: bool = false
var _main  # untyped Main instance for TEST B (no init_players call, so no game loop runs)


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	seed(SEED)
	_deck = DeckScene.instantiate()
	add_child(_deck)

	await _test_deal_table()
	await _test_joint_moves()
	await _test_family_out_round_end()
	await await_frames(1)

	print("\n==========================")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print(str(_failed) + " CHECK(S) FAILED")
	print("==========================")
	get_tree().quit(1 if _failed > 0 else 0)


# ----------------------------------------------------------------------------------------
# TEST A: the noble deal table, for 2 / 3 / 4 players.
# ----------------------------------------------------------------------------------------
func _test_deal_table() -> void:
	print("\n########## TEST A: noble deal table (burn 3/1/0, first-hand 1/seat, ")
	print("family 5/4/3, main leftovers 1/0/0) ##########")
	for count: int in [2, 3, 4]:
		var burn: int = Deck.NOBLE_BURN[count]
		var fam: int = Deck.NOBLE_FAMILY_SIZE[count]
		var main_expected: int = TOTAL_CARDS - burn - count * (1 + fam)

		var ok_table: bool = burn + count * (1 + fam) <= TOTAL_CARDS
		var ok_widow := true
		var ok_widow_sprite := true
		var ok_first := true
		var ok_families := true
		var ok_main := true
		var ok_conservation := true
		var ok_left := true
		var ok_permutation := true
		var ok_typed := true

		for t in TRIALS:
			var families: Array = _deck.prepare_noble(count)

			# the widow is the burn pile; in 4p it does not exist at all
			ok_widow = ok_widow and (_deck._widow_cards.size() == burn)
			ok_widow_sprite = ok_widow_sprite and (_deck._widow.visible == (burn > 0))
			# 1 card per seat, dealt before the families, not part of any family
			ok_first = ok_first and (_deck.first_hand.size() == count)
			# one private family per seat, equal sizes, as-dealt order, typed
			ok_families = ok_families and (families.size() == count)
			for i in count:
				ok_families = ok_families and (families[i].size() == fam)
				ok_typed = ok_typed and (families[i] is Array[Deck.CardType])
			# leftovers stay in the main pile; the main sprite mirrors it
			ok_main = ok_main and (_deck._cards.size() == main_expected)
			ok_main = ok_main and (_deck._main.visible == (main_expected > 0))
			# burn + first-hand + families + main = the whole deck
			ok_conservation = ok_conservation and (
				burn + _deck.first_hand.size()
				+ family_cards_total(families)
				+ _deck._cards.size() == TOTAL_CARDS
			)
			# family dealing decrements nothing
			ok_left = ok_left and (_left_counts() == Deck.card_count)
			# the four piles are a permutation of the deck: no duplicate, none lost
			ok_permutation = ok_permutation and (_piles_multiset(families) == Deck.card_count)

		var prefix := (str(count) + "p: burn " + str(burn) + ", family " + str(fam)
			+ ", main " + str(main_expected))
		check(ok_table, prefix + ": deal table fits in 16 cards ("
			+ str(burn) + " + " + str(count) + " x (1 + " + str(fam) + ") <= 16)")
		check(ok_widow, prefix + ": widow holds exactly the " + str(burn)
			+ " burned card(s) over " + str(TRIALS) + " deals")
		check(ok_widow_sprite, prefix + ": widow sprite visible == (burn > 0)"
			+ (" (no widow pile in 4p)" if burn == 0 else ""))
		check(ok_first, prefix + ": exactly " + str(count) + " first-hand card(s), 1 per seat")
		check(ok_families, prefix + ": " + str(count) + " families of " + str(fam)
			+ " card(s) each, equal per seat")
		check(ok_typed, prefix + ": each family is an Array[Deck.CardType] (assignable to Player.family)")
		check(ok_main, prefix + ": main pile keeps " + str(main_expected) + " leftover card(s)")
		check(ok_conservation, prefix + ": conservation burn + first-hand + families + main == 16")
		check(ok_left, prefix + ": `_left` still equals Deck.card_count - dealing decrements nothing")
		check(ok_permutation, prefix + ": widow + first-hand + families + main is a permutation"
			+ " of the 16-card deck (no duplicate, none lost, no Unknown)")


# how many family cards a deal produced in total (all seats are checked equal above)
func family_cards_total(families: Array) -> int:
	var total := 0
	for f in families:
		total += (f as Array).size()
	return total


# `_left` as a plain Array[int], for elementwise comparison with Deck.card_count
func _left_counts() -> Array:
	var out: Array = []
	for n in _deck._left.size():
		out.append(_deck._left[n])
	return out


# multiset of every card the deal produced: main pile + widow + first-hand + all families
func _piles_multiset(families: Array) -> Array:
	var counts: Array = []
	for i in Deck.card_count.size():
		counts.append(0)
	var piles: Array = [_deck._cards, _deck._widow_cards, _deck.first_hand]
	for f in families:
		piles.append(f)
	for pile in piles:
		for c in pile:
			var t: int = c as int
			# an Unknown / out-of-range type in a pile means a card was invented by the deal
			if t < 0 or t >= counts.size():
				return [-1]
			counts[t] += 1
	return counts


# ----------------------------------------------------------------------------------------
# TEST B: the joint (draw, play, target) enumeration + the level 1-4 draw policies.
# A Main scene is instantiated but NEVER started (no init_players call), so the game loop does
# not run: the harness sets the seat's 1-card hand, his family and the protection flags by hand,
# then calls the production Main.find_valid_moves() and Player.select_move() on that state.
# ----------------------------------------------------------------------------------------
func _test_joint_moves() -> void:
	print("\n########## TEST B: joint (draw, play, target) moves (step 11) ##########")
	_main = MainScene.instantiate()
	add_child(_main)
	await await_frames(1)
	_main.noble_family = true
	# fills `_left` with the full counts, which is what eval_moves reads as `left_cards`
	_main._deck.prepare_noble(4)

	# ---- the expected counts, written out by hand (4 seats, nobody protected) ----
	# family [Baron, Handmaid, Princess] in as-dealt order, active card = Guard:
	#   f0 Baron    : Guard x 3 targets x 7 guesses = 21   Baron   x 3 targets = 3
	#   f1 Handmaid : Guard x 3 x 7 = 21                   Handmaid self        = 1
	#   f2 Princess : Guard x 3 x 7 = 21                   Princess self        = 1 (variant only)
	var fam_a: Array = [Deck.CardType.Baron, Deck.CardType.Handmaid, Deck.CardType.Princess]
	var moves_a: Array[Move] = _state(Deck.CardType.Guard, fam_a, 4, [false, false, false, false])
	check(moves_a.size() == 3 * 21 + 3 + 1 + 1, "Guard + family [Baron, Handmaid, Princess] (4p): "
		+ str(moves_a.size()) + " moves, expected " + str(3 * 21 + 3 + 1 + 1))
	check(legal_move_set(moves_a, Deck.CardType.Guard, fam_a, 4),
		"  ... every move plays a card of its own pair, names that draw, targets a legal seat")
	check(moves_a[0]._drawn_family_idx == 0 and moves_a[0]._played_card_idx == 0,
		"the first move draws family index 0 (as-dealt order) and plays the active card")

	# Countess + a man forces the Countess play; Countess + Princess is free, and the Princess
	# self-play exists in the variant enumeration only.
	var fam_b: Array = [Deck.CardType.Prince, Deck.CardType.King, Deck.CardType.Princess]
	var moves_b: Array[Move] = _state(Deck.CardType.Countess, fam_b, 4, [false, false, false, false])
	check(moves_b.size() == 1 + 1 + 2, "Countess + family [Prince, King, Princess] (4p): "
		+ str(moves_b.size()) + " moves, expected 1 + 1 + 2 = 4 (Countess forced twice)")
	check(legal_move_set(moves_b, Deck.CardType.Countess, fam_b, 4),
		"  ... no move plays the Prince/King next to the Countess")

	# 3 seats, both opponents protected: a Prince can only be played on the self seat, and a Guard
	# probe is allowed against a protected seat because every other seat is protected too
	#   f0 Handmaid : Prince on self = 1   Handmaid self = 1
	#   f1 Guard    : Prince on self = 1   Guard x 2 targets x 7 guesses = 14
	var fam_c: Array = [Deck.CardType.Handmaid, Deck.CardType.Guard]
	var moves_c: Array[Move] = _state(Deck.CardType.Prince, fam_c, 3, [false, true, true, false])
	check(moves_c.size() == 1 + 1 + 1 + 14, "Prince + family [Handmaid, Guard] (3p, both opponents "
		+ "protected): " + str(moves_c.size()) + " moves, expected 1 + 1 + 1 + 14 = 17")
	check(legal_move_set(moves_c, Deck.CardType.Prince, fam_c, 3),
		"  ... Prince reaches only the self seat, Guard probes reach the protected seats")

	# The pair that forces a Princess: two Princesses in one seat is impossible in classic (1 copy
	# in the deck) and reachable in the variant. The move list must not be empty - an empty list
	# would strand the seat with no move at all.
	var fam_d: Array = [Deck.CardType.Princess]
	var moves_d: Array[Move] = _state(Deck.CardType.Princess, fam_d, 2, [false, false, false, false])
	check(moves_d.size() == 2, "Princess + family [Princess] (2p): " + str(moves_d.size())
		+ " moves, expected 2 (both cards of the pair are a Princess)")
	check(not moves_d.is_empty() and legal_move_set(moves_d, Deck.CardType.Princess, fam_d, 2),
		"  ... the forced Princess play is a legal self-targeted move, so a seat never has zero moves")

	# A 2-card hand in the variant is the human placeholder path (step 20 replaces it with the
	# modal): classic enumeration, no draws, no Princess play.
	var moves_e: Array[Move] = _state_2_cards(Deck.CardType.Guard, Deck.CardType.Baron, 4)
	check(moves_e.size() == 3 * 7 + 3, "variant seat with a 2-card hand (human placeholder): "
		+ str(moves_e.size()) + " moves, expected Guard 3 x 7 + Baron 3 = 24")
	var no_draws := true
	for m in moves_e:
		no_draws = no_draws and not m.is_noble()
	check(no_draws, "  ... a 2-card hand enumerates classic Moves (no family draw in any of them)")
	var princess_moves := 0
	for m in moves_e:
		if m.played_type() == Deck.CardType.Princess:
			princess_moves += 1
	check(princess_moves == 0, "  ... a Princess is never enumerated outside the joint enumeration")

	# the level checks run on scenario C's own board state, so rebuild it first
	_seat(Deck.CardType.Prince, fam_c, 3, [false, true, true, false])
	_test_levels(moves_c)


# The level 1-4 policies over one enumerated joint-move list (todo step 12).
func _test_levels(moves: Array[Move]) -> void:
	var p = _main._players[0]
	var left: Array[int] = _main._deck._left

	p.ai_level = Player.AI_Level.Level_1
	var l1: Move = p.select_move(moves, left)
	check(l1 == moves[0] and l1._drawn_family_idx == 0,
		"level 1 takes the first joint move (family index 0, as-dealt order): " + str(l1))

	p.ai_level = Player.AI_Level.Level_2
	var distinct: Dictionary = {}
	var ok_l2 := true
	for i in 60:
		var m: Move = p.select_move(moves, left)
		ok_l2 = ok_l2 and (m in moves)
		distinct[str(m._drawn_family_idx) + "/" + str(m._played_card_idx)] = true
	check(ok_l2, "level 2 only ever picks an enumerated move (60 samples)")
	check(distinct.size() > 1, "level 2 spreads over the list: " + str(distinct.size())
		+ " distinct (draw, play) pairs out of " + str(moves.size()) + " moves")

	var min_drawn: Deck.CardType = moves[0]._drawn_type
	for m in moves:
		if m._drawn_type < min_drawn:
			min_drawn = m._drawn_type
	var by_draw: Array[Move] = []
	var cheap_exists := false
	for m in moves:
		if m._drawn_type == min_drawn:
			by_draw.append(m)
			if m.played_type() <= m._leftover_type:
				cheap_exists = true
	p.ai_level = Player.AI_Level.Level_3
	var ok_l3 := true
	for i in 40:
		var m: Move = p.select_move(moves, left)
		if m._drawn_type != min_drawn:
			ok_l3 = false
		if cheap_exists and m.played_type() > m._leftover_type:
			ok_l3 = false
	check(ok_l3, "level 3 draws the cheapest family card (" + Deck.card_names[min_drawn]
		+ ", " + str(len(by_draw)) + " candidate move(s)) and plays the cheaper card of the pair "
		+ "whenever such a play exists (40 samples)")

	# level 4 = the existing weighted eval, no new scoring terms: a 0-score move (a Princess
	# self-play has no eval branch) can never win while anything in the list scores.
	p.ai_level = Player.AI_Level.Level_4
	p.eval_moves(moves, left)
	var sum := 0
	for m in moves:
		sum += m._score
	var ok_l4 := true
	if sum > 0:
		for i in 40:
			if p.select_move(moves, left)._score == 0:
				ok_l4 = false
	check(sum > 0, "level 4 scores the joint list (sum of _score = " + str(sum) + ")")
	check(ok_l4, "level 4 never plays a 0-score move (the Princess self-play) while a scoring "
		+ "move exists (40 samples)")


# Build one variant decision state for seat 0 (1 hand card + family) and enumerate it.
func _state(active_t: Deck.CardType, family: Array, count: int,
		protected_flags: Array) -> Array[Move]:
	_seat(active_t, family, count, protected_flags)
	return _main.find_valid_moves()


# The same with a 2-card hand - the classic selection the human seat gets until step 20.
func _state_2_cards(a: Deck.CardType, b: Deck.CardType, count: int) -> Array[Move]:
	_seat(a, [], count, [false, false, false, false])
	_add_card(_main._players[0], b)
	return _main.find_valid_moves()


func _seat(active_t: Deck.CardType, family: Array, count: int, protected_flags: Array) -> void:
	for i in 4:
		var p = _main._players[i]
		p.active = i < count
		p.ai_level = Player.AI_Level.Level_1 if i < count else Player.AI_Level.Disabled
		p.protected = protected_flags[i]
		p.clear_hand()
		p.clear_family()
	_main._cur_player = 0
	_add_card(_main._players[0], active_t)
	var fam: Array[Deck.CardType] = []
	for t in family:
		fam.append(t)
	_main._players[0].family = fam
	# `_other_protected`, exactly as new_turn() computes it
	var other_protected := true
	for pl in _main._players:
		if pl.is_active() and not pl.protected and pl.idx != 0:
			other_protected = false
	_main._other_protected = other_protected


func _add_card(p: Player, t: Deck.CardType) -> void:
	# exactly the production order (Main.deal_card): the card enters the tree in the animation
	# layer first - `Card.type` / `faceup` setters touch the sprite, which only exists once the
	# node is in the tree - and only then `Player.add_card` reparents it into the hand.
	var c = _main.card_scene.instantiate()
	_main._animation_layer.add_child(c)
	c.type = t
	c.faceup = true
	p.add_card(c)


# Every property a joint move must have, checked move by move:
# 1. the draw is a real family index and `_drawn_type` is that family card;
# 2. the pair: playing one of (active, family[f]) keeps the other, so `_leftover_type` is forced;
# 3. `_played_card` matches the played slot (null when only the drawn card is played);
# 4. Countess + man plays the Countess;
# 5. the target follows the type rules (self-only for Handmaid/Countess/Princess, Prince hits an
#    unprotected seat incl. self, Guard probes name a guessable type, the rest hit opponents);
# 6. no (draw, play, target, type) combination is generated twice.
func legal_move_set(moves: Array[Move], active_t: Deck.CardType, family: Array,
		count: int) -> bool:
	var ok := true
	var seen: Dictionary = {}
	for m in moves:
		var f: int = m._drawn_family_idx
		ok = ok and f >= 0 and f < family.size() and m._drawn_type == family[f]
		var played: Deck.CardType = m.played_type()
		var kept: Deck.CardType = family[f] if played == active_t else active_t
		ok = ok and (played == active_t or played == family[f])
		ok = ok and m._leftover_type == kept
		ok = ok and ((m._played_card_idx == 0) == (played == active_t and m._played_card != null))
		if m._played_card_idx == 0:
			ok = ok and m._played_card == _main._players[0].hand.get_child(0)
		if m._played_card_idx == 1:
			ok = ok and m._played_card == null
		if is_countess_pair(active_t, family[f]):
			ok = ok and played == Deck.CardType.Countess
		ok = ok and legal_target(m, played, count)
		var key := str(f) + "/" + str(m._played_card_idx) + "/" + str(m._target_player) + "/"
		key += str(m._target_type)
		ok = ok and not seen.has(key)
		seen[key] = true
	return ok


func is_countess_pair(a: Deck.CardType, b: Deck.CardType) -> bool:
	return (a == Deck.CardType.Countess or b == Deck.CardType.Countess) and (
		_main._players[0].is_man(a) or _main._players[0].is_man(b))


func legal_target(m: Move, played: Deck.CardType, count: int) -> bool:
	var tgt: int = m._target_player
	if played == Deck.CardType.Handmaid or played == Deck.CardType.Countess \
			or played == Deck.CardType.Princess:
		return tgt == -1
	if tgt < 0 or tgt >= count or not _main._players[tgt].is_active():
		return false
	var target_protected: bool = _main._players[tgt].protected
	if played == Deck.CardType.Prince:
		return not target_protected
	if played == Deck.CardType.Guard:
		return tgt != 0 and (not target_protected or _main._other_protected)
	return tgt != 0 and not target_protected


# ----------------------------------------------------------------------------------------
# TEST C (todo step 14): a whole scripted 4-player variant round.
#
# The rule under test: "the round ends at TURN START when the seat to act has an empty family",
# and the corollary the same step demands: an AI seat does NOT draw at turn start - the family
# draw belongs to the chosen move (step 13), so exactly ONE family draw happens per play.
#
# Every seat is level 1 -> `valid_moves[0]` = (draw family index 0, play the active card), so the
# whole round is deterministic: seat i plays first-hand, family[0], family[1] on his 1st/2nd/3rd
# turn and keeps family[2]. 12 plays, zero eliminations (the scripted supply has no Priest in any
# hand, so every Guard probe misses by construction), and the 13th turn starts at seat 0 with an
# empty family - the round ends there and nowhere else.
# ----------------------------------------------------------------------------------------
func _test_family_out_round_end() -> void:
	print("\n########## TEST C: a 4p round ends exactly at the turn start with an empty family (step 14) ##########")
	var main = MainScene.instantiate()
	var card_scene: PackedScene = main.card_scene  # set_script resets exported vars
	main.set_script(load(CountingMainScript))
	main.card_scene = card_scene
	# the deck script goes on BEFORE the scene enters the tree, so the Deck node's @onready
	# references are resolved by the test script (set_script on a ready node leaves them null)
	var deck = main.get_node("Table/Deck")
	deck.set_script(FakeDeckScript)
	deck.scripted = NOBLE_SCRIPTED
	deck.scripted_left = NOBLE_SCRIPTED_LEFT
	add_child(main)
	main.noble_family = true
	for i in 4:
		main._players[i].ai_level = Player.AI_Level.Level_1  # deterministic seat, seat 0 is NOT human
	for i in 4:
		main._players[i].move_chosen.connect(_count_c_play.bind(i))
	await main.init_players(SEED)
	# init_players() does not await the deal coroutine, so poll until the opening deal settled
	await await_until(func() -> bool:
		var ready := true
		for p in main._players:
			ready = ready and p.hand.get_child_count() == 1 and p.family_size() == Deck.NOBLE_FAMILY_SIZE[4]
		return ready)

	# --- the scripted deal, as the production deal table applies it in 4p ---
	var fam: int = Deck.NOBLE_FAMILY_SIZE[4]
	check(main._deck.first_hand.size() == 4, "4p deal: 1 first-hand card per seat (4 cards)")
	for p in main._players:
		check(p.family_size() == fam, "seat " + str(p.idx) + " holds a family of " + str(fam)
			+ " scripted cards: " + family_str(p))
	check(deck._widow_cards.is_empty() and !deck._widow.visible,
		"4p burns nothing -> no widow pile exists (empty and hidden)")
	check(deck._cards.is_empty() and !deck._main.visible,
		"4p main pile: 16 - 0 burn - 4 first-hand - 12 family = 0 leftovers (empty and hidden)")
	var supply := 0
	for n in deck._left.size():
		supply += deck._left[n]
	check(supply == TOTAL_CARDS, "the scripted supply is 16 cards and `_left` mirrors it ("
		+ str(supply) + "), so the discard accounting of a whole round is assertable")

	# --- play 4 whole rounds and check every one of them ---
	var seen_rounds: int = 0
	var seen_fam: Array[int] = [0, 0, 0, 0]
	var seen_idx: Array[int] = [0, 0, 0, 0]
	var seen_elim: int = 0
	var seen_pile: int = 0
	var seen_first_hand: int = 0
	var seen_turns: Array[int] = [0, 0, 0, 0]
	var rounds: Array = []  # per round: total plays (cross-check of the harness counters)
	for _f in 20000:
		if main.round_end_actor.size() > seen_rounds:
			var r: int = seen_rounds
			seen_rounds += 1
			var prefix := "round " + str(r + 1) + ":"
			var actor: int = main.round_end_actor[r]
			var fams: Array = main.round_end_families[r]
			var hands: Array = main.round_end_hands[r]
			var left: Array = main.round_end_left[r]
			var turns: Array = main.round_end_turns[r]
			var start_seat: int = main.round_start_actor[r]
			var turns_total := 0
			for j in 4:
				turns_total += int(turns[j]) - seen_turns[j]
				seen_turns[j] = int(turns[j])
			var drew: Array[int] = [0, 0, 0, 0]
			var drew_idx: Array = []
			var total: int = 0
			for j in 4:
				drew[j] = main.family_draws[j] - seen_fam[j]
				seen_fam[j] = main.family_draws[j]
				var k: int = seen_idx[j]
				while k < main.family_draw_idx[j].size():
					drew_idx.append(main.family_draw_idx[j][k])
					k += 1
				seen_idx[j] = main.family_draw_idx[j].size()
				total += _c_plays[j]
			var elim_delta: int = main.eliminations - seen_elim
			seen_elim = main.eliminations
			var pile_delta: int = main.pile_draws - seen_pile
			seen_pile = main.pile_draws

			check(total == 4 * fam, prefix + " " + str(total) + " plays == 4 seats x family size "
				+ str(fam) + ": the round ran to the family-out end, it never stopped earlier")
			check(turns_total == 4 * fam + 1, prefix + " " + str(turns_total) + " turns == 4 x "
				+ str(fam) + " plays + 1: the round ended on the turn that found the empty family, i.e."
				+ " at TURN START, after every playable turn was taken")
			check(actor == start_seat, prefix + " the round ended on seat " + str(actor) + ", the same seat"
				+ " that opened it (seat " + str(start_seat) + "): 4 seats x " + str(fam)
				+ " family cards means the seat to act on the " + str(4 * fam + 1) + "th turn is the seat "
				+ "that took the 1st turn, so the family-out rule ends the round there")
			check(int(fams[actor]) == 0, prefix + " the seat to act has an EMPTY family: that is the"
				+ " variant's only round-end rule (" + str(int(fams[actor])) + " family card left)")
			var fam_total := 0
			for j in 4:
				fam_total += int(fams[j])
			check(fam_total == 0, prefix + " every family is exhausted (sum " + str(fam_total)
				+ "), no seat was cut off before his last card")
			check(elim_delta == 0, prefix + " no elimination (" + str(elim_delta) + "): the scripted plays"
				+ " (Guard probes on non-Priests, Handmaid, Countess) cannot kill a seat, so the family-out"
				+ " rule is the only way this round could end")
			check(pile_delta == 0, prefix + " zero draws from the main pile / the widow ("
				+ str(pile_delta) + " Deck.pop draws): the turn-start draw is a family draw only")
			var fh_delta: int = main.first_hand_deals - seen_first_hand
			seen_first_hand = main.first_hand_deals
			check(fh_delta == 4, prefix + " " + str(fh_delta) + " first-hand cards dealt (1 per seat,"
				+ " animated through deal_card with an explicit type) - the round was re-dealt")
			var one_draw_per_play := true
			for j in 4:
				# THE step 14 assertion: seat plays == family draws == family size. A turn-start
				# placeholder draw would make family_draws 4 > family size (and crash pop_family).
				one_draw_per_play = one_draw_per_play and drew[j] == fam and drew[j] == _c_plays[j]
			check(one_draw_per_play, prefix + " every seat drew exactly " + str(fam)
				+ " family cards in exactly " + str(fam) + " plays - one draw per play, no turn-start"
				+ " draw for an AI seat (draws " + str(drew) + ", plays " + str(_c_plays) + ")")
			var idx_zero_only := true
			for k in drew_idx:
				idx_zero_only = idx_zero_only and int(k) == 0
			check(idx_zero_only, prefix + " every draw used family index 0 (as-dealt order): "
				+ str(drew_idx))
			var one_card := true
			for j in 4:
				one_card = one_card and int(hands[j]) == 1
			check(one_card, prefix + " every live seat holds exactly 1 card at the round end ("
				+ str(hands) + ")")
			var left_ok := true
			var left_sum := 0
			for n in left.size():
				left_sum += int(left[n])
				left_ok = left_ok and int(left[n]) == NOBLE_ROUND_END_LEFT[n]
			check(left_ok, prefix + " `_left` == " + str(left) + ", expected "
				+ str(NOBLE_ROUND_END_LEFT) + " (16 - 12 plays, family draws decremented nothing)")
			check(left_sum == TOTAL_CARDS - total, prefix + " sum(_left) == 16 - " + str(total)
				+ " plays == " + str(left_sum))
			rounds.append(total)
			for j in 4:
				_c_plays[j] = 0
		if seen_rounds >= 4:
			break
		await get_tree().process_frame

	check(seen_rounds >= 4, "4 scripted rounds ran (" + str(seen_rounds) + " observed), every one of"
		+ " them a 12-play family-out end: " + str(rounds))
	check(main.draws_checked > 0 and main.draw_mismatches.is_empty(),
		"every move named the family card its own play chain drew (" + str(main.draws_checked)
		+ " pairings, " + str(main.draw_mismatches.size()) + " mismatches)")
	# the scripted deal is re-applied every round (families are re-dealt, never carried over)
	var redeal := true
	for p in main._players:
		redeal = redeal and p.active
	check(redeal, "the next round is dealt and the seats are live again (families are re-dealt every"
		+ " round, they are not carried over)")
	for p in main._players:
		p.clear_hand()
		check(p.hand.get_child_count() == 0, "seat " + str(p.idx) + " hand cleared")
	main.queue_free()
	await await_frames(2)


func family_str(p: Player) -> String:
	var s := "["
	for t in p.family:
		s += Deck.card_names[t] + " "
	return s + "]"


func _count_c_play(m: Move, seat: int) -> void:
	_c_plays[seat] += 1


func await_until(cond: Callable, max_frames: int = 4000) -> void:
	for i in max_frames:
		if cond.call():
			return
		await get_tree().process_frame
	print("  (await_until timed out)")


# ----------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------
func check(ok: bool, desc: String) -> void:
	print((("  PASS  " + desc) if ok else ("  FAIL  " + desc)))
	if !ok:
		_failed += 1


func await_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
