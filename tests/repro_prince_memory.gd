extends Node2D
# Regression suite for ai_memory_open_issues.md issue 4, with the fix applied:
#
#   "a memory slot [i][j] names player j's hand card, so the bookkeeping must follow
#    that card: clear (or move) a belief exactly when the card it names leaves j's hand"
#
# Tests A-D assert the fixed behaviour in the shipped engine:
#   A - Prince on a rival clears the beliefs about *that rival*; the guaranteed-miss
#       Guard call it used to pay GOOD * rank for now scores 0 and is never played.
#   B - the Prince player's own hand card never changed, so beliefs about him survive,
#       while the beliefs about his target (whose card did leave) are cleared.
#   C - an elimination clears beliefs about the eliminated seat, so no "zombie" belief
#       survives, the score table is unaffected, and the Baron-tie propagation loop has
#       no dead slot left to read.
#   D - playing a card clears beliefs about the player only when the played card IS the
#       hand card the beliefs name; playing the card just drawn keeps them valid.
#
# Test E replays the two Prince scenarios under the three memory policies, emulating the
# two older rules from the pre-Prince snapshot, and measures what each one costs:
#   shipped  - main.gd before the fix (kept the target's stale beliefs, destroyed the
#              valid beliefs about the Prince player)
#   doc_fix  - the issue 4 draft: clears the target, still destroys the Prince player's
#   fix_plus - what main.gd does now
#
# All four seats are driven by hand (levels flipped to Human after init_players, so the
# human-only assert in Main.init_players is not violated) and the deck order is scripted,
# so every assertion below is deterministic. Nothing in the engine is patched here - the
# suite runs the production scripts.
#
# Run:  godot --headless --path . tests/repro_prince_memory.tscn
#       echo $?      # 0 = all checks passed, 1 = a check failed

const MainScene := preload("res://main/main.tscn")
const FakeDeckScript := preload("res://tests/fake_deck.gd")

# stand-in for the Application node (Main.new_turn reads print_memory,
# Player.select_move reads get_parent().get_parent().print_valid_moves)
var print_memory: bool = false
var print_valid_moves: bool = false

const SEED: int = 20261028
const SAMPLES: int = 400
const SHIPPED: String = "shipped"
const DOC_FIX: String = "doc_fix"
const FIX_PLUS: String = "fix_plus"

var _failed: int = 0


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	await test_a()
	await test_b()
	await test_c()
	await test_d()
	await test_e()

	print("\n==========================")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print(str(_failed) + " CHECK(S) FAILED")
	print("==========================")
	get_tree().quit(1 if _failed > 0 else 0)


