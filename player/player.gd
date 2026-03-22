class_name Player
extends Node2D

signal card_played(card: Card)
signal target_player_selected(idx: int)
signal target_type_selected(type: Deck.CardType)

enum AI_Level {
	Human = 0,
	Level_1
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


var _known_cards: Array[Deck.CardType] = [
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


func next_state(type: Deck.CardType, log: bool) -> State:
	var result := State.IDLE
	match type:
		Deck.CardType.Guard, Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
			result = State.INPUT_OTHER_P
			if log:
				print("Select another player")
		Deck.CardType.Prince:
			result = State.INPUT_ANY_P
			if log:
				print("Select any player")
	return result


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
	print("\nPlayer " + str(idx) + " - ai_move:")
	for m in valid_moves:
		print("\t" + str(m))
	var choice = randi() % len(valid_moves)
	var my_move = valid_moves[choice]
	print("My " + str(my_move))
	var c = hand.get_child(my_move._played_card_idx)
	hand.remove_child(c)
	card_played.emit(c)
	if my_move._target_player != -1:
		await Animator.delay(1)
		_state = next_state(c.type, false)
		target_player_selected.emit(my_move._target_player)
	if my_move._target_type != Deck.CardType.Unknown:
		await Animator.delay(1)
		target_type_selected.emit(my_move._target_type)
