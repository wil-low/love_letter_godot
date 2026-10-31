extends Deck
# Test-only deck that deals a scripted card order instead of a shuffled one.
# Installed at runtime with `main._deck.set_script(...)` - no production file is modified.

var scripted: Array[Deck.CardType] = []


func prepare(player_count: int) -> void:
	super.prepare(player_count)
	if !scripted.is_empty():
		_cards = scripted.duplicate()
		_widow_cards = []
		update_piles()
