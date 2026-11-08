class_name Player
extends Node2D

signal card_played(card: Card)
signal target_player_selected(idx: int)
signal move_chosen(move: Move)

enum AI_Level {
	Disabled = -1,
	Human = 0,
	Level_1,
	Level_2,
	Level_3,
	Level_4,
	Level_5
}

enum State {
	IDLE = 0,
	SELECT_CARD,
	INPUT_ANY_P,
	INPUT_OTHER_P,
	INPUT_T
}

var _state: State = State.IDLE

@export var idx: int = 0
@export var right_score: bool = false
@onready var hand: Node2D = $Hand
@onready var _shield: Sprite2D = $Shield
@onready var _inactive: Sprite2D = $Inactive
@onready var _score_digit: Label = $Score
@onready var _badge: Sprite2D = $Badge
@onready var current_mark: ColorRect = $Current

var ai_level: AI_Level = AI_Level.Level_1:
	get:
		return ai_level
	set(value):
		ai_level = value
		if ai_level > AI_Level.Human:
			_badge.frame = ai_level - 1
		_badge.visible = ai_level > AI_Level.Human
		_score_digit.visible = ai_level > AI_Level.Disabled

var active: bool = true

var score: int = 0:
	get:
		return score
	set(value):
		score = value
		_score_digit.text = str(score)

var total_score: int = 0

# Noble Family variant: this seat's private family pile, in as-dealt order.
# Never sorted. Owned/filled by Main, stored here.
var family: Array[Deck.CardType] = []

var _memory: Array[Deck.CardType] = [
	Deck.CardType.Unknown,
	Deck.CardType.Unknown,
	Deck.CardType.Unknown,
	Deck.CardType.Unknown,
]

var protected: bool:
	get:
		return protected
	set(value):
		protected = value
		_shield.visible = protected

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if right_score:
		_score_digit.position.x = 12
		current_mark.position.x = 12
		_badge.position.x = 12


func drawn_card_position() -> Vector2:
	if idx == 0:
		return Vector2(global_position.x + hand.get_child_count() * 13, global_position.y)
	return global_position


func add_card(card: Card) -> void:
	card.reparent(hand)
	if is_human():
		card.input_event.connect(_on_card_input_event.bind(card))


func is_human() -> bool:
	return ai_level == AI_Level.Human


func is_active() -> bool:
	return ai_level > AI_Level.Disabled and active


func clear_hand() -> void:
	for ch in hand.get_children():
		hand.remove_child(ch)
		ch.queue_free()


func family_size() -> int:
	return family.size()


func pop_family(family_idx: int) -> Deck.CardType:
	assert(family_idx >= 0 and family_idx < family.size(),
		"Player " + str(idx) + ": family index " + str(family_idx) + " out of range")
	return family.pop_at(family_idx)


func clear_family() -> void:
	# Data only; visual clearing is added with Player.render_family() (step 18).
	family.clear()


func print_memory() -> void:
	var s := "Player " + str(idx) + " memory:  "
	if is_active():
		for i in _memory.size():
			if idx == i:
				s+= "   " + str(i) + ":         "
			else:
				s += "   " + str(i) + ": " + Deck.card_names[_memory[i]]
	print(s)


func update_memory(player_idx: int, type: Deck.CardType = Deck.CardType.Unknown) -> void:
	_memory[player_idx] = type


func countess_restricted() -> int:
	# returns -1 if Countess rule is not in effect
	var child_types: Array[Deck.CardType] = [hand.get_child(0).type, hand.get_child(1).type]
	var has_countess = child_types[0] == Deck.CardType.Countess or child_types[1] == Deck.CardType.Countess
	var has_men = child_types[0] == Deck.CardType.Prince or child_types[0] == Deck.CardType.King or child_types[1] == Deck.CardType.Prince or child_types[1] == Deck.CardType.King
	var result = -1
	if has_countess and has_men:
		result = 0 if child_types[0] == Deck.CardType.Countess else 1
	return result


func _on_card_input_event(_viewport: Node, event: InputEvent, _shape_idx: int, card: Card) -> void:
	match _state:
		State.SELECT_CARD:
			if event.is_action_pressed("left_click"):
				var countess_idx = countess_restricted()
				var card_idx = card.get_index()
				if countess_idx == -1 or countess_idx == card_idx:
					_state = State.IDLE
					#hand.remove_child(card)
					if card_idx == 0:
						Animator.move_card(hand.get_child(1), global_position)
					card_played.emit(card)


func _on_player_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event.is_action_pressed("left_click"):
		target_player_selected.emit(idx)


func ai_move(valid_moves: Array[Move], left_cards: Array[int]) -> void:
	if get_parent().get_parent().print_valid_moves:
		print("\nPlayer " + str(idx) + " - ai_move: " + str(len(valid_moves)))
	var my_move = select_move(valid_moves, left_cards)
	#hand.remove_child(my_move._played_card)
	move_chosen.emit(my_move)


