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
# Later steps append to this file: step 14 (round ends at turn start with an empty
# family), step 15 (Prince: family draw -> widow fallback -> elimination), step 16
# (elimination reveal + discard accounting), step 31 (joint move legality, L1
# determinism). Those cases use the `tests/fake_deck.gd` scripted-deal technique;
# TEST A deliberately needs no Main scene at all, so the deal table is pinned
# independently of the game loop.
#
# Run:  godot --headless --path . tests/noble_family_rules.tscn
#       echo $?      # 0 = every check passed, 1 = a check failed

const DeckScene := preload("res://deck/deck.tscn")

const TRIALS: int = 200
const SEED: int = 20260607
const TOTAL_CARDS: int = 16

var _failed: int = 0
var _deck: Deck


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	seed(SEED)
	_deck = DeckScene.instantiate()
	add_child(_deck)

	await _test_deal_table()
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
# helpers
# ----------------------------------------------------------------------------------------
func check(ok: bool, desc: String) -> void:
	print((("  PASS  " + desc) if ok else ("  FAIL  " + desc)))
	if !ok:
		_failed += 1


func await_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