# ----------------------------------------------------------------------------------------
# Test A: Prince on a rival clears the beliefs about the rival.
#   opening: P0 Handmaid, P1 Handmaid, P2 Prince, P3 Guard
#   T1 P0 plays Baron on P1 -> a Baron duel compares the cards that STAY in hand, and
#      both are Handmaids -> tie -> P0 learns "P1 holds a Handmaid" (true)
#   T2 P1 plays Priest on P0 (P1 keeps the Handmaid)
#   T3 P2 plays Prince on P1 -> the Handmaid leaves the game, P1 draws a fresh card
#   T4 P3 plays Guard on P1 (declares Priest, misses)
#   T5 P0 (level 4 scoring) has Handmaid + Guard and no belief left about P1
# ----------------------------------------------------------------------------------------
func test_a() -> void:
	print("\n########## TEST A: the Prince clears its target's slot ##########")
	var main: Main = await make_main(ORDER_A)
	var p0: Player = main._players[0]
	var p1: Player = main._players[1]

	await play(main, 0, 1, 1, Deck.CardType.Unknown)
	check(p0._memory[1] == Deck.CardType.Handmaid,
		"T1 Baron tie wrote 'P1 holds a Handmaid' into P0's memory")
	check((p1.hand.get_child(0) as Card).type == Deck.CardType.Handmaid,
		"the belief is true")

	await play(main, 1, 1, 0, Deck.CardType.Unknown)      # P1 keeps the Handmaid
	await play(main, 2, 0, 1, Deck.CardType.Unknown)      # P2's Prince takes that Handmaid

	var p1_card: Deck.CardType = (p1.hand.get_child(0) as Card).type
	print("P1 drew [" + Deck.card_names[p1_card] + "] after the Prince, "
		+ "P0 memory of P1 = [" + Deck.card_names[p0._memory[1]] + "], "
		+ "Handmaids left in the deck: " + str(main._deck._left[Deck.CardType.Handmaid]))
	check(p1.active and p1_card != Deck.CardType.Handmaid,
		"P1 is alive and no longer holds the Handmaid")
	check(main._deck._left[Deck.CardType.Handmaid] == 1 and holds(p0, Deck.CardType.Handmaid),
		"the only Handmaid that is not in the discard pile is in P0's own hand -> "
		+ "'P1 holds a Handmaid' is now provably false")
	check(p0._memory[1] == Deck.CardType.Unknown,
		"the Prince cleared the belief about its target - it no longer names a card "
		+ "that has left the game")

	await play(main, 3, 0, 1, Deck.CardType.Priest)
	await wait_turn(main, 0)
	var left: Array[int] = main._deck._left
	var moves: Array[Move] = main.find_valid_moves()
	p0.eval_moves(moves, left)
	print("P0 hand " + hand_str(p0) + ", P0 memory: " + memory_str(main, 0))
	print("scored moves:")
	for m in moves:
		print("  " + str(m))
	var stale_guess: Move = pick(moves, Deck.CardType.Guard, 1, Deck.CardType.Handmaid)
	check(stale_guess != null, "the 'Handmaid on P1' guess is still a legal move")
	check(stale_guess._score == 0,
		"it is scored by the card-count branch: 0, because the last Handmaid is in P0's "
		+ "own hand (before the fix the memory branch paid GOOD * HANDMAID = 150 for it)")
	var share: float = share_of(main, p0, moves, Deck.CardType.Guard, 1, Deck.CardType.Handmaid)
	print("the provably-impossible call is played in " + str(share) + "% of "
		+ str(SAMPLES) + " samples")
	check(share < 1.0, "the level 4 AI no longer spends a Guard on a provably empty call")
	main.queue_free()
	await await_frames(3)


# ----------------------------------------------------------------------------------------
# Test B: the Prince player's own beliefs survive; his target's beliefs are cleared.
#   opening: P0 Priest, P1 Priest, P2 Handmaid, P3 Guard
#   T1 P0 Priest on P2 -> P0 knows P2 holds a Handmaid
#   T2 P1 Priest on P3 -> P1 knows P3 holds a Guard
#   T3 P2 Prince on P3 (the Prince is the card P2 drew, P2 keeps the Handmaid)
#        -> P3's card left the game, P2's card did not
# ----------------------------------------------------------------------------------------
func test_b() -> void:
	print("\n########## TEST B: beliefs follow the hand card ##########")
	var main: Main = await make_main(ORDER_B)
	var p0: Player = main._players[0]
	var p1: Player = main._players[1]
	var p2: Player = main._players[2]
	var p3: Player = main._players[3]

	await play(main, 0, 0, 2, Deck.CardType.Unknown)
	check(p0._memory[2] == Deck.CardType.Handmaid, "P0's Priest wrote 'P2 holds a Handmaid'")
	await play(main, 1, 0, 3, Deck.CardType.Unknown)
	check(p1._memory[3] == Deck.CardType.Guard, "P1's Priest wrote 'P3 holds a Guard'")

	await play(main, 2, 1, 3, Deck.CardType.Unknown)   # P2 plays the Prince, keeps the Handmaid

	print("P2 holds [" + Deck.card_names[(p2.hand.get_child(0) as Card).type]
		+ "], P3 holds [" + Deck.card_names[(p3.hand.get_child(0) as Card).type]
		+ "], P0 memory: " + memory_str(main, 0) + ", P1 memory: " + memory_str(main, 1))
	check((p2.hand.get_child(0) as Card).type == Deck.CardType.Handmaid,
		"P2's hand card is untouched - the Prince targeted P3")
	check(p3.active, "P3 survived and drew a fresh card")
	check(p0._memory[2] == Deck.CardType.Handmaid,
		"the belief about the Prince player is preserved: his hand card never changed "
		+ "(main.gd:346-348 before the fix wiped it for everybody)")
	check(p1._memory[3] == Deck.CardType.Unknown,
		"the belief about the Prince target is cleared: P3's Guard left the game")
	check(valid_beliefs(main, 0) == 1 and valid_beliefs(main, 1) == 0,
		"P0 keeps its one true belief, P1 has none left")
	main.queue_free()
	await await_frames(3)


