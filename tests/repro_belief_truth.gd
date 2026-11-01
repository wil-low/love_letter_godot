extends Node2D
# Issue 1 check, run in the engine.
#
# Section 1 of ai_memory_open_issues.md claims that `eval_moves` trusts `_memory` blindly
# (the Guard/Baron/Prince memory branches never consult `_left`), so a *stale* belief is
# scored greedily and played - the headline case being a memory of "rival holds the
# Princess" while the deciding seat itself holds the Princess (score 50 * 7 = 350).
#
# That claim is about states the AI can actually reach, so it is checked here at real
# decision points, in the shipped engine, over N full rounds with every seat on level 4.
# The hook is `Player.move_chosen`, which `ai_move` emits after `select_move` and before
# `Main._on_card_played` - i.e. exactly the decision-time view: memories as they were when
# the move was scored, hands as they were, `_deck._left` as it was.
#
# What is measured per decision:
#   A. belief truth: every non-Unknown belief about a LIVE rival must name that rival's
#      real hand card (`hand.get_child(0)`). A violation is a stale belief.
#   B. memory-driven Guard guesses (mem == declared type) - hit / miss / provably impossible
#      (`_left[t] - own copies of t <= 0`, the exact condition issue 1's guardrail tests)
#   C. "Princess" declared by a seat that is holding the Princess
#   D. Baron plays scored by a belief that does not match the real card
#   E. beliefs about seats that are already out, visible at decision time
#
# Measured (default 500 rounds, 4 x level 4, exit 0, no script error in the log):
#   4 666 level 4 decisions (9.3 per round)
#   A: 412 beliefs about live rivals, 0 false
#   B: 118 memory-driven Guard guesses - 118 hits, 0 miss, 0 provably impossible;
#      1 703 card-count guesses - 1 provably impossible, and that one is a legal probe the
#      shipped count branch already scores 0 (the copy it counts is in its own hand)
#   C: 1   D: 44 Baron plays scored by a belief, 0 false   E: 0
# Raising it (`--rounds=1500`, ~23 min): 13 917 decisions, 1 200 beliefs about live rivals
# with 0 false, 387 memory-driven guesses with 387 hits and 0 impossible, 101 Baron plays
# scored by a belief with 0 false, 0 zombie slots.
# The invariant held in every decision the engine played, so section 1 closes as not an issue.
# Keep ROUNDS modest: cost is superlinear in rounds (500 ~ 7 min, 1 500 ~ 23 min) because the
# test scene accumulates leaked Card nodes - the same leak tests/smoke_games.tscn reports.
#
# Run:  godot --headless --path . tests/repro_belief_truth.tscn
#       echo $?      # 0 = the belief model held, 1 = a stale belief was found

const MainScene := preload("res://main/main.tscn")

var print_memory: bool = false
var print_valid_moves: bool = false

const ROUNDS: int = 500
const SEED: int = 20261028
const FRAME_BUDGET: int = 900000

# Rounds to play: `godot --headless --path . tests/repro_belief_truth.tscn --rounds=2000`
# (the cost is superlinear - see the header - so raise it deliberately).
var rounds: int = ROUNDS

var _rounds: int = 0
var _decisions: int = 0
var _stale: Array[String] = []
var _c := {
	"beliefs_live": 0,          # A: beliefs about live rivals, at decision time
	"beliefs_false": 0,         # A: ... of which false
	"guard_mem": 0,             # B: memory-driven Guard guesses
	"guard_mem_hit": 0,
	"guard_mem_miss": 0,
	"guard_mem_impossible": 0,  # ... with no copy of that type left outside my hand
	"guard_count": 0,           # B: card-count-driven Guard guesses
	"guard_count_impossible": 0,
	"princess_declared_with_princess": 0,   # C
	"baron_mem": 0,             # D
	"baron_mem_false": 0,
	"zombie_beliefs": 0,        # E
}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rounds="):
			rounds = int(a.get_slice("--rounds=", 1))
			if rounds <= 0:
				push_error("--rounds= must be a positive integer, using " + str(ROUNDS))
				rounds = ROUNDS
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	var main: Main = MainScene.instantiate()
	add_child(main)
	for i in 4:
		main._players[i].ai_level = Player.AI_Level.Level_4
		main._players[i].move_chosen.connect(_on_move_chosen.bind(main))
	main.round_finished.connect(on_round)
	await main.init_players(SEED)

	var frames := 0
	while _rounds < 4 * rounds and frames < FRAME_BUDGET:
		frames += 1
		await get_tree().process_frame

	var ok := true
	print("\n=========== issue 1 / belief truth (%d rounds, 4 x level 4) ===========" % (_rounds / 4))
	print("decisions scored by level 4: " + str(_decisions) + "  (" + str(float(_decisions) / (_rounds / 4)) + " per round)")
	print("A  beliefs about live rivals, at decision time: " + str(_c["beliefs_live"])
		+ ", of which FALSE: " + str(_c["beliefs_false"]))
	print("B  memory-driven Guard guesses: " + str(_c["guard_mem"])
		+ "  (hit " + str(_c["guard_mem_hit"]) + ", miss " + str(_c["guard_mem_miss"])
		+ ", provably impossible " + str(_c["guard_mem_impossible"]) + ")")
	print("   card-count Guard guesses: " + str(_c["guard_count"])
		+ "  (provably impossible " + str(_c["guard_count_impossible"]) + ")")
	print("C  'Princess' declared while holding the Princess: "
		+ str(_c["princess_declared_with_princess"]))
	print("D  Baron plays scored by a belief: " + str(_c["baron_mem"])
		+ ", of which FALSE: " + str(_c["baron_mem_false"]))
	print("E  beliefs about eliminated seats at decision time: " + str(_c["zombie_beliefs"]))
	for s in _stale:
		print("  " + s)
	if (_rounds / 4) < rounds:
		print("FAIL  the games stalled after " + str(_rounds / 4) + " of " + str(rounds) + " rounds")
		ok = false
	if _c["beliefs_false"] > 0:
		print("FAIL  a belief did not name the real hand card - the premise of issue 1 is live")
		ok = false
	if _c["guard_mem_impossible"] > 0:
		print("FAIL  a memory-driven Guard guess named a type that cannot be anywhere - issue 1")
		ok = false
	if _c["baron_mem_false"] > 0:
		print("FAIL  a Baron was scored on a false belief")
		ok = false
	if ok:
		print("PASS  every belief at every level 4 decision named a real hand card; the")
		print("      stale-belief state that section 1 describes never occurs in play")
	get_tree().quit(0 if ok else 1)


