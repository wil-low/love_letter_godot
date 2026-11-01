extends Node2D
# Checks the premise of issue 3 of ai_memory_open_issues.md, verbatim:
#
#   "`m._target_type` ... for every other card, find_valid_moves builds the move without
#    a type, so `_target_type` is `Deck.CardType.Unknown == 0` ... Three branches
#    multiply by it ... a level 4 AI can never score a guaranteed Baron win above LOSE,
#    and can never score the Princess-kill Prince above LOSE ... these moves are
#    effectively *never played* by level 4/5"
#
# `Deck.CardType.Unknown` is **8**, not 0 (the enum starts at Guard = 0, Unknown is the
# 9th value). The two multipliers in question evaluate to
#
#     EvalScore.GOOD * Deck.CardType.Unknown = 50 * 8 = 400
#
# the largest number in the scoring table, not LOSE. Measured here: the score tables and
# how often level 4 plays those moves.
#
# Run:  godot --headless --path . tests/repro_score_multiplier.tscn
#       echo $?      # 0 = all checks passed, 1 = a check failed

const PlayerScene := preload("res://player/player.tscn")
const CardScene := preload("res://card/card.tscn")

# stand-in for the Application node (Player.select_move reads get_parent().get_parent())
var print_memory: bool = false
var print_valid_moves: bool = false

const SAMPLES: int = 400

var _failed: int = 0
var _players_box: Node


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	_players_box = Node.new()
	_players_box.name = "PlayersBox"
	add_child(_players_box)

	test_a()
	test_b()
	test_c()
	test_d()
	free_players()

	print("\n==========================")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print(str(_failed) + " CHECK(S) FAILED")
	print("==========================")
	get_tree().quit(1 if _failed > 0 else 0)


# A: the exact position issue 3 calls unplayable: Baron + King, rival believed Priest.
# The Baron wins (leftover King > believed Priest). Predicted: score 0 = LOSE, never played.
func test_a() -> void:
	print("\n########## TEST A: known Baron win (Baron + King vs a believed Priest) ##########")
	var r := decide([Deck.CardType.Baron, Deck.CardType.King], Deck.CardType.Priest)
	for s in r.moves:
		print("  " + str(s))
	check(r.moves[0]._score == 400,
		"the known Baron win scores GOOD * Unknown = 50 * 8 = 400 (issue 3 claims 0 = LOSE)")
	check(r.moves[0]._score > r.moves[1]._score,
		"and it outscores the competing play (King on the same rival = "
			+ str(r.moves[1]._score) + ")")
	var n: int = r.tally.get("Baron", 0)
	print("plays over " + str(SAMPLES) + " decisions: " + str(r.tally))
	check(n >= int(SAMPLES * 0.95),
		"level 4 plays the known Baron win in " + str(n) + "/" + str(SAMPLES)
			+ " samples (issue 3 claims it is never played)")


# B: the same branch on a Baron the AI would lose - the score must stay LOSE.
func test_b() -> void:
	print("\n########## TEST B: known Baron loss (Baron + Guard vs a believed Priest) ##########")
	var r := decide([Deck.CardType.Baron, Deck.CardType.Guard], Deck.CardType.Priest)
	for s in r.moves:
		print("  " + str(s))
	check(r.moves[0]._score == 0,
		"the Baron play that loses scores LOSE")
	print("plays over " + str(SAMPLES) + " decisions: " + str(r.tally))
	check(r.tally.get("Baron", 0) == 0,
		"and is played " + str(r.tally.get("Baron", 0)) + "/" + str(SAMPLES) + " times")


# C: "Prince on a known Princess holder: GOOD x rank, the best kill in the game", 0 per issue 3.
func test_c() -> void:
	print("\n########## TEST C: Prince on a known Princess holder ##########")
	var r := decide([Deck.CardType.Prince, Deck.CardType.Handmaid], Deck.CardType.Princess)
	for s in r.moves:
		print("  " + str(s))
	check(r.moves[0]._score == 400,
		"the Princess-burning Prince scores 400, not 0 (self-Prince = " + str(r.moves[1]._score)
			+ ", Handmaid = " + str(r.moves[2]._score) + ")")
	var n2: int = r.tally.get("Prince", 0)
	print("plays over " + str(SAMPLES) + " decisions: " + str(r.tally))
	check(n2 >= int(SAMPLES * 0.9),
		"level 4 plays it in " + str(n2) + "/" + str(SAMPLES)
			+ " samples (issue 3 claims it is never played)")