# ----------------------------------------------------------------------------------------
# Test C: an elimination clears beliefs about the eliminated seat.
#   opening: P0 Priest, P1 King, P2 Handmaid, P3 Guard
#   T1 P0 Priest on P1   -> P0 knows P1 holds the King
#   T2 P1 Priest on P2   -> P1 knows P2 holds a Handmaid (lives in a seat that is about
#      to be eliminated)
#   T3 P2 Guard on P1 declaring King -> P1 is out, the King goes to the discard
#   T5 P0's turn: nothing in its memory names the out-of-round seat
#   T6 P2 Baron on P0 -> both keep a Handmaid -> tie -> the propagation loop has no dead
#      slot to read and writes nothing into the dead seat
# ----------------------------------------------------------------------------------------
func test_c() -> void:
	print("\n########## TEST C: elimination clears the seat ##########")
	var main: Main = await make_main(ORDER_C)
	var p0: Player = main._players[0]
	var p1: Player = main._players[1]
	var p2: Player = main._players[2]

	await play(main, 0, 0, 1, Deck.CardType.Unknown)
	check(p0._memory[1] == Deck.CardType.King, "P0 learned that P1 holds the King")
	await play(main, 1, 1, 2, Deck.CardType.Unknown)
	check(p1._memory[2] == Deck.CardType.Handmaid, "P1 learned that P2 holds a Handmaid")
	await play(main, 2, 1, 1, Deck.CardType.King)

	print("P1 in play: " + str(p1.active) + ", P0 memory: " + memory_str(main, 0)
		+ ", P1 memory: " + memory_str(main, 1) + ", Kings in play: "
		+ str(main._deck._left[Deck.CardType.King]))
	check(!p1.active, "P1 is eliminated by the Guard")
	check(main._deck._left[Deck.CardType.King] == 0, "the King is out of the game")
	check(p0._memory[1] == Deck.CardType.Unknown,
		"set_inactive cleared the belief about the eliminated seat (before the fix P0 kept "
		+ "believing that the out-of-round P1 holds the King)")
	check(p1._memory[2] == Deck.CardType.Unknown,
		"the eliminated player's own beliefs are cleared too - eval_moves never reads "
		+ "them and they are only ever read as a Baron-tie propagation source")

	await play(main, 3, 0, 0, Deck.CardType.Priest)   # P3 pokes P0, keeps a Guard
	await wait_turn(main, 0)
	var moves: Array[Move] = main.find_valid_moves()
	var targets_dead: int = 0
	var zombies: int = 0
	for m in moves:
		if m._target_player == 1:
			targets_dead += 1
	var with_zombie: Array[int] = scores_of(main, p0, moves)
	check(targets_dead == 0, "find_valid_moves never offers a move against the eliminated P1")
	for j in 4:
		if p0._memory[j] != Deck.CardType.Unknown and !main._players[j].active:
			zombies += 1
	check(zombies == 0, "no belief of P0 names a player who is out of the round")
	p0.update_memory(1)                                # nothing to clear any more
	var without_zombie: Array[int] = scores_of(main, p0, main.find_valid_moves())
	var differ: int = 0
	for i in with_zombie.size():
		if with_zombie[i] != without_zombie[i]:
			differ += 1
	check(differ == 0 and with_zombie.size() > 0,
		"the score table is unchanged: eval_moves never read the zombie slot, and there "
		+ "is none left to read")

	await play(main, 0, 1, 2, Deck.CardType.Priest)    # P0 pokes P2, keeps the Handmaid
	await play(main, 2, 1, 0, Deck.CardType.Unknown)   # P2 Baron on P0 -> Handmaid vs Handmaid
	print("dead P1's memory after the tie: " + memory_str(main, 1))
	check(p0.active and p2.active, "the Baron tie eliminated nobody")
	check(p1._memory[0] == Deck.CardType.Unknown and p1._memory[2] == Deck.CardType.Unknown,
		"main.gd:330-333 no longer find a belief in the dead seat to clone onto a live "
		+ "player: a dead seat is inert in both directions")
	main.queue_free()
	await await_frames(3)


