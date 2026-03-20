class_name Player
extends Node2D

signal card_played(card: Card)
signal player_clicked(idx: int)

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


var _score: int = 0
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
	set_score(_score)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func drawn_card_position() -> Vector2:
	return global_position


func add_card(card: Card) -> void:
	hand.add_child(card)


func set_score(new_score: int) -> void:
	_score = new_score
	$Score.frame = _score


func clear_hand() -> void:
	for ch in hand.get_children():
		hand.remove_child(ch)
		ch.queue_free()


func _on_player_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:
	if event.is_action_pressed("left_click"):
		player_clicked.emit(idx)
