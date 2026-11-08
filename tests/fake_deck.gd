extends Deck
# Test-only deck that deals a scripted card order instead of a shuffled one.
# Installed at runtime with `main._deck.set_script(...)` - no production file is modified.
#
# `scripted` is the full supply in deal order:
# - classic `prepare()`: the widow is emptied and `_cards` is the scripted order, so the first
#   `player_count` cards are the opening hands and the rest is the draw pile;
# - noble `prepare_noble()`: the scripted order is dealt through the PRODUCTION deal table
#   (burn NOBLE_BURN / 1 first-hand per seat / NOBLE_FAMILY_SIZE per seat round-robin),
#   exactly like `Deck.prepare_noble()` does with a shuffled deck.

var scripted: Array[Deck.CardType] = []
# The Noble Family supply is a hand-picked multiset (it is not the real deck's), so `_left` is
# rebuilt from it: `discard()` asserts `_left[type] >= 0` and the harness asserts the accounting
# elementwise. An empty `scripted_left` keeps the production counts.
var scripted_left: Array[int] = []


func prepare(player_count: int) -> void:
	super.prepare(player_count)
	if !scripted.is_empty():
		_cards = scripted.duplicate()
		_widow_cards = []
		update_piles()


func prepare_noble(player_count: int) -> Array:
	# runs the production assert + `_left` build, then re-deals the scripted order
	var families: Array = super.prepare_noble(player_count)
	if scripted.is_empty():
		return families
	var rest: Array[Deck.CardType] = scripted.duplicate()
	_widow_cards = []
	first_hand = []
	families = []
	for i in player_count:
		var seat_family: Array[Deck.CardType] = []
		families.append(seat_family)
	for _n in Deck.NOBLE_BURN[player_count]:
		_widow_cards.append(rest.pop_front())
	for _n in player_count:
		first_hand.append(rest.pop_front())
	for _c in Deck.NOBLE_FAMILY_SIZE[player_count]:
		for i in player_count:
			families[i].append(rest.pop_front())
	_cards = rest
	if !scripted_left.is_empty():
		var left: Array[int] = []
		for n in scripted_left.size():
			left.append(scripted_left[n])
		_left = left
	update_piles()
	return families
