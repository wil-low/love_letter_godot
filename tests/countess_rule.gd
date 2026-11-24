extends Node2D
# Countess rule check: the Countess must be played together with any card
# ranked 5 or higher (Prince, King, Princess), not with Prince/King only.
#
# Run:  godot --headless --path . tests/countess_rule.tscn
#       echo $?      # 0 = all checks passed, 1 = a check failed

const PlayerScene := preload("res://player/player.tscn")
const CardScene := preload("res://card/card.tscn")

var _failed: int = 0


func _check(condition: bool, text: String) -> void:
	print(("  PASS  " if condition else "  FAIL  ") + text)
	if !condition:
		_failed += 1


func _restricted(types: Array) -> int:
	var p := PlayerScene.instantiate() as Player
	add_child(p)
	for t in types:
		var card := CardScene.instantiate() as Card
		p.hand.add_child(card)
		card.type = t
	var result := p.countess_restricted()
	p.free()
	return result


func _ready() -> void:
	for t in [Deck.CardType.Guard, Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.Handmaid]:
		_check(Deck.rank(t) < Deck.MIN_HIGH_RANK, "rank(%s) = %d stays below the threshold" % [Deck.card_names[t], Deck.rank(t)])
	for t in [Deck.CardType.Prince, Deck.CardType.King, Deck.CardType.Countess, Deck.CardType.Princess]:
		_check(Deck.rank(t) >= Deck.MIN_HIGH_RANK, "rank(%s) = %d is at/above the threshold" % [Deck.card_names[t], Deck.rank(t)])

	# Countess + a rank 5+ card -> forced Countess, index of the Countess is returned
	_check(_restricted([Deck.CardType.Countess, Deck.CardType.Prince]) == 0, "Countess + Prince -> forced Countess")
	_check(_restricted([Deck.CardType.Prince, Deck.CardType.Countess]) == 1, "Prince + Countess -> forced Countess")
	_check(_restricted([Deck.CardType.Countess, Deck.CardType.King]) == 0, "Countess + King -> forced Countess")
	_check(_restricted([Deck.CardType.King, Deck.CardType.Countess]) == 1, "King + Countess -> forced Countess")
	_check(_restricted([Deck.CardType.Countess, Deck.CardType.Princess]) == 0, "Countess + Princess -> forced Countess (new)")
	_check(_restricted([Deck.CardType.Princess, Deck.CardType.Countess]) == 1, "Princess + Countess -> forced Countess (new)")

	# Countess + a rank < 5 card -> free choice
	for t in [Deck.CardType.Guard, Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.Handmaid]:
		_check(_restricted([Deck.CardType.Countess, t]) == -1, "Countess + %s -> free choice" % Deck.card_names[t])
		_check(_restricted([t, Deck.CardType.Countess]) == -1, "%s + Countess -> free choice" % Deck.card_names[t])

	# no Countess in hand -> rule off
	_check(_restricted([Deck.CardType.Guard, Deck.CardType.Princess]) == -1, "no Countess in hand -> rule off")
	_check(_restricted([Deck.CardType.Prince, Deck.CardType.King]) == -1, "no Countess in hand -> rule off")

	print("\n" + ("ALL CHECKS PASSED" if _failed == 0 else "%d CHECKS FAILED" % _failed))
	get_tree().quit(1 if _failed > 0 else 0)
