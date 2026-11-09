class_name FamilySelector
extends Node2D

# Noble Family variant, todo step 19: the MODAL the human seat uses to pick WHICH family card he
# draws. The family stack (`Player.render_family()`, step 18) is the display-only view - "look at
# your noble family at any time" needs no widget; the modal is only where he CHOOSES.
#
# Shape follows `type_selector`: a Node2D of `Card` children + one selection sprite, taps on the
# Area2D cards. Differences, all forced by the variant rules:
# - the row is REBUILT from the family data on every `open()`: a family has 0..5 cards, in
#   as-dealt order, and the order is the level 1 determinism, so it is never sorted here either;
# - a tap COMMITS immediately and there is NO cancel/BACK control: the turn-start draw and a
#   Prince redraw are MANDATORY, so the modal has no way to leave without drawing;
# - it reports an INDEX, not a type: Main pops `p.family[idx]`, so the panel can be a view of the
#   data without ever owning it (a type would allow a stale/duplicated card to be "drawn").
signal draw_selected(family_idx: int)

# Geometry: one row of 11 x 17 cards, 12 px pitch (1 px gap), y 22. A full 5-card family row spans
# x 12..71 on the 84 x 48 board, i.e. centered on the Table (board center x 42), below the top
# seat row (y 0..17) and above the "Select other player" labels (y 36+).
const CARD_ORIGIN := Vector2(12, 22)
const CARD_PITCH: int = 12
# 5 is the biggest family the deal table produces (2 players, `Deck.NOBLE_FAMILY_SIZE`), so the
# panel has room for exactly one full family and no more.
const MAX_CARDS: int = 5

const CARD_SCENE: PackedScene = preload("res://card/card.tscn")

@onready var _selection: Sprite2D = $FamilySelection

# The types the row currently shows, in as-dealt order - a COPY of the family, so a family pop
# (`Player.pop_family()` mutates the seat's array) can never retype a card that is on screen.
var _types: Array[Deck.CardType] = []
# The panel arms exactly ONE emission per `open()`: taps are ignored once a choice is made, so a
# double tap, a tap on a closing panel or a stray tap cannot emit twice into `await`ed Main code.
var _armed: bool = false


func _ready() -> void:
	# a panel that is open at scene setup would eat taps before the first family exists
	hide()


# Rebuild the row from `family` and open it. `family` is read, never stored by reference: the
# panel is a view of the seat's data, and the data is mutated by the draw it is asking for.
func open(family: Array[Deck.CardType]) -> void:
	if family.is_empty():
		# The draw is mandatory, so a panel with no card is a deadlock, not an empty page: an empty
		# family means the round is over (turn start) or the target is out (Prince) - Main decides
		# that, this panel just refuses to open on nothing. Closing is part of refusing: a panel left
		# open on its PREVIOUS row would keep a family the seat no longer has tappable.
		push_warning("FamilySelector: refusing to open on an empty family")
		close()
		return
	var types: Array[Deck.CardType] = family.duplicate()
	if types.size() > MAX_CARDS:
		push_warning("FamilySelector: family of " + str(types.size()) + " cards truncated to "
			+ str(MAX_CARDS))
		types.resize(MAX_CARDS)
	_close_cards()
	_types = types
	for i in types.size():
		var c: Card = CARD_SCENE.instantiate()
		# IN THE TREE before type/faceup are set: both setters touch `_sprite.frame`, which _ready() sets
		add_child(c)
		c.position = CARD_ORIGIN + Vector2(i * CARD_PITCH, 0)
		c.type = types[i]
		c.faceup = true  # the seat chooses among HIS OWN cards, they are public to him
		c.modulate.a = 1.0
		c.input_event.connect(_on_card_input_event.bind(i))
	_selection.hide()
	_armed = true
	show()


# Close the panel and drop the row: a modal that keeps its cards keeps tappable Area2D zones and a
# copy of a family that no longer exists.
func close() -> void:
	_armed = false
	_selection.hide()
	_close_cards()
	_types.clear()
	hide()


func is_open() -> bool:
	return _armed and visible


# Commit a family index: flash the selection sprite, emit, close. Returns false when the panel has
# nothing to commit (already chosen, closed, index out of the row) - a tap outside the row does
# nothing, by construction there is no control that does anything else.
func select(family_idx: int) -> bool:
	if !_armed:
		return false
	if family_idx < 0 or family_idx >= _types.size():
		return false
	# one emission per open(): disarmed BEFORE the emit, so a listener that taps the panel again
	# from its own handler cannot fire a second draw
	_armed = false
	set_selection(family_idx)
	draw_selected.emit(family_idx)
	close()
	return true


# The tapped card gets the selection sprite, the rest fade. There is no confirm step (the tap IS
# the draw), so this is the choice flash the player sees for the frame before the card flies out of
# his stack - and the hook a debug run uses to show a row's current choice.
# The row's Card nodes in tree order == family order (`open()` appends in as-dealt order, and the
# selection sprite is declared after them in the scene file - filtering by `is Card` keeps the
# mapping index -> node independent of that order).
func _cards() -> Array:
	var out: Array = []
	for c in get_children():
		if c is Card:
			out.append(c)
	return out


func set_selection(family_idx: int) -> void:
	var cards: Array = _cards()
	for i in cards.size():
		# `set_selection(-1)` is the "no choice yet" state (the type selector's Unknown): a panel that
		# kept a card dimmed after a closed modal would look like the draw was already made
		(cards[i] as Card).modulate.a = 1.0 if family_idx == -1 or i == family_idx else 0.25
	if family_idx >= 0 and family_idx < cards.size():
		_selection.position = (cards[family_idx] as Card).position
		_selection.show()
	else:
		_selection.hide()


func _on_card_input_event(_viewport: Node, event: InputEvent, _shape_idx: int,
		family_idx: int) -> void:
	if event.is_action_pressed("left_click"):
		select(family_idx)


func _close_cards() -> void:
	for ch in get_children():
		if ch is Card:
			# removed synchronously, freed on the frame: a re-open in the same frame sees the row it
			# built, never the previous family's leftovers
			remove_child(ch)
			ch.queue_free()
