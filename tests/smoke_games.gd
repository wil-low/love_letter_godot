extends Node2D
# Smoke test: plays full games in the engine, every seat driven by the AI, animations at
# speed 0, and checks that the game loop keeps producing rounds and eliminations after the
# issue 4 memory-bookkeeping fix in main.gd (which clears memories in set_inactive).
#
# Run:  godot --headless --path . tests/smoke_games.tscn
#       echo $?      # 0 = the games kept flowing, 1 = they stalled / no elimination
#
# Script errors show up in the output; grep the log for "SCRIPT ERROR".
# main.gd calls Player.set_inactive directly (the defence_failed / self_eliminated signals
# belong to the human input path), so eliminations are counted by watching the seats flip
# from active to inactive.

const MainScene := preload("res://main/main.tscn")

var print_memory: bool = false
var print_valid_moves: bool = false

const ROUNDS: int = 300
const SEED: int = 20260607
const FRAME_BUDGET: int = 300000
const LEVELS: Array[Player.AI_Level] = [
	Player.AI_Level.Level_4,
	Player.AI_Level.Level_4,
	Player.AI_Level.Level_3,
	Player.AI_Level.Level_2,
]

var _rounds: int = 0
var _eliminations: int = 0


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	var main: Main = MainScene.instantiate()
	add_child(main)
	for i in len(main._players):
		main._players[i].ai_level = LEVELS[i]
	main.round_finished.connect(on_round)
	await main.init_players(SEED)

	var was_active: Array[bool] = []
	for p in main._players:
		was_active.append(p.active)

	var frames := 0
	for i in FRAME_BUDGET:
		frames += 1
		for j in main._players.size():
			if was_active[j] and !main._players[j].active:
				_eliminations += 1
			was_active[j] = main._players[j].active
		if _rounds >= ROUNDS:
			break
		await get_tree().process_frame

	print("========== smoke test ==========")
	print("rounds played: " + str(_rounds) + ", games: " + str(main.game_counter)
		+ ", eliminations: " + str(_eliminations) + ", scores: " + scores_str(main))
	var ok := true
	if _rounds < ROUNDS:
		print("FAIL  the games stalled after " + str(_rounds) + " rounds")
		ok = false
	if _eliminations == 0:
		print("FAIL  no elimination in " + str(ROUNDS) + " rounds - the elimination "
			+ "path (and the new set_inactive clear) is not covered")
		ok = false
	if ok:
		print("PASS  " + str(ROUNDS) + " rounds played with all four seats on the AI, "
			+ str(_eliminations) + " eliminations, no script error")
	get_tree().quit(0 if ok else 1)


func on_round(level: Player.AI_Level) -> void:
	_rounds += 1


func scores_str(main: Main) -> String:
	var s := ""
	for p in main._players:
		s += str(p.idx) + ":" + str(p.score) + " "
	return s
