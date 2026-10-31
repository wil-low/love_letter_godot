extends Node2D
# Reproduces the reported level 4 behaviour:
#   "AI has Guard + Princess in hand, plays Guard and declares Princess on the rival"
#
# Test A - unit: the decision itself, given a memory slot pointing at the rival.
# Test B - integration: the exact 4-step sequence reported, in a real 2-player round
#          with a scripted deck order (no random seed involved).
#
# Nothing in the production scripts is modified. The test root node stands in for the
# `Application` node (Main.new_turn() reads get_parent().print_memory and
# Player.select_move() reads get_parent().get_parent().print_valid_moves).
#
# Run:  godot --headless --path . tests/repro_guard_princess.tscn

const PlayerScene := preload("res://player/player.tscn")
const CardScene := preload("res://card/card.tscn")
const MainScene := preload("res://main/main.tscn")
const FakeDeckScript := preload("res://tests/fake_deck.gd")

# stand-in for the Application node
var print_memory: bool = false
var print_valid_moves: bool = false

const SEED: int = 20261028

var _failed: int = 0
var _players_box: Node
var _ai_chosen: Move = null


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	await _test_a()
	await _test_b()

	print("\n==========================")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print(str(_failed) + " CHECK(S) FAILED")
	print("==========================")
	get_tree().quit(1 if _failed > 0 else 0)


# ----------------------------------------------------------------------------------------
# Test A: the bare decision. No deck, no animations.
# ----------------------------------------------------------------------------------------
func _test_a() -> void:
	print("\n########## TEST A: level 4 Guard decision ##########")
	_players_box = Node.new()
	_players_box.name = "PlayersBox"
	add_child(_players_box)

	# The state left by the King swap in Test B: our own hand is [Princess, Guard],
	# our memory of the rival points at a Guard - which is TRUE and not guessable,
	# so the card-count heuristic must take over (Princess is in our own hand)
	await scenario("memory of rival = Guard", Deck.CardType.Guard, false)
	# The "stale memory" hypothesis: the rival is believed to hold the Princess.
	# The Guard check does NOT cure this one - a known Princess still scores 50 * 7 = 350.
	await scenario("memory of rival = Princess", Deck.CardType.Princess, true)


func scenario(title: String, mem: Deck.CardType, expect_princess: bool) -> void:  # coroutine (awaits frames)
	print("\n--- " + title + " ---")
	var p0 := make_player(0, Player.AI_Level.Level_4)
	var p1 := make_player(1, Player.AI_Level.Level_1)
	# child 0 = card received from the King swap, child 1 = card drawn this turn
	p0.add_card(make_card(Deck.CardType.Princess))
	p0.add_card(make_card(Deck.CardType.Guard))
	p1.add_card(make_card(Deck.CardType.Guard))
	p0.update_memory(1, mem)

	var left: Array[int] = []
	for i in Deck.card_count.size():
		left.append(Deck.card_count[i])

	var moves := legal_moves(p0, 1)
	p0.eval_moves(moves, left)
	print("P0 hand " + hand_str(p0) + ", P1 hand " + hand_str(p1))
	print("P0 memory of P1 = [" + Deck.card_names[mem] + "], Princess in P0 hand: "
		+ str(holds(p0, Deck.CardType.Princess)) + ", _left[Princess] = "
		+ str(left[Deck.CardType.Princess]))
	print("scored moves:")
	for m in moves:
		print("  " + str(m))
	var chosen: Move = p0.select_move(moves, left)
	print("AI plays: " + str(chosen))
	var declares_princess: bool = chosen._target_type == Deck.CardType.Princess
	check(declares_princess == expect_princess,
		"AI " + ("declares Princess (memory says Princess, score 350)" if expect_princess
			else "does NOT declare Princess - the count heuristic drops it to 0"))

	p0.clear_hand()
	p1.clear_hand()
	p0.queue_free()
	p1.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# Test B: the reported sequence, played out on the real game scene.