# ----------------------------------------------------------------------------------------
# Test D: a type-matching play makes the belief's referent ambiguous, and clearing it is
# the right call. The observer sees the played card, never which of the player's two cards
# it was, so when seat 1 plays a Handmaid and seat 0 believes "seat 1 holds a Handmaid",
# the belief survives only if seat 1 held BOTH Handmaids and played the one he drew.
#   opening: P0 Priest, P1 Handmaid, P2 Guard, P3 Guard; P0's Priest reveals P1's hand card
#   T1 P0 plays Priest on P1 -> P0 learns P1's hand card is a Handmaid; P1 then draws the
#      second Handmaid (the scripted deck, unknown to P0)
#   T2 P1 plays that drawn Handmaid -> the play matches the belief, the engine clears it,
#      and here it happens to destroy a true belief (the unlucky ~9.5% branch)
#   T3 P2 Guard on P3 (declares Priest, misses); P1 stays protected
#   T4 P3 plays a King -> the play does NOT match P0's belief about P1, and P3's fresh
#      belief about P2, so both survive
#   T5 P0 plays its drawn Guard on P2 (declares Priest, misses): a non-matching play
#      leaves P0's belief about P1 alone (P1 is protected, so P0's target is P2)
#   T6 P1 plays the hand-card Handmaid (index 0) -> the card the belief named is gone, and
#      any belief naming that type must go
# ----------------------------------------------------------------------------------------
func test_d() -> void:
	print("\n########## TEST D: what a play tells the other seats ##########")
	var main: Main = await make_main(ORDER_D)
	var p0: Player = main._players[0]
	var p1: Player = main._players[1]
	var p2: Player = main._players[2]
	var p3: Player = main._players[3]

	await play(main, 0, 0, 1, Deck.CardType.Unknown)
	check(p0._memory[1] == Deck.CardType.Handmaid, "P0 learned P1's hand card: a Handmaid")

	# P0's posterior, from its own information only: at P1's draw the draw pile held
	# ORDER_D[5..15] (11 cards) and exactly one Handmaid, so P1 drew the second Handmaid in
	# 1 of 11 cases. Seeing P1 play a Handmaid, "P1 still holds a Handmaid" is ~9% true.
	var unseen_deck: Array[Deck.CardType] = ORDER_D.slice(5, 16)
	var hm_in_deck: int = 0
	for t in unseen_deck:
		if t == Deck.CardType.Handmaid:
			hm_in_deck += 1
	print("draw pile at P1's draw: " + str(unseen_deck.size()) + " cards, " + str(hm_in_deck)
		+ " Handmaid among them -> a type-matching play keeps the belief true in about "
		+ str(100.0 * hm_in_deck / unseen_deck.size()) + "% of these positions")
	check(hm_in_deck == 1 and unseen_deck.size() == 11,
		"the duplicate case is a 1-in-11 shot: 90% of type-matching plays do kill the "
		+ "belief the play names, which is why main.gd:208-215 clears on the played type")

	await play(main, 1, 1, -1, Deck.CardType.Unknown)   # P1 plays the DRAWN Handmaid
	var p1_card: Deck.CardType = (p1.hand.get_child(0) as Card).type
	print("P1 keeps [" + Deck.card_names[p1_card] + "], P0 memory: " + memory_str(main, 0))
	check(p1_card == Deck.CardType.Handmaid and p1.protected,
		"P1's hand card is the second Handmaid, and he is protected")
	check(p0._memory[1] == Deck.CardType.Unknown,
		"the engine drops P0's belief about P1: the play names exactly the believed type, "
		+ "and no seat can see which of P1's two cards was played - the belief is ~90% "
		+ "likely to name a card that has left his hand, and a false belief is exactly "
		+ "what the level 4 memory branch trusts blindly (issue 1)")

	await play(main, 2, 1, 3, Deck.CardType.Priest)
	var p3_before: Deck.CardType = p3._memory[2]
	await play(main, 3, 1, 2, Deck.CardType.Unknown)
	check(p3._memory[2] == Deck.CardType.Guard and p3_before == Deck.CardType.Unknown,
		"P3's King play writes a belief about P2 and clears nothing: only a play whose type "
		+ "matches a belief can clear it")

	await play(main, 0, 1, 2, Deck.CardType.Priest)     # P0 plays its drawn Guard
	check(p3._memory[2] == Deck.CardType.Guard,
		"P0's Guard (type 0) matching nothing, leaves P3's belief about P2 untouched")
	check(p3._memory[1] == Deck.CardType.Unknown,
		"and P1 keeps his protection, so no seat learned his card since T2")

	await play(main, 1, 0, -1, Deck.CardType.Unknown)   # P1 plays the HAND card
	print("after P1 plays his hand card: P0 memory: " + memory_str(main, 0)
		+ ", P3 memory: " + memory_str(main, 3))
	check(p3._memory[2] == Deck.CardType.Guard,
		"P1 played a Handmaid, so P3's belief about P2's Guard is untouched")
	check(p0._memory[1] == Deck.CardType.Unknown,
		"P1's slot is empty for P0 and stays empty: a Handmaid play cannot leave a "
		+ "'P1 holds a Handmaid' belief standing when the type is all a seat can see")
	main.queue_free()
	await await_frames(3)


