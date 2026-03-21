class_name Player
extends Node2D

signal card_played(card: Card)
signal target_player_selected(idx: int)
signal target_type_selected(type: Deck.CardType)
signal move_selected(card: Card, player_idx: int, type: Deck.CardType)

enum AI_Level {
	Human = 0,
	Level_1
}

enum State {
	IDLE = 0,
	SELECT_CARD,
	PUT_CARD,
	INPUT_ANY_P,
	INPUT_OTHER_P,
	INPUT_T,
	RESOLVE,
}

var _state: State = State.IDLE

@export var idx: int = 0
@export var right_score: bool = false
@export var ai_level: AI_Level = AI_Level.Level_1
@onready var hand: Node = $Hand
@onready var _inactive: Sprite2D = $Inactive
@onready var score_digit: Sprite2D = $Score

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
		$Score.frame = score


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
		$Shield.visible = protected

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if right_score:
		$Score.position.x = 12


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func drawn_card_position() -> Vector2:
	if is_human():
		return Vector2(global_position.x + hand.get_child_count() * 16, global_position.y)
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


func reveal_hand(speed: float, hide_afterwards: bool = true) -> void:
	if hand.get_child_count() > 0:
		var card: Card = hand.get_child(0)
		await card.flip(true, speed)
		await get_tree().create_timer(speed * 4).timeout
		if hide_afterwards:
			await card.flip(false, speed)


func countess_restricted() -> int:
	# returns -1 if Countess rule is not in effect
	var child_types: Array[Deck.CardType] = [hand.get_child(0).type, hand.get_child(1).type]
	var has_countess = child_types[0] == Deck.CardType.Countess or child_types[1] == Deck.CardType.Countess
	var has_men = child_types[0] == Deck.CardType.Prince or child_types[0] == Deck.CardType.King or child_types[1] == Deck.CardType.Prince or child_types[1] == Deck.CardType.King
	var result = -1
	if has_countess and has_men:
		result = 0 if child_types[0] == Deck.CardType.Countess else 1
	return result


func _on_card_input_event(viewport: Node, event: InputEvent, shape_idx: int, card: Card) -> void:
	match _state:
		State.SELECT_CARD:
			if event.is_action_pressed("left_click"):
				var countess_idx = countess_restricted() 
				if countess_idx == -1 or countess_idx == card.get_index():
					hand.remove_child(card)
					if hand.get_child_count() == 1:
						var tw = create_tween().set_parallel().set_trans(Tween.TRANS_QUAD)
						tw.tween_property(hand.get_child(0), "global_position", global_position, get_parent().animation_speed / 2)
					card_played.emit(card)


func _on_player_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:
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
		await get_tree().create_timer(1).timeout
		target_player_selected.emit(my_move._target_player)
	if my_move._target_type != Deck.CardType.Unknown:
		await get_tree().create_timer(1).timeout
		target_type_selected.emit(my_move._target_type)
