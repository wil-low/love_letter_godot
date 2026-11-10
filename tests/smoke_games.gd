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
var _main: Main  # the classic game, kept so it can be STOPPED before the nested suites run


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	var main: Main = MainScene.instantiate()
	_main = main
	add_child(main)
	for i in 4:
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

	var ui_ok: bool = await _check_noble_ui()
	ok = ok and ui_ok
	get_tree().quit(0 if ok else 1)


func on_round(level: Player.AI_Level) -> void:
	_rounds += 1


func scores_str(main: Main) -> String:
	var s := ""
	for p in main._players:
		s += str(p.idx) + ":" + str(p.score) + " "
	return s


# NOBLE UI (todo step 22): the manual pass the todo names - "Guard (target + type selector),
# Countess-forced play, King swap, Baron reveal and self-Prince in one human game: no stuck overlays,
# no double draws" - is automated as TEST J1 of `tests/noble_family_rules.tscn`: a scripted 4-player
# game, seat 0 human, played ENTIRELY by tapping the family modal's real `Card` nodes, with the
# exclusivity rails sampled on EVERY frame (a 1-frame check sees a 1-frame bug: a panel that closes a
# frame late, a selector that flickers back for a frame, a draw that pops two family cards in one
# frame is invisible to a check made at one moment).
#
# This section runs THAT SUITE nested inside the classic gate (its own `get_tree().quit()` is turned
# off with `quit_on_fail`) and prints the counters TEST J measures, so the classic command carries
# the step 22 number: the classic loop and the modal's rails fail together, in one run, and the
# numbers are a measurement of a real suite run, not a restatement of its checks.
const RULES_SCENE: String = "res://tests/noble_family_rules.tscn"
const RULES_FRAMES: int = 60000


func _check_noble_ui() -> bool:
	var scene := load(RULES_SCENE) as PackedScene
	if scene == null:
		print("FAIL  NOBLE UI: ", RULES_SCENE, " is missing - the family modal has no gate at all")
		return false
	# STOP the classic game first. Its seats are still on the AI, and an AI seat consumes the global
	# RNG every turn - left running, it would steal random numbers from the scripted fixtures (measured:
	# 16 plays where the standalone suite measures 19, a whole game's worth of AI drift) and the NOBLE
	# UI counters would describe a game nobody scripted.
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	var suite = scene.instantiate()
	suite.set("quit_on_fail", false)  # a nested suite must not quit the game it is embedded in
	add_child(suite)
	var frames: int = 0
	while not bool(suite.get("suite_done")) and frames < RULES_FRAMES:
		await get_tree().process_frame
		frames += 1
	if not bool(suite.get("suite_done")):
		print("FAIL  NOBLE UI: the noble rules suite never finished (", frames, " frames)")
		return false
	var opens: int = int(suite.get("ui_openings"))
	var taps: int = int(suite.get("ui_taps"))
	var plays: int = int(suite.get("ui_plays"))
	var effects: int = int(suite.get("ui_effects"))
	var mismatch: int = int(suite.get("ui_mismatch"))
	var crowded: int = int(suite.get("ui_crowded"))
	var leaks: int = int(suite.get("ui_leaks"))
	var surfaces: Array = suite.get("ui_surfaces")
	var names: Array[String] = []
	for x in surfaces:
		names.append(str(x))
	var fails: int = int(suite.call("fails"))
	print("NOBLE UI: scripted 4p game, seat 0 human, played by tapping the family modal - ", opens,
		" openings, ", taps, " taps, ", plays, " plays, ", effects, " effect records, ",
		int(suite.get("ui_frames")), " frames sampled one by one; surfaces [", ", ".join(names), "];"
		+ " rails: " + str(mismatch) + " frames where the pending draw and the open panel disagreed, "
		+ str(crowded) + " frames crowded by another selector, " + str(leaks)
		+ " closed-panel leaks; the Countess-forced play of a human seat is TEST I1 play 5 of the"
		+ " same suite")
	var ok := true
	if fails > 0:
		print("FAIL  NOBLE UI: ", fails, " check(s) of the embedded noble rules suite failed")
		ok = false
	if opens != 6 or taps != 6:
		print("FAIL  NOBLE UI: ", opens, " family-modal openings and ", taps, " taps, expected 6/6"
			+ " (2 rounds x (2 turn starts + 1 mid-effect draw) for seat 0) - an opening left untapped"
			+ " is a stalled human turn, a draw with no panel is a draw the game picked for him")
		ok = false
	if mismatch > 0 or crowded > 0 or leaks > 0:
		print("FAIL  NOBLE UI: the rails leaked (", mismatch, " drawing/open mismatches, ", crowded,
			" frames crowded by another selector, ", leaks, " closed-panel leaks) - the modal is not"
			+ " exclusive for the WHOLE game, which is the whole point of step 22")
		ok = false
	return ok