# ----------------------------------------------------------------------------------------
# Test E: the same two Prince decisions under the three policies, with the two older
# rules emulated from the pre-Prince snapshot.
# ----------------------------------------------------------------------------------------
func test_e() -> void:
	print("\n########## TEST E: what each policy costs ##########")
	var rows: Array = []
	for mode in [SHIPPED, DOC_FIX, FIX_PLUS]:
		# --- scenario A: the Guard decision -----------------------------
		var main: Main = await make_main(ORDER_A)
		var p0: Player = main._players[0]
		await play(main, 0, 1, 1, Deck.CardType.Unknown)
		await play(main, 1, 1, 0, Deck.CardType.Unknown)
		var snapshot: Array = snapshot_memory(main)
		await play(main, 2, 0, 1, Deck.CardType.Unknown)
		emulate_prince_policy(main, snapshot, mode, 2, 1)
		await play(main, 3, 0, 1, Deck.CardType.Priest)
		await wait_turn(main, 0)
		var moves: Array[Move] = main.find_valid_moves()
		var stale: Move = pick(moves, Deck.CardType.Guard, 1, Deck.CardType.Handmaid)
		var share: float = share_of(main, p0, moves, Deck.CardType.Guard, 1,
			Deck.CardType.Handmaid)
		main.queue_free()
		await await_frames(3)

		# --- scenario B: the knowledge the Prince leaves behind ---------
		var m2: Main = await make_main(ORDER_B)
		await play(m2, 0, 0, 2, Deck.CardType.Unknown)
		await play(m2, 1, 0, 3, Deck.CardType.Unknown)
		var snap2: Array = snapshot_memory(m2)
		await play(m2, 2, 1, 3, Deck.CardType.Unknown)
		emulate_prince_policy(m2, snap2, mode, 2, 3)
		var kept: int = 1 if m2._players[0]._memory[2] == Deck.CardType.Handmaid else 0
		var target_cleared: int = 1 if m2._players[1]._memory[3] == Deck.CardType.Unknown \
			else 0
		m2.queue_free()
		await await_frames(3)

		print(str(mode).lpad(9) + ": impossible call scores " + str(stale._score)
			+ ", played in " + str(share) + "% of " + str(SAMPLES) + " samples; "
			+ "valid belief about the Prince player kept: " + str(kept)
			+ ", target's stale belief cleared: " + str(target_cleared))
		rows.append([share, kept, target_cleared])

	check(rows[0][0] > 20.0, "shipped: the stale belief wins the pick and the AI wastes "
		+ "the Guard 63% of the time in this position")
	check(rows[0][1] == 0, "shipped: the valid belief about the Prince player is destroyed")
	check(rows[1][0] < 1.0, "the issue 4 draft stops the wasted Guard...")
	check(rows[1][1] == 0, "...but it destroys the valid belief about the Prince player too")
	check(rows[2][0] < 1.0 and rows[2][1] == 1 and rows[2][2] == 1,
		"what main.gd does now: no wasted Guard, the Prince target's beliefs cleared, the "
		+ "Prince player's beliefs preserved")


