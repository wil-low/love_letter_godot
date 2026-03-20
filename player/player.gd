class_name Player
extends Node2D

signal card_played(card: Card)

enum AI_Level {
	Human = 0,
	Level_1
}

enum State {
	IDLE = 0,
	SELECT_CARD,
	PUT_CARD,
	GUARD_INPUT_P,
	PRIEST_INPUT_P,
	BARON_INPUT_P,
	HANDMAID_RESOLVE,
	PRINCE_INPUT_P,
	KING_INPUT_P,
	COUNTESS_RESOLVE,
	PRINCESS_RESOLVE
}

var _state: State = State.IDLE

@export var idx: int = 0
@export var right_score: bool = false
@export var ai_level: AI_Level = AI_Level.Level_1

@onready var _card: Card = $Card
@onready var _card_selection: Sprite2D = $CardSelection
@onready var _player_selection: Sprite2D = $PlayerSelection

var active: bool = true

var _score: int = 0
var _known_cards: Array[Deck.CardType] = [
	Deck.CardType.Unknown,
	Deck.CardType.Unknown,
	Deck.CardType.Unknown,
	Deck.CardType.Unknown,
]

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if right_score:
		$Score.position.x = 16
	set_score(_score)
	hide_selections()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func hide_selections():
	_card_selection.global_position = Vector2(-100, 100)
	_player_selection.global_position = _card_selection.position


func set_card(type: Deck.CardType) -> void:
	_card.type = type
	_card.show()


func set_score(new_score: int) -> void:
	_score = new_score
	$Score.frame = _score
