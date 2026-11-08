extends Node2D
# Noble Family variant smoke test (docs/noble-family-todo.md steps 7 + 11: joint (draw, play, target) moves,
# verified per move from inside the play chain by CountingMain._on_move_chosen).
#
# Plays whole variant games in the production scene with every seat on the AI (levels 4/4/3/2),
# animations at speed 0, audio muted, and asserts that the variant loop keeps producing rounds,
# games and eliminations - and that a round ends exactly at the turn start where the seat to act
# has run out of family cards.
#
# Run:  godot --headless --path . tests/noble_family_smoke.tscn
#       godot --headless --path . tests/noble_family_smoke.tscn -- --players=2 --rounds=40
#       echo $?      # 0 = the variant games flowed, 1 = a check failed / the loop stalled
#
# Event counting. No production file is touched: `tests/counting_main.gd` (extends Main) is
# installed on the instantiated scene with `set_script` and records eliminations, round ends (with
# the seat that was to act) and family draws. Polling per frame cannot work at `Animator._speed = 0`:
# the chain "family draw -> play -> effect -> next turn", and even
# "eliminate -> round_over -> label -> _new_round -> active = true", can resolve inside ONE frame,
# so hand sizes, `Player.active` and the round-over label look unchanged between two samples.
# Plays are counted on each seat's own signals (`move_chosen` for the AI, `card_played` for a human).
#
# Family accounting (this is what the round-end rule really means): a seat consumes one family
# card per own turn (the mandatory turn-start draw) AND one per Prince redraw aimed at him, so
# `plays[seat] <= family_draws[seat] <= family_size` and the round ends when the seat to act has
# drawn his last family card - `plays[seat]` alone need not reach `family_size` (12 plays in a
# 4-player round only when no Prince touched anybody).
#
# Checks per finished round:
# - `plays[seat] <= family_draws[seat] <= family size`, and `family_size(seat) == family size -
#   family_draws[seat]` (the family array shrinks by exactly the draws);
# - a round with no elimination is a family-out end: the seat that was to act has an EMPTY family
#   (his family draws == family size), and `sum(Deck._left) == 16 - plays - prince_plays` (plays and
#   the Prince's discarded target card are the only decrements - family draws must not touch `_left`);
# - every live seat holds exactly 1 card at round end (the invariant the whole design rests on).
# Suite-level: the requested round count is reached, at least 1 elimination happens, at least
# 1 round runs all the way to the family-out end.

const MainScene := preload("res://main/main.tscn")
const CountingMain := "res://tests/counting_main.gd"  # load()ed at runtime: preload() would make
# a cyclic dependency (this harness preloads main.tscn, counting_main.gd extends Main)

var print_memory: bool = false
var print_valid_moves: bool = false  # set by --print-moves=1

const SEED: int = 20260607
const PLAYERS: int = 4
const ROUNDS: int = 40
const FRAME_BUDGET: int = 200000
const LEVELS: Array[Player.AI_Level] = [
	Player.AI_Level.Level_4,
	Player.AI_Level.Level_4,
	Player.AI_Level.Level_3,
	Player.AI_Level.Level_2,
]

var plays: Array[int] = [0, 0, 0, 0]
var fam_draws: Array[int] = [0, 0, 0, 0]
var prince_plays: int = 0
var _prince_total: int = 0

var _rounds: int = 0
var _family_out_ends: int = 0
var _elim_rounds: int = 0
var _eliminations: int = 0
var _plays_total: int = 0
var _max_plays: int = 0
var _failures: int = 0


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	var count: int = _arg("players", PLAYERS)
	var target_rounds: int = _arg("rounds", ROUNDS)
	var seed_value: int = _arg("seed", SEED)
	# `-- --print_moves=1` turns on Main's own move-list dump (the step 11 gate check: every
	# variant move line shows the draw, `draw <Type> (#idx), keep <Type>`).
	print_valid_moves = _arg("print_moves", 0) == 1
	assert(count >= 2 and count <= 4, "--players must be 2, 3 or 4")
	var fam: int = Deck.NOBLE_FAMILY_SIZE[count]

	var main = MainScene.instantiate()  # untyped: the harness reads the subclass's extra members
	var card_scene: PackedScene = main.card_scene  # set_script resets exports, restore it below
	main.set_script(load(CountingMain))
	main.card_scene = card_scene
	add_child(main)
	main.noble_family = true
	for i in 4:
		main._players[i].ai_level = LEVELS[i] if i < count else Player.AI_Level.Disabled
	for i in 4:
		main._players[i].move_chosen.connect(count_play.bind(i))
		main._players[i].card_played.connect(count_card_play.bind(i))

	await main.init_players(seed_value)

	var seen_rounds: int = 0
	var elim_seen: int = 0
	var fam_seen: Array[int] = [0, 0, 0, 0]

	for _f in FRAME_BUDGET:
		if main.round_end_actor.size() > seen_rounds:
			var actor_idx: int = main.round_end_actor[seen_rounds]
			seen_rounds += 1
			_rounds += 1
			var elim: int = main.eliminations - elim_seen
			elim_seen = main.eliminations
			var fam_round: Array[int] = [0, 0, 0, 0]
			for j in 4:
				fam_round[j] = main.family_draws[j] - fam_seen[j]
				fam_seen[j] = main.family_draws[j]
			check_round(main, count, fam, plays, fam_round, prince_plays, elim, actor_idx)
			check_draw_pairing(main)
			for i in 4:
				plays[i] = 0
			prince_plays = 0
		if _rounds >= target_rounds:
			break
		await get_tree().process_frame

	_eliminations = elim_seen
	var avg: float = 0.0
	if _rounds > 0:
		avg = float(_plays_total) / _rounds
	print("========== noble family smoke test (players=" + str(count) + ", levels 4/4/3/2) ==========")
	print("rounds: " + str(_rounds) + ", games started: " + str(main.game_counter) +
		", family-out ends (no elimination): " + str(_family_out_ends) +
		", rounds with eliminations: " + str(_elim_rounds))
	print("eliminations: " + str(_eliminations) + ", plays: " + str(_plays_total) +
		", prince plays: " + str(_prince_total) + ", avg plays/round: " + String.num(avg, 2) +
		", max plays in a round: " + str(_max_plays) + " (no-Prince 4p round: " + str(count * fam) + ")")
	print("family size per seat: " + str(fam) + ", scores: " + scores_str(main))
	print("move/draw pairings verified: " + str(main.draws_checked) +
		" - every move naming family card f drew family card f, checked inside its own play chain")

	var ok: bool = true
	if _rounds < target_rounds:
		fail("the games stalled after " + str(_rounds) + " of " + str(target_rounds) + " rounds")
		ok = false
	if _eliminations == 0:
		fail("no elimination in " + str(_rounds) + " rounds - the elimination path is not covered")
		ok = false
	if _family_out_ends == 0:
		fail("no round ran to the family-out end (the seat to act had an empty family)")
		ok = false
	if main.draws_checked == 0:
		fail("no (draw, play) pairing was verified - CountingMain._on_move_chosen never ran")
		ok = false
	if _failures > 0:
		fail(str(_failures) + " per-round rule check(s) failed")
		ok = false
	if ok:
		print("PASS  " + str(_rounds) + " variant rounds (" + str(_family_out_ends) +
			" family-out ends), " + str(_eliminations) + " eliminations, " + str(_plays_total) +
			" plays, no script error")
	get_tree().quit(0 if ok else 1)