# D: what the multiplier actually encodes: a constant 400 for every Baron win and for the
# Prince kill, sitting above the best Guard guess (GOOD * Princess = 350).
func test_d() -> void:
	print("\n########## TEST D: rank, constant, or zero? ##########")
	var vs_priest := decide([Deck.CardType.Baron, Deck.CardType.King], Deck.CardType.Priest)
	var vs_countess := decide([Deck.CardType.Baron, Deck.CardType.Princess], Deck.CardType.Countess)
	var vs_prince_card := decide([Deck.CardType.Baron, Deck.CardType.King], Deck.CardType.Prince)
	var guard := decide([Deck.CardType.Guard, Deck.CardType.King], Deck.CardType.Princess)
	var princess_guess := -1
	for s in guard.moves:
		print("  " + str(s))
		if s._target_type == Deck.CardType.Princess:
			princess_guess = s._score
	print("Baron win vs believed Priest   = " + str(vs_priest.moves[0]._score))
	print("Baron win vs believed Prince   = " + str(vs_prince_card.moves[0]._score))
	print("Baron win vs believed Countess = " + str(vs_countess.moves[0]._score))
	print("best Guard guess (Princess)    = " + str(princess_guess))
	check(vs_priest.moves[0]._score == vs_countess.moves[0]._score,
		"the multiplier is the constant `Unknown` (8), not a rank: a Baron win on a believed"
			+ " Priest and on a believed Countess score identically")
	check(princess_guess == 350,
		"the Guard branch does scale with the rank of the guess (50 * Princess = 350)")
	check(vs_priest.moves[0]._score > princess_guess,
		"and the constant 400 outranks it - a calibration question, not a zeroing bug")


# ---------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------
# builds the move list the way Main.find_valid_moves() does for 2 seats, runs the real
# Player.eval_moves() on it, then samples the real Player.select_move() SAMPLES times.
# `mem` is what seat 0 believes about seat 1 (Unknown = no belief).
func decide(hand: Array[Deck.CardType], mem: Deck.CardType) -> Dictionary:
	var p0 := make_player(0, Player.AI_Level.Level_4)
	var p1 := make_player(1, Player.AI_Level.Level_1)
	p0.add_card(make_card(hand[0]))
	p0.add_card(make_card(hand[1]))
	p1.add_card(make_card(Deck.CardType.King))
	if mem != Deck.CardType.Unknown:
		p0.update_memory(1, mem)

	var moves := legal_moves(p0, 1)
	var left: Array[int] = []
	for i in Deck.card_count.size():
		left.append(Deck.card_count[i])
	p0.eval_moves(moves, left)
	var tally := {}
	for i in SAMPLES:
		var chosen: Move = p0.select_move(moves, left)
		var k: String = Deck.card_names[chosen._played_card.type].strip_edges()
		if chosen._target_type != Deck.CardType.Unknown:
			k += "-guess"
		tally[k] = int(tally.get(k, 0)) + 1
	# the Move objects keep referencing the hand cards, so the hand is freed with the
	# players (queue_free is deferred to the end of the frame, after the caller printed)
	p0.queue_free()
	p1.queue_free()
	return {"moves": moves, "tally": tally}


func make_player(idx: int, level: Player.AI_Level) -> Player:
	var p: Player = PlayerScene.instantiate()
	_players_box.add_child(p)
	p.idx = idx
	p.ai_level = level
	return p


func make_card(t: Deck.CardType) -> Card:
	var c: Card = CardScene.instantiate()
	add_child(c)
	c.type = t
	c.faceup = false
	return c


# mirrors Main.find_valid_moves() ordering; Prince may target self, Princess has no branch
func legal_moves(p: Player, target: int) -> Array[Move]:
	var moves: Array[Move]
	var cards: Array[Card] = []
	for i in p.hand.get_child_count():
		cards.append(p.hand.get_child(i))
	for i in cards.size():
		match cards[i].type:
			Deck.CardType.Guard:
				for t in range(Deck.CardType.Priest, Deck.CardType.Unknown):
					moves.append(Move.new(cards[i], i, target, t))
			Deck.CardType.Princess:
				pass  # find_valid_moves has no Princess branch - the AI is never offered it
			Deck.CardType.Handmaid, Deck.CardType.Countess:
				moves.append(Move.new(cards[i], i))
			Deck.CardType.Prince:
				moves.append(Move.new(cards[i], i, target))
				moves.append(Move.new(cards[i], i, p.idx))
			_:
				moves.append(Move.new(cards[i], i, target))
	return moves


func check(ok: bool, desc: String) -> void:
	print((("  PASS  " + desc) if ok else ("  FAIL  " + desc)))
	if !ok:
		_failed += 1


func free_players() -> void:
	for c in _players_box.get_children():
		(c as Player).clear_hand()
		c.queue_free()
