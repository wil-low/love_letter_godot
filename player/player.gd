class_name Player
extends Node2D

signal card_played(card: Card)
signal target_player_selected(idx: int)
signal move_chosen(move: Move)

enum AI_Level {
	Human = 0,
	Level_1,
	Level_2,
	Level_3,
	Level_4
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
@export var ai_level: AI_Level = AI_Level.Level_1
@onready var hand: Node = $Hand
@onready var _shield: Sprite2D = $Shield
@onready var _inactive: Sprite2D = $Inactive
@onready var _score_digit: Sprite2D = $Score
@onready var current_mark: ColorRect = $Current

var active: bool = true:
	get:
		return active
	set(value):
		active = value
		_inactive.visible = !active

var score: int = 0:
	get:
		return score
	set(value):
		score = value
		_score_digit.frame = score

var total_score: int = 0

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


func drawn_card_position() -> Vector2:
	if is_human():
		return Vector2(global_position.x + hand.get_child_count() * 13, global_position.y)
	return global_position


func add_card(card: Card) -> void:
	hand.add_child(card)
	if is_human():
		card.input_event.connect(_on_card_input_event.bind(card))


func is_human() -> bool:
	return ai_level == AI_Level.Human


func clear_hand() -> void:
	for ch in hand.get_children():
		hand.remove_child(ch)
		ch.queue_free()


func print_memory() -> void:
	var s := "Player " + str(idx) + " memory:  "
	if active:
		for i in range(len(_memory)):
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
					hand.remove_child(card)
					if card_idx == 0:
						Animator.move_card(hand.get_child(0), global_position)
					card_played.emit(card)


func _on_player_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event.is_action_pressed("left_click"):
		target_player_selected.emit(idx)


func ai_move(valid_moves: Array[Move]) -> void:
	print("\nPlayer " + str(idx) + " - ai_move: " + str(len(valid_moves)))
	var my_move = select_move(valid_moves)
	hand.remove_child(my_move._played_card)
	move_chosen.emit(my_move)


func select_move(valid_moves: Array[Move]) -> Move:
	if ai_level != AI_Level.Level_4:
		for m in valid_moves:
			print("\t" + str(m))
	match ai_level:
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
			eval_moves(valid_moves)
			var sum := 0
			for m in valid_moves:
				print("\t" + str(m))
				sum += m._score
			if sum == 0:
				sum = 1
			var rmove := randi() % sum
			sum = 0
			for m in valid_moves:
				sum += m._score
				if sum >= rmove:
					return m
			return valid_moves[-1]
	return null

enum EvalScore {
	LOSE = 0,
	BAD = 5,
	WEAK = 10,
	MODERATE = 20,
	GOOD = 50
}

func eval_moves(valid_moves):
	assert(hand.get_child_count() == 2, "Player " + str(idx) + ": wrong hand count")
	for m in valid_moves:
		var my_type = hand.get_child(1 - m._played_card_idx).type  # leftover card
		var mem := _memory[m._target_player]
		m._score = EvalScore.LOSE
		match m._played_card.type:
			Deck.CardType.Guard:
				if mem != Deck.CardType.Unknown:
					if mem == m._target_type:
						m._score = EvalScore.GOOD
				else:
					m._score = EvalScore.BAD
			Deck.CardType.Priest:
				if mem == Deck.CardType.Unknown:
					m._score = EvalScore.WEAK
			Deck.CardType.Baron:
				if mem != Deck.CardType.Unknown:
					if my_type > mem:
						m._score = EvalScore.GOOD
					elif my_type == mem:
						m._score = EvalScore.WEAK
				else:
					m._score = EvalScore.WEAK if my_type > Deck.CardType.Handmaid else EvalScore.BAD
			Deck.CardType.Handmaid:
				m._score = EvalScore.MODERATE
			Deck.CardType.Prince:
				if idx == m._target_player:  # myself
					if my_type != Deck.CardType.Princess:
						m._score = EvalScore.WEAK if my_type > Deck.CardType.Handmaid else EvalScore.MODERATE
				else:
					if mem != Deck.CardType.Unknown:
						if mem == Deck.CardType.Princess:
							m._score = EvalScore.GOOD
						elif mem > Deck.CardType.Handmaid:
							m._score = EvalScore.WEAK
					else:
						m._score = EvalScore.BAD
			Deck.CardType.King:
				if my_type == mem:
					m._score = EvalScore.WEAK
				elif mem != Deck.CardType.Unknown:
					m._score = EvalScore.MODERATE if my_type < mem else EvalScore.BAD
				else:
					m._score = EvalScore.BAD
			Deck.CardType.Countess:
				m._score = EvalScore.BAD