func count_play(m: Move, seat: int) -> void:
	plays[seat] += 1
	# `played_type()` works for a Noble Family move that plays the DRAWN family card, whose
	# `Move._played_card` node is null at decision time.
	if m.played_type() == Deck.CardType.Prince:
		prince_plays += 1
		_prince_total += 1


func count_card_play(c: Card, seat: int) -> void:
	plays[seat] += 1
	if c.type == Deck.CardType.Prince:
		prince_plays += 1
		_prince_total += 1


# One finished round. `actor_idx` is the seat that was to act when `round_over()` ran,
# `plays` / `fam_draws` / `prince_plays` are the counts collected since the previous round end.
func check_round(main, count: int, fam: int, plays: Array[int], fam_draws: Array[int],
	princes: int, elim: int, actor_idx: int) -> void:
	var total: int = 0
	for j in count:
		total += plays[j]
		if plays[j] > fam_draws[j]:
			fail("seat " + str(j) + " played " + str(plays[j]) + " times after only " +
				str(fam_draws[j]) + " family draws")
		if fam_draws[j] > fam:
			fail("seat " + str(j) + " drew " + str(fam_draws[j]) +
				" family cards, more than its family size " + str(fam))
		var p = main._players[j]
		if p.family_size() != fam - fam_draws[j]:
			fail("seat " + str(j) + " has " + str(p.family_size()) + " family cards left, expected " +
				str(fam - fam_draws[j]) + " (family size " + str(fam) + " - " + str(fam_draws[j]) +
				" draws)")
	_plays_total += total
	_max_plays = max(_max_plays, total)

	var actor = main._players[actor_idx]
	var family_out: bool = actor.family.is_empty()
	if elim == 0:
		# nothing eliminated the seat to act, so the family-out rule must be why the round ended
		if not family_out:
			fail("round ended with no elimination while the seat to act (player " + str(actor.idx) +
				") still has " + str(actor.family_size()) + " family card(s): the round must end at " +
				"turn start with an empty family")
		if fam_draws[actor_idx] != fam:
			fail("the seat to act drew " + str(fam_draws[actor_idx]) +
				" family cards in a round with no elimination, expected the full family (" + str(fam) +
				") - the family-out rule is what ends such a round")
		var left := 0
		for i in main._deck._left.size():
			left += main._deck._left[i]
		if left != 16 - total - princes:
			fail("sum(_left) == " + str(left) + " at round end, expected 16 - " + str(total) +
				" plays - " + str(princes) + " Prince discards (family draws must not decrement _left)")
		if family_out and fam_draws[actor_idx] == fam and left == 16 - total - princes:
			_family_out_ends += 1
	else:
		_elim_rounds += 1

	for j in count:
		var p = main._players[j]
		var n: int = p.hand.get_child_count()
		if p.is_active() and n != 1:
			fail("seat " + str(j) + " holds " + str(n) + " cards at round end, expected exactly 1")


# The (draw, play, target) gate (step 11/12): `CountingMain._on_move_chosen` pairs every move that
# names a family card with the family card the same play chain draws, from inside the chain. This
# only reports what that pairing found since the last round end.
func check_draw_pairing(main) -> void:
	for msg in main.draw_mismatches:
		fail("move/draw mismatch: " + msg)
	main.draw_mismatches = []


func fail(msg: String) -> void:
	_failures += 1
	print("FAIL  " + msg)


func _arg(name: String, def: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return int(a.split("=", false, 1)[1])
	return def


func scores_str(main) -> String:
	var s := ""
	for p in main._players:
		s += str(p.idx) + ":" + str(p.score) + " "
	return s
