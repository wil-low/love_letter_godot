class_name Player
extends Node2D

enum AI_Level {
	Human = 0,
	Level_1
}

@export var idx: int = 0
@export var right_score: bool = false
@export var ai_level: AI_Level = AI_Level.Level_1
@onready var _card: Card = $Card
@onready var _drawn_card: Card = $DrawnCard

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
	if ai_level == AI_Level.Human:
		_card.faceup = true
		_drawn_card.faceup = true
	set_score(_score)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func set_card(type: Deck.CardType) -> void:
	_card.type = type
	_card.show()


func set_drawn_card(type: Deck.CardType) -> void:
	_drawn_card.type = type
	_drawn_card.show()


func set_score(new_score: int) -> void:
	_score = new_score
	$Score.frame = _score