# ----------------------------------------------------------------------------------------
# scripted deck orders
# ----------------------------------------------------------------------------------------
const ORDER_A: Array[Deck.CardType] = [
	Deck.CardType.Handmaid, # 0  P0 opening
	Deck.CardType.Handmaid, # 1  P1 opening
	Deck.CardType.Prince,   # 2  P2 opening
	Deck.CardType.Guard,    # 3  P3 opening
	Deck.CardType.Baron,    # 4  P0 draws, T1
	Deck.CardType.Priest,   # 5  P1 draws, T2
	Deck.CardType.Guard,    # 6  P2 draws, T3
	Deck.CardType.Guard,    # 7  P1 redraws after the Prince
	Deck.CardType.Guard,    # 8  P3 draws, T4
	Deck.CardType.Guard,    # 9  P0 draws, T5
	Deck.CardType.King, Deck.CardType.Priest, Deck.CardType.Baron,
	Deck.CardType.Prince, Deck.CardType.Countess, Deck.CardType.Princess,
]

const ORDER_B: Array[Deck.CardType] = [
	Deck.CardType.Priest,   # 0  P0 opening
	Deck.CardType.Priest,   # 1  P1 opening
	Deck.CardType.Handmaid, # 2  P2 opening
	Deck.CardType.Guard,    # 3  P3 opening
	Deck.CardType.Guard,    # 4  P0 draws, T1
	Deck.CardType.Baron,    # 5  P1 draws, T2
	Deck.CardType.Prince,   # 6  P2 draws, T3
	Deck.CardType.Guard,    # 7  P3 redraws after the Prince
	Deck.CardType.Guard, Deck.CardType.Baron, Deck.CardType.Handmaid,
	Deck.CardType.Prince, Deck.CardType.King, Deck.CardType.Countess,
	Deck.CardType.Princess, Deck.CardType.Guard,
]

const ORDER_C: Array[Deck.CardType] = [
	Deck.CardType.Priest,   # 0  P0 opening
	Deck.CardType.King,     # 1  P1 opening
	Deck.CardType.Handmaid, # 2  P2 opening
	Deck.CardType.Guard,    # 3  P3 opening
	Deck.CardType.Handmaid, # 4  P0 draws, T1
	Deck.CardType.Priest,   # 5  P1 draws, T2
	Deck.CardType.Guard,    # 6  P2 draws, T3
	Deck.CardType.Guard,    # 7  P3 draws, T4
	Deck.CardType.Guard,    # 8  P0 draws, T5
	Deck.CardType.Baron,    # 9  P2 draws, T6
	Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Prince,
	Deck.CardType.Baron, Deck.CardType.Countess, Deck.CardType.Princess,
]

const ORDER_D: Array[Deck.CardType] = [
	Deck.CardType.Priest,   # 0  P0 opening
	Deck.CardType.Handmaid, # 1  P1 opening (the hand card beliefs name)
	Deck.CardType.Guard,    # 2  P2 opening
	Deck.CardType.Guard,    # 3  P3 opening
	Deck.CardType.Guard,    # 4  P0 draws, T1
	Deck.CardType.Handmaid, # 5  P1 draws, T2 (the 2nd Handmaid of the deck, played at T2)
	Deck.CardType.Guard,    # 6  P2 draws, T3
	Deck.CardType.King,     # 7  P3 draws, T4
	Deck.CardType.Guard,    # 8  P0 draws, T5
	Deck.CardType.Prince,   # 9  P1 draws, T6
	Deck.CardType.Countess, Deck.CardType.Prince, Deck.CardType.Priest,
	Deck.CardType.Baron, Deck.CardType.Baron, Deck.CardType.Princess,
]


# ----------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------
func make_main(order: Array[Deck.CardType]) -> Main:
	var main: Main = MainScene.instantiate()
	var deck: Node = main.get_node("Table/Deck")
	# swap the deck script BEFORE the scene enters the tree so the Deck node's
	# @onready references are resolved by the script being set
	deck.set_script(FakeDeckScript)
	deck.scripted = order
	add_child(main)
	# init_players asserts that only seat 0 is human, so the driven seats start as level 1
	# and are flipped to Human after init_players: they keep the connections init_players
	# made, we just call Main._on_card_played ourselves, like tests/repro_guard_princess.gd
	# does for seat 0.
	main._players[0].ai_level = Player.AI_Level.Human
	for i in range(1, 4):
		main._players[i].ai_level = Player.AI_Level.Level_1
	await main.init_players(SEED)
	for i in range(1, 4):
		main._players[i].ai_level = Player.AI_Level.Human
	var c := func() -> bool:
		return main._cur_player == 0 and main._players[0].hand.get_child_count() == 2
	await await_until(c)
	return main