func on_round(level: Player.AI_Level) -> void:
	# `Main.round_over` emits round_finished once per seat, so divide by the seat count
	_rounds += 1
	if _rounds % 400 == 0:  # every 100 game rounds: a long run should show that it is alive
		print("progress %d/%d rounds, %d decisions, %d beliefs (%d false), %d impossible guesses"
			% [_rounds / 4, rounds, _decisions, _c["beliefs_live"], _c["beliefs_false"],
				_c["guard_mem_impossible"] + _c["guard_count_impossible"]])


func _on_move_chosen(m: Move, main: Main) -> void:
	_decisions += 1
	var p: Player = main._players[main._cur_player]
	var left: Array[int] = main._deck._left

	for j in p._memory.size():
		var pl: Player = main._players[j]
		if j == p.idx or p._memory[j] == Deck.CardType.Unknown:
			continue
		if not pl.is_active():
			_c["zombie_beliefs"] += 1
			continue
		_c["beliefs_live"] += 1
		if pl.hand.get_child(0).type != p._memory[j]:
			_c["beliefs_false"] += 1
			note("stale belief: seat " + str(p.idx) + " believes seat " + str(j) + " holds "
				+ Deck.card_names[p._memory[j]] + ", real card "
				+ Deck.card_names[pl.hand.get_child(0).type])

	# `move_chosen` fires before `_on_card_played`, so the hand still holds both cards
	var tgt: Player = null if m._target_player == -1 else main._players[m._target_player]
	var own := {}
	for c in p.hand.get_children():
		own[(c as Card).type] = int(own.get((c as Card).type, 0)) + 1

	match m._played_card.type:
		Deck.CardType.Guard:
			var t: Deck.CardType = m._target_type
			var mem: Deck.CardType = p._memory[m._target_player]
			# the exact condition issue 1's drafted guardrail tests: copies of the declared type
			# outside the guessing seat's own hand. It is the card-count branch's own arithmetic
			# (player.gd:232-237), so `impossible` here means "the shipped count branch already
			# scores this 0" - not a missed play.
			var free: int = left[t] - int(own.get(t, 0))
			var hit: bool = tgt.hand.get_child(0).type == t
			if mem != Deck.CardType.Unknown and mem != Deck.CardType.Guard:
				_c["guard_mem"] += 1
				_c["guard_mem_hit"] += int(hit)
				_c["guard_mem_miss"] += int(not hit)
				_c["guard_mem_impossible"] += int(free <= 0)
				if free <= 0:
					note("impossible memory guess: seat " + str(p.idx) + " declares "
						+ Deck.card_names[t] + " on seat " + str(m._target_player)
						+ ", memory " + Deck.card_names[mem] + ", _left " + str(left))
			else:
				_c["guard_count"] += 1
				_c["guard_count_impossible"] += int(free <= 0)
			if t == Deck.CardType.Princess and own.has(Deck.CardType.Princess):
				_c["princess_declared_with_princess"] += 1
		Deck.CardType.Baron:
			var mem_b: Deck.CardType = p._memory[m._target_player]
			if mem_b != Deck.CardType.Unknown:
				_c["baron_mem"] += 1
				if tgt.hand.get_child(0).type != mem_b:
					_c["baron_mem_false"] += 1
					note("false Baron belief: seat " + str(p.idx) + " vs seat "
						+ str(m._target_player) + ", believes " + Deck.card_names[mem_b]
						+ ", real " + Deck.card_names[tgt.hand.get_child(0).type])


func note(s: String) -> void:
	if _stale.size() < 20:
		_stale.append(s)