func select_move(valid_moves: Array[Move], left_cards: Array[int]) -> Move:
	var print_valid_moves: bool = get_parent().get_parent().print_valid_moves
	var strategy: int = ai_level
	if strategy == AI_Level.Level_5:
		# Level_5 has no strategy of its own - it picks Level_1 - Level_4 at random every turn
		strategy = AI_Level.Level_1 + randi() % (AI_Level.Level_4 - AI_Level.Level_1 + 1)
		if print_valid_moves:
			print("\tLevel_5 picks strategy " + str(strategy))
	if strategy != AI_Level.Level_4 and print_valid_moves:
		for m in valid_moves:
			print("\t" + str(m))
	match strategy:
		AI_Level.Level_1:
			# first valid move
			return valid_moves[0]
		AI_Level.Level_2:
			# random valid move
			return valid_moves[randi() % len(valid_moves)]
		AI_Level.Level_3:
			# moves of cheaper card
			var cheaper_idx = 0 if hand.get_child(0).type <= hand.get_child(1).type else 1
			var filtered: Array[Move]
			for m in valid_moves:
				if m._played_card_idx == cheaper_idx:
					filtered.append(m)
			if filtered.is_empty():  # other protected
				filtered.append_array(valid_moves)
			return filtered[randi() % len(filtered)]
		AI_Level.Level_4:
			# move scoring
			eval_moves(valid_moves, left_cards)
			var sum := 0
			for m in valid_moves:
				sum += m._score
				if print_valid_moves:
					print("\t" + str(m))
			if sum == 0:
				sum = 1
			var rmove := randi() % sum
			sum = 0
			for m in valid_moves:
				sum += m._score
				if sum > rmove:
					return m
			return valid_moves[-1]
		_:
			assert(false)
	return null


enum EvalScore {
	LOSE = 0,
	BAD = 5,
	WEAK = 10,
	MODERATE = 20,
	GOOD = 50
}


# Scores every move in place (m._score). Works for classic moves (2-card hand, real Card
# nodes) and for Noble Family moves, which are scored BEFORE the family card is drawn:
# such a move carries only types (_drawn_type / _leftover_type) and may have a null
# _played_card, so the pair is read via Move.played_type() + _leftover_type.
func eval_moves(valid_moves: Array[Move], left_cards: Array[int]):
	for m in valid_moves:
		var is_classic: bool = m._drawn_family_idx == -1
		if is_classic:
			assert(hand.get_child_count() == 2, "Player " + str(idx) + ": wrong hand count")
		var played_t: Deck.CardType = m.played_type()
		var my_type: Deck.CardType = m._leftover_type
		if my_type == Deck.CardType.Unknown:
			my_type = hand.get_child(1 - m._played_card_idx).type  # leftover card
		var mem := _memory[m._target_player]
		m._score = EvalScore.LOSE
		match played_t:
			Deck.CardType.Guard:
				# Guard is not a guessable type (find_valid_moves guesses Priest..Princess),
				# so a Guard memory can never be matched - fall through to the card-count heuristic
				if mem != Deck.CardType.Unknown and mem != Deck.CardType.Guard:
					if mem == m._target_type:
						m._score = EvalScore.GOOD * m._target_type
				else:
					var left := left_cards[m._target_type]
					# cards of the pair visible to me: the played one + the card I keep.
					# For classic moves these are exactly hand[0] and hand[1] in some order.
					if played_t == m._target_type:
						left -= 1
					if my_type == m._target_type:
						left -= 1
					m._score = EvalScore.BAD * left
			Deck.CardType.Priest:
				if mem == Deck.CardType.Unknown:
					m._score = EvalScore.MODERATE
			Deck.CardType.Baron:
				if mem != Deck.CardType.Unknown:
					if my_type > mem:
						m._score = EvalScore.GOOD * m._target_type
					elif my_type == mem:
						m._score = EvalScore.WEAK
				else:
					m._score = EvalScore.MODERATE if my_type > Deck.CardType.Handmaid else EvalScore.BAD
			Deck.CardType.Handmaid:
				m._score = EvalScore.MODERATE
			Deck.CardType.Prince:
				if idx == m._target_player:  # myself
					if my_type != Deck.CardType.Princess:
						m._score = EvalScore.BAD if my_type > Deck.CardType.Handmaid else EvalScore.WEAK
				else:
					if mem != Deck.CardType.Unknown:
						if mem == Deck.CardType.Princess:
							m._score = EvalScore.GOOD * m._target_type
						elif mem > Deck.CardType.Handmaid:
							m._score = EvalScore.WEAK
					else:
						m._score = EvalScore.WEAK
			Deck.CardType.King:
				if my_type == mem:
					m._score = EvalScore.WEAK
				elif mem != Deck.CardType.Unknown:
					m._score = EvalScore.MODERATE if my_type < mem else EvalScore.BAD
				else:
					m._score = EvalScore.BAD
			Deck.CardType.Countess:
				m._score = EvalScore.BAD