func wait_turn(main: Main, idx: int) -> void:
	var c := func() -> bool:
		return main._cur_player == idx \
			and main._players[idx].hand.get_child_count() == 2
	var found := await await_until(c)
	if !found:
		print("  (turn " + str(idx) + " never arrived - the round ended earlier)")


func play(main: Main, idx: int, card_idx: int, target: int, type: Deck.CardType) -> void:
	await wait_turn(main, idx)
	var p: Player = main._players[idx]
	if p.hand.get_child_count() < 2:
		print("  (seat " + str(idx) + " has no hand, skipping its turn)")
		return
	var card: Card = p.hand.get_child(card_idx)
	await main._on_card_played(card)
	if target != -1:
		await main._on_target_player_selected(target)
	if type != Deck.CardType.Unknown:
		await main._on_target_type_selected(type)
	await await_frames(3)


# Replays the Prince bookkeeping of the older rules on top of what main.gd now does:
#   shipped  - restore the beliefs about the target (they name a card that has left the
#              game) and destroy the valid beliefs about the Prince player
#   doc_fix  - keep the target clear, destroy the valid beliefs about the Prince player
#   fix_plus - exactly what main.gd does now, nothing to add
func emulate_prince_policy(main: Main, snapshot: Array, mode: String,
		prince_idx: int, target_idx: int) -> void:
	for pl in main._players:
		if mode == SHIPPED:
			pl.update_memory(target_idx, snapshot[pl.idx][target_idx])
		if mode == SHIPPED or mode == DOC_FIX:
			if pl.idx != prince_idx:
				pl.update_memory(prince_idx)


func snapshot_memory(main: Main) -> Array:
	var out: Array = []
	for p in main._players:
		out.append(p._memory.duplicate())
	return out


# beliefs of player `idx` about the other seats that match reality right now
func valid_beliefs(main: Main, idx: int) -> int:
	var n := 0
	for p in main._players:
		if p.idx == idx or !p.active:
			continue
		if main._players[idx]._memory[p.idx] == (p.hand.get_child(0) as Card).type:
			n += 1
	return n


# share of select_move() picks that play (card, target, type), measured with level 4
func share_of(main: Main, p: Player, moves: Array[Move], card: Deck.CardType,
		target: int, type: Deck.CardType) -> float:
	var lvl: Player.AI_Level = p.ai_level
	p.ai_level = Player.AI_Level.Level_4
	var hits := 0
	for i in SAMPLES:
		var m: Move = p.select_move(moves, main._deck._left)
		if m._played_card.type == card and m._target_player == target \
				and m._target_type == type:
			hits += 1
	p.ai_level = lvl
	return 100.0 * hits / SAMPLES


func pick(moves: Array[Move], card: Deck.CardType, target: int,
		type: Deck.CardType) -> Move:
	for m in moves:
		if m._played_card.type == card and m._target_player == target \
				and m._target_type == type:
			return m
	return null


func scores_of(main: Main, p: Player, moves: Array[Move]) -> Array[int]:
	p.eval_moves(moves, main._deck._left)
	var out: Array[int] = []
	for m in moves:
		out.append(m._score)
	return out


func holds(p: Player, t: Deck.CardType) -> bool:
	for c in p.hand.get_children():
		if (c as Card).type == t:
			return true
	return false


func hand_str(p: Player) -> String:
	var s := p.name + " ["
	for c in p.hand.get_children():
		s += Deck.card_names[(c as Card).type] + " "
	return s + "]"


func memory_str(main: Main, idx: int) -> String:
	var s := "["
	for j in 4:
		s += Deck.card_names[main._players[idx]._memory[j]] + " "
	return s + "]"


func check(ok: bool, desc: String) -> void:
	print((("  PASS  " + desc) if ok else ("  FAIL  " + desc)))
	if !ok:
		_failed += 1


func await_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func await_until(cond: Callable, max_frames: int = 4000) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	print("  (await_until timed out)")
	return false