#   1. P0 holds Priest, P1 holds Princess
#   2. P0 draws Guard, plays Priest, sees the Princess in P1's hand
#   3. P1 draws King, plays it, swaps Princess for P0's Guard
#   4. P0 draws Guard (hand = Princess + Guard), plays Guard, declares Princess
# ----------------------------------------------------------------------------------------
func _test_b() -> void:
	print("\n########## TEST B: full round, scripted deck ##########")
	var main: Main = MainScene.instantiate()
	# swap the deck script BEFORE the scene enters the tree, so the Deck node's
	# @onready references are resolved by the test script (set_script on a ready node
	# would leave them null)
	var deck: Node = main.get_node("Table/Deck")
	deck.set_script(FakeDeckScript)
	var order: Array[Deck.CardType] = [
		Deck.CardType.Priest,   # P0 opening hand
		Deck.CardType.Princess, # P1 opening hand
		Deck.CardType.Guard,    # P0 draws, step 2
		Deck.CardType.King,     # P1 draws, step 3
		Deck.CardType.Guard,    # P0 draws, step 4
		Deck.CardType.Baron, Deck.CardType.Baron, Deck.CardType.Handmaid,
		Deck.CardType.Handmaid, Deck.CardType.Prince, Deck.CardType.Prince,
		Deck.CardType.Countess, Deck.CardType.Guard, Deck.CardType.Guard,
		Deck.CardType.Guard,
	]
	deck.scripted = order
	add_child(main)

	var p0: Player = main._players[0]
	var p1: Player = main._players[1]
	# P0 plays "human" so its plays can be driven explicitly, P1 uses level 1
	# (first legal move) - P1's King play in step 3 is then forced.
	p0.ai_level = Player.AI_Level.Human
	p1.ai_level = Player.AI_Level.Level_1
	main._players[2].ai_level = Player.AI_Level.Disabled
	main._players[3].ai_level = Player.AI_Level.Disabled
	await main.init_players(SEED)
	# init_players fires _new_game -> _new_round (dealing + first new_turn) without
	# awaiting it, so wait until the opening deal and P0's first draw have settled.
	var c_open := func() -> bool:
		var ready_turn: bool = main._cur_player == 0
		var p0_cards: bool = p0.hand.get_child_count() == 2
		var p1_cards: bool = p1.hand.get_child_count() == 1
		return ready_turn and p0_cards and p1_cards
	await await_until(c_open)

	# --- step 1 + 2 ---
	print("opening: P0 " + hand_str(p0) + ", P1 " + hand_str(p1))
	var dealt_ok: bool = holds(p0, Deck.CardType.Priest) and holds(p1, Deck.CardType.Princess)
	check(dealt_ok, "opening hands dealt as scripted (P0 Priest, P1 Princess)")
	if !dealt_ok:
		print("aborting Test B - deck order not applied")
		return

	var priest: Card = p0.hand.get_child(0)
	await main._on_card_played(priest)
	await main._on_target_player_selected(1)
	await await_frames(2)
	print("after P0's Priest: P0 memory of P1 = ["
		+ Deck.card_names[p0._memory[1]] + "]")
	check(p0._memory[1] == Deck.CardType.Princess,
		"Priest revealed the Princess into P0's memory")

	# --- step 3: P1 draws King, plays it on P0 (only legal move: no Princess branch
	# in find_valid_moves), cards are swapped ---
	var c_p0_turn := func() -> bool:
		return main._cur_player == 0 and p0.hand.get_child_count() == 2
	await await_until(c_p0_turn)
	print("after P1's King: P0 " + hand_str(p0) + ", P1 " + hand_str(p1))
	print("P0 memory of P1 = [" + Deck.card_names[p0._memory[1]] + "]"
		+ " (King rewrites it to the card P0 handed over)")
	check(holds(p0, Deck.CardType.Princess) and holds(p1, Deck.CardType.Guard),
		"King swap: P0 now holds the Princess, P1 holds the Guard")
	check(p0._memory[1] == Deck.CardType.Guard,
		"memory is NOT stale - King overwrote it with the rival's real card")

	# --- step 4: P0 draws a Guard, level 4 decides ---
	p0.ai_level = Player.AI_Level.Level_4
	var moves := main.find_valid_moves()
	p0.eval_moves(moves, main._deck._left)
	print("P0 hand " + hand_str(p0) + ", P1 hand " + hand_str(p1))
	print("scored moves:")
	for m in moves:
		print("  " + str(m))
	var sum := 0
	for m in moves:
		sum += m._score
	print("sum of all move scores = " + str(sum) + ", _left = " + str(main._deck._left))
	check(sum > 0, "card-count heuristic is used again (a Guard memory no longer blocks it)")
	check(moves[-1]._target_type == Deck.CardType.Princess,
		"the last generated move is still the Princess guess (Princess is the last enum value)")
	var princess_score := 0
	for m in moves:
		if m._target_type == Deck.CardType.Princess:
			princess_score = m._score
	check(princess_score == 0,
		"the Princess guess scores 0 - left_cards[Princess] minus the copy in hand")

	var chosen: Move = p0.select_move(moves, main._deck._left)
	print("AI plays: " + str(chosen))
	check(chosen._played_card.type == Deck.CardType.Guard
		and chosen._target_player == 1
		and chosen._target_type != Deck.CardType.Princess,
		"level 4 plays Guard on P1 without declaring the Princess it holds itself")

	# --- let the AI play it for real and watch the (failed) resolution ---
	# P0 started as Human, so Main never connected its move_chosen handler.
	# Record what the AI chooses and forward it to Main like a real AI turn.
	var p1_card_before: int = (p1.hand.get_child(0) as Card).type
	_ai_chosen = null
	var cb := func(m: Move) -> void:
		_ai_chosen = m
		main._on_move_chosen(m)
	p0.move_chosen.connect(cb)
	p0.ai_move(moves, main._deck._left)
	await await_until(func() -> bool: return _ai_chosen != null)
	print("AI emitted move: " + str(_ai_chosen))
	# the declared guess travels inside the chosen Move; P1's real card is the one
	# it held when the Guard resolved (new_turn already dealt a fresh card by now)
	print("resolution: declared [" + Deck.card_names[_ai_chosen._target_type]
		+ "], P1 real card was [" + Deck.card_names[p1_card_before] + "], P1 still in play: "
		+ str(p1.active))
	check(p1.active
		and _ai_chosen._target_type != Deck.CardType.Princess
		and p1_card_before == Deck.CardType.Guard,
		"the rival is not accused of holding the Princess and survives")


# ----------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------
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


# mirrors Main.find_valid_moves() ordering for a [Princess, Guard] hand vs one target
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
				pass  # find_valid_moves() has no branch for Princess - it is never played
			_:
				moves.append(Move.new(cards[i], i))
	return moves


func hand_str(p: Player) -> String:
	var s := p.name + " ["
	for c in p.hand.get_children():
		s += Deck.card_names[(c as Card).type] + " "
	return s + "]"


func holds(p: Player, t: Deck.CardType) -> bool:
	for c in p.hand.get_children():
		if (c as Card).type == t:
			return true
	return false


func check(ok: bool, desc: String) -> void:
	print((("  PASS  " + desc) if ok else ("  FAIL  " + desc)))
	if !ok:
		_failed += 1


func await_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func await_until(cond: Callable, max_frames: int = 2000) -> void:
	for i in max_frames:
		if cond.call():
			return
		await get_tree().process_frame
	print("  (await_until timed out)")
