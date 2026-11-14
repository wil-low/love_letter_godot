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
#       godot --headless --path . tests/noble_family_smoke.tscn -- --levels=1234   # one seat per AI level
#       godot --headless --path . tests/noble_family_smoke.tscn -- --seed=777 --log=1 > run.log
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
#   family_draws[seat]` (the family array shrinks by exactly the draws) - EXCEPT for a seat eliminated
#   in this round, who has `family_size == 0`: step 16 revealed his family, moved it to the discard
#   pile through `Main.discard()` and cleared the data the moment he left the round;
# - a round with no elimination is a family-out end: the seat that was to act has an EMPTY family
#   (his family draws == family size), and `sum(Deck._left) == 16 - plays - prince_plays` (plays and
#   the Prince's discarded target card are the only decrements - family draws must not touch `_left`);
# - the round draws from a pile AT MOST once per Prince play: today the only pile draw is the
#   Prince's redraw of its target (`deal_card(target, true)`), which todo step 15 moves to the
#   target's family with the widow as fallback; the turn-start draw is never a pile draw, and the
#   scripted round in rules TEST C (no Prince in the supply) asserts 0 pile draws;
# - when a family-out round had no elimination AND no Prince play (a "clean" round), its length is
#   exact: `plays == seats x family size`, `turns == plays + 1` (the round ends ON the turn that
#   found the empty family) and the seat that ends it is the seat that opened it;
# - every live seat holds exactly 1 card at round end (the invariant the whole design rests on);
# - the step 17 accounting gate, from the snapshots `CountingMain` takes INSIDE `round_over()`:
#   per type `_left[t] == (supply as dealt for this round) - (cards of type t discarded in it)`,
#   `sum(_left) == dealt - discards`, and the discards split by the container they left from
#   (played cards / hand cards / revealed families) must match the round's own counters.
#
# And continuously, not only at round ends: `CountingMain.audit_left()` runs both accounting
# identities at EVERY turn start, at every pre-decision state, at every decision (the moment the
# seat commits its (draw, play, target) triple) and at both sides of every effect, and reports the
# audit / skip / violation counts. A snapshot taken inside a `discard()` animation is skipped on
# purpose - `_left` is decremented card by card at the START of each card's animation while the
# card node is still a child of its container - and every skip is counted, so the suite can tell
# "audited and clean" from "never looked".
# Suite-level: the requested round count is reached, at least 1 elimination happens, at least
# 1 round runs all the way to the family-out end.
#
# Step 12 (the AI draw policies) adds two more rails:
# - EVERY joint move is checked the moment the seat commits it (`count_play` is on `move_chosen`,
#   which fires BEFORE the chain animates the draw, so the family data and the 1-card hand the
#   harness reads are exactly the state the move was chosen from): the named family index exists
#   and names that family card, the played card is one of the pair (active, family[f]) and the
#   leftover is the other one, the Countess rule is obeyed, `_played_card` is the hand node for an
#   active-card play and null for a drawn-card play, and the target follows the type rules.
#   A move that passes is counted, per AI LEVEL - so "levels 1-4 all play legal joint moves" is a
#   measurement (`--levels=1234` puts one seat of every level on the board), not an eyeball.
# - `--log=1` prints one line per play (`LOG  r<round> s<seat> lvl<level> <Move>`). The game seeds
#   its RNG per game (`Main._new_game()` -> `seed(_random_seed)`), so a fixed seed is a REPRODUCIBLE
#   run: the same seed twice gives a byte-identical log (that is level 1 determinism -
#   `valid_moves[0]` over the as-dealt family order), and a different seed gives a different one.
#   Levels 1 and 2 look at no hand at all, so their logs are the policy's whole behaviour: a level 1
#   log shows only `draw <family[0] type> (#0)` plays of the active card, a level 2 log spreads over
#   several draw indices. The log prints no timing, no board dumps - only what a run decided.

const MainScene := preload("res://main/main.tscn")
const CountingMain := "res://tests/counting_main.gd"  # load()ed at runtime: preload() would make
# a cyclic dependency (this harness preloads main.tscn, counting_main.gd extends Main)

var print_memory: bool = false
var print_valid_moves: bool = false  # set by --print-moves=1

const SEED: int = 20260607
const PLAYERS: int = 4
const ROUNDS: int = 40
const FRAME_BUDGET: int = 200000
# The seat levels, one digit per seat (`--levels=1234`): 1..5 = AI level 1..5. The default is the
# step 7 mix (4/4/3/2); step 12's gate ("levels 1-4 all play legal joint moves") is the run that
# puts every level on the board, so every level is measured in a real variant game.
const LEVELS_SPEC: String = "4432"

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
var _unsettled_rounds: int = 0  # round ends that caught a discard/reveal animation in flight
var _boundary_devs: int = 0  # piece-count deviations of exactly 1 (the abandoned play chain)
var _left_violations: int = 0  # step 17: continuous audit violations reported by CountingMain
# Step 12: the joint-move legality rail + the reproducible play log
var main_ref = null  # the CountingMain instance, for the per-move checks
var cur_round: int = 1  # the round a play belongs to (1-based, finished rounds + 1)
var log_moves: bool = false
var levels_spec: String = LEVELS_SPEC
var legal_checked: int = 0
var plays_by_level: Array[int] = [0, 0, 0, 0, 0, 0]  # index = Player.AI_Level value
var legal_violations: Array[String] = []
const KIND_NAMES: Array[String] = ["played card (table)", "hand card", "revealed family", "other container"]


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	var count: int = _arg("players", PLAYERS)
	var target_rounds: int = _arg("rounds", ROUNDS)
	var seed_value: int = _arg("seed", SEED)
	levels_spec = _arg_str("levels", LEVELS_SPEC)
	assert(levels_spec.length() >= 2 and levels_spec.length() <= 4,
		"--levels takes one digit per seat, 2 to 4 digits")
	var levels: Array[Player.AI_Level] = _levels_from_spec(levels_spec)
	log_moves = _arg("log", 0) == 1
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
	main_ref = main
	for i in 4:
		main._players[i].ai_level = levels[i] if i < count else Player.AI_Level.Disabled
	for i in 4:
		main._players[i].move_chosen.connect(count_play.bind(i))
		main._players[i].card_played.connect(count_card_play.bind(i))

	await main.init_players(seed_value)

	var seen_rounds: int = 0
	var elim_seen: int = 0
	var fam_seen: Array[int] = [0, 0, 0, 0]
	var turns_seen: Array[int] = [0, 0, 0, 0]
	var pile_seen: int = 0
	var first_hand_seen: int = 0

	for _f in FRAME_BUDGET:
		if main.round_end_actor.size() > seen_rounds:
			var r_idx: int = seen_rounds
			var actor_idx: int = main.round_end_actor[seen_rounds]
			var start_actor: int = main.round_start_actor[seen_rounds]
			seen_rounds += 1
			cur_round = seen_rounds + 1  # the plays the harness sees next belong to the NEXT round
			_rounds += 1
			var elim: int = main.eliminations - elim_seen
			var eliminated_this: Array = []  # the seats this round eliminated, by index
			for k in elim:
				eliminated_this.append(main.eliminated_seats[elim_seen + k])
			elim_seen = main.eliminations
			var fam_round: Array[int] = [0, 0, 0, 0]
			var turns_round: int = 0
			var turn_snapshot: Array = main.round_end_turns[r_idx]
			for j in 4:
				fam_round[j] = main.family_draws[j] - fam_seen[j]
				fam_seen[j] = main.family_draws[j]
				turns_round += int(turn_snapshot[j]) - turns_seen[j]
				turns_seen[j] = int(turn_snapshot[j])
			var pile_round: int = main.pile_draws - pile_seen
			var first_hand_round: int = main.first_hand_deals - first_hand_seen
			pile_seen = main.pile_draws
			first_hand_seen = main.first_hand_deals
			var rec: Dictionary = main.round_end_records[r_idx]
			check_round(main, count, fam, plays, fam_round, prince_plays, elim, actor_idx,
				turns_round, start_actor, pile_round, first_hand_round, eliminated_this, rec)
			check_draw_pairing(main)
			collect_left_violations(main)
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
	print("========== noble family smoke test (players=" + str(count) + ", levels "
		+ levels_spec + ") ==========")
	print("rounds: " + str(_rounds) + ", games started: " + str(main.game_counter) +
		", family-out ends (no elimination): " + str(_family_out_ends) +
		", rounds with eliminations: " + str(_elim_rounds))
	print("eliminations: " + str(_eliminations) + ", plays: " + str(_plays_total) +
		", prince plays: " + str(_prince_total) + ", avg plays/round: " + String.num(avg, 2) +
		", max plays in a round: " + str(_max_plays) + " (no-Prince 4p round: " + str(count * fam) + ")")
	print("family size per seat: " + str(fam) + ", scores: " + scores_str(main))
	print("seat levels: " + levels_spec + " (1..4 = AI levels, 5 = random mix), joint moves verified"
		+ " legal: " + str(legal_checked) + " by level: " + plays_by_level_str(levels_spec))
	print("move/draw pairings verified: " + str(main.draws_checked) +
		" - every move naming family card f drew family card f, checked inside its own play chain")
	var kinds: Array = main.discards_by_kind
	print("_left audit (step 17): " + str(main.left_audits) + " audits ran at every turn start, every"
		+ " pre-decision state, every decision and every effect boundary, " + str(main.left_skips)
		+ " skipped because a discard/reveal animation was in flight, " + str(main.left_violations.size())
		+ " violation(s)")
	print("cards that left play, by container: played " + str(int(kinds[0])) + ", hand "
		+ str(int(kinds[1])) + ", revealed families " + str(int(kinds[2])) + ", other "
		+ str(int(kinds[3])) + " (" + str(_unsettled_rounds) + " round end(s) caught an animation in"
		+ " flight, " + str(_boundary_devs) + " boundary-chain deviation(s) of 1)")

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
	if main.left_audits == 0:
		fail("no _left audit ran - the accounting is not verified continuously (step 17)")
		ok = false
	if main.left_audits <= main.left_skips:
		fail(str(main.left_skips) + " audits skipped vs " + str(main.left_audits)
			+ " run - the audit is being skipped more than it runs, so it proves nothing")
		ok = false
	if _left_violations > 0:
		fail(str(_left_violations) + " continuous _left accounting violation(s) (see the lines above)")
		ok = false
	if _failures > 0:
		fail(str(_failures) + " per-round rule check(s) failed")
		ok = false
	# step 12: the joint-move legality rail (every committed move checked in the state it was chosen
	# from) and the per-level coverage the gate asks for ("levels 1-4 all play legal joint moves")
	for msg in legal_violations:
		fail("illegal joint move: " + msg)
		ok = false
	if legal_checked == 0:
		fail("no joint move was checked - the legality rail never ran")
		ok = false
	for i in levels_spec.length():
		var lvl: int = int(levels_spec[i])
		if plays_by_level[lvl] == 0:
			fail("no play was made with AI level " + str(lvl) + " - the level is on the board and never"
				+ " chose a move, so its policy is not covered by this run")
			ok = false
	if ok:
		print("PASS  " + str(_rounds) + " variant rounds (" + str(_family_out_ends) +
			" family-out ends), " + str(_eliminations) + " eliminations, " + str(_plays_total) +
			" plays, no script error")
	get_tree().quit(0 if ok else 1)


func count_play(m: Move, seat: int) -> void:
	plays[seat] += 1
	# `move_chosen` only fires for AI seats, so the level is 1..5; the guard keeps a Disabled/human
	# seat from indexing `plays_by_level` out of range if this rail is ever wired to a human game.
	var lvl: int = int(main_ref._players[seat].ai_level)
	if lvl >= 0:
		plays_by_level[lvl] += 1
	# `played_type()` works for a Noble Family move that plays the DRAWN family card, whose
	# `Move._played_card` node is null at decision time.
	if m.played_type() == Deck.CardType.Prince:
		prince_plays += 1
		_prince_total += 1
	check_joint_move(m, seat)
	if log_moves:
		print("LOG  r" + str(cur_round) + " s" + str(seat) + " lvl"
			+ str(int(main_ref._players[seat].ai_level)) + " " + str(m))


# The step 12 gate, one joint move at a time: every (draw, play, target) triple a seat COMMITS is
# legal in the state the seat chose it from. `move_chosen` fires before `_on_move_chosen()` animates
# the draw, so `p.family` is the family the enumeration saw and the hand is the 1 active card.
# The AI levels only ever pick an element of `Main.find_valid_moves()`'s list, so this is the rail
# that proves the list itself - and the policy that filters it - produce legal plays, for every level.
func check_joint_move(m: Move, seat: int) -> void:
	var p = main_ref._players[seat]
	var v: Array[String] = []
	if not m.is_noble():
		v.append("an AI move of the variant names no family draw (_drawn_family_idx == -1)")
	var fam_idx: int = m._drawn_family_idx
	var drawn_t: Deck.CardType = m._drawn_type
	if fam_idx >= 0 and fam_idx < p.family_size() and p.family[fam_idx] != drawn_t:
		v.append("names family[" + str(fam_idx) + "] as " + Deck.card_names[int(drawn_t)]
			+ " but that slot is " + Deck.card_names[int(p.family[fam_idx])])
	if p.hand.get_child_count() != 1:
		v.append("decides with " + str(p.hand.get_child_count())
			+ " cards in hand, the variant seat holds exactly the 1 active card")
	var active_t: Deck.CardType = Deck.CardType.Unknown
	if p.hand.get_child_count() > 0:
		active_t = p.hand.get_child(0).type
	var idx: int = m._played_card_idx
	if idx != 0 and idx != 1:
		v.append("_played_card_idx == " + str(idx) + ", 0 = the active card / 1 = the drawn one")
	var played_t: Deck.CardType = m.played_type()
	var pair: Array = [active_t, drawn_t]
	if not pair.has(played_t):
		v.append("plays " + Deck.card_names[int(played_t)] + ", which is neither the active card ("
			+ Deck.card_names[int(active_t)] + ") nor the drawn one ("
			+ Deck.card_names[int(drawn_t)] + ")")
	if idx == 0 or idx == 1:
		var want_keep: Deck.CardType = pair[1 - idx]
		if m._leftover_type != want_keep:
			v.append("keeps " + Deck.card_names[int(m._leftover_type)] + ", the pair (" + str(pair)
				+ ") leaves " + Deck.card_names[int(want_keep)])
	var forced: int = p.countess_restricted_types(active_t, drawn_t)
	if forced != -1 and forced != idx:
		v.append("plays the man of a Countess + man pair (Countess is forced, played idx " + str(idx)
			+ ", forced idx " + str(forced) + ")")
	if m._played_card != null and idx == 1:
		v.append("carries a hand node for a play of the DRAWN card, which has no node yet")
	if m._played_card != null and m._played_card.get_parent() != p.hand:
		v.append("_played_card is not a card of this seat's hand")
	# The target rule the rail enforces is production's own, stated from the rules and NOT from
	# `Main._other_protected` (a rail that reads the enumerator's flag agrees with a buggy enumerator):
	# a seat may name a PROTECTED opponent only when every other active seat is protected - the classic
	# "everyone hid behind a Handmaid" case. With an unprotected opponent available, the protected one
	# is not targetable.
	var tgt: int = m._target_player
	var all_others_protected: bool = true
	for pl in main_ref._players:
		if pl.is_active() and !pl.protected and pl.idx != seat:
			all_others_protected = false
	match played_t:
		Deck.CardType.Guard:
			if tgt == seat or tgt < 0 or tgt >= 4:
				v.append("a Guard probes seat " + str(tgt) + ", which is not an opponent")
			elif tgt < main_ref._players.size() and main_ref._players[tgt].protected \
					and not all_others_protected:
				v.append("a Guard probes protected seat " + str(tgt) + " while an unprotected opponent"
					+ " is available")
			elif m._target_type < Deck.CardType.Priest or m._target_type > Deck.CardType.Princess:
				v.append("a Guard names " + Deck.card_names[int(m._target_type)]
					+ ", the guessable types are Priest..Princess")
		Deck.CardType.Priest, Deck.CardType.Baron, Deck.CardType.King:
			if tgt == seat or tgt < 0 or tgt >= 4:
				v.append(Deck.card_names[int(played_t)] + " targets seat " + str(tgt)
					+ ", which is not an opponent")
			elif tgt < main_ref._players.size() and main_ref._players[tgt].protected \
					and not all_others_protected:
				v.append(Deck.card_names[int(played_t)] + " targets protected seat " + str(tgt)
					+ " while an unprotected opponent is available")
		Deck.CardType.Prince:
			if tgt < 0 or tgt >= 4:
				v.append("a Prince targets seat " + str(tgt) + ", any active seat including self")
			elif main_ref._players[tgt].protected:
				v.append("a Prince targets protected seat " + str(tgt))
		Deck.CardType.Handmaid, Deck.CardType.Countess, Deck.CardType.Princess:
			if tgt != -1:
				v.append(Deck.card_names[int(played_t)] + " targets seat " + str(tgt)
					+ ", this card is played on self")
	if tgt >= 0 and tgt < main_ref._players.size() and not main_ref._players[tgt].is_active():
		v.append("targets seat " + str(tgt) + ", who is out of the round")
	if v.is_empty():
		legal_checked += 1
		return
	for msg in v:
		# one line per violation, the move included: the log is the evidence, the count is the gate
		legal_violations.append("r" + str(cur_round) + " s" + str(seat) + " lvl"
			+ str(int(main_ref._players[seat].ai_level)) + " " + str(m) + ": " + msg)


func count_card_play(c: Card, seat: int) -> void:
	plays[seat] += 1
	if c.type == Deck.CardType.Prince:
		prince_plays += 1
		_prince_total += 1


# One finished round. `actor_idx` is the seat that was to act when `round_over()` ran,
# `plays` / `fam_draws` / `prince_plays` are the counts collected since the previous round end.
# `turns` is the number of `new_turn()` calls the round took, `start_actor` the seat that opened it.
func check_round(main, count: int, fam: int, plays: Array[int], fam_draws: Array[int],
	princes: int, elim: int, actor_idx: int, turns: int, start_actor: int,
	pile_drawn: int, first_hand: int, eliminated_this: Array, rec: Dictionary) -> void:
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
		# Step 16: an out seat's family leaves play WITH him - it is materialized for the reveal, discarded
		# through `Main.discard()` (the one `_left` decrement) and its DATA is cleared on the spot, so a seat
		# eliminated this round has NO family left and drew no family card after the elimination. A live seat
		# is unchanged: family size minus the family cards he drew.
		var want_fam: int = 0 if eliminated_this.has(j) else fam - fam_draws[j]
		if p.family_size() != want_fam:
			fail("seat " + str(j) + " has " + str(p.family_size()) + " family cards left, expected " +
				str(want_fam) + " (" + ("eliminated this round: his family left play with him (step 16)" if
					eliminated_this.has(j) else
					"family size " + str(fam) + " - " + str(fam_draws[j]) + " draws)"))
	if pile_drawn > princes:
		fail(str(pile_drawn) + " draw(s) from a pile in a round with " + str(princes) + " Prince play(s): " +
			"today the ONLY draw from the main pile / the widow is the Prince's redraw of its target " +
			"(`Main.play_card`'s Prince branch, `deal_card(target, true)`), so pile draws are bounded by " +
			"the number of Prince plays. Todo step 15 moves that redraw to the target's FAMILY (widow as " +
			"fallback), and then a round must touch no pile at all. The turn-start draw is never a pile " +
			"draw in any case (rules TEST C asserts 0 with a Prince-free supply)")
	if first_hand != count:
		fail(str(first_hand) + " first-hand cards dealt in a round, expected 1 per seat (" + str(count) +
			") - every round is re-dealt, the families are re-dealt and never carried over")
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
		if turns != total + 1 and princes == 0:
			fail("the round took " + str(turns) + " turns for " + str(total) + " plays, expected " +
				str(total + 1) + ": every play is a turn and the family-out round ends ON THE TURN " +
				"THAT FOUND the empty family, so exactly one turn more than there were plays. The " +
				"count is only exact when no Prince was played: a Prince play belongs to a chain that " +
				"resumes after the round end, and such a play is not a turn of this round")
		if actor_idx != start_actor and princes == 0:
			fail("the round ended on seat " + str(actor_idx) + " but was opened by seat " +
				str(start_actor) + ": with " + str(count) + " seats and " + str(fam) +
				" family cards each and no Prince redraw, the " + str(count * fam + 1) + "th turn belongs " +
				"to the seat that took the 1st turn, and that is the seat the family-out rule stops")
		var accounting: bool = check_left_accounting(rec, total, princes, elim, fam, fam_draws,
			eliminated_this)
		if family_out and fam_draws[actor_idx] == fam and accounting:
			_family_out_ends += 1
	else:
		_elim_rounds += 1

	for j in count:
		var p = main._players[j]
		var n: int = p.hand.get_child_count()
		if p.is_active() and n != 1:
			fail("seat " + str(j) + " holds " + str(n) + " cards at round end, expected exactly 1")


# The step 17 gate: the card accounting of ONE finished round, from the snapshots CountingMain
# takes INSIDE `round_over()` (`_new_round()` re-deals and overwrites `_deck._left` a frame or two
# after the round ended, so the live array is not the round's accounting any more when the harness
# sees the round end). Three checks:
#
#   per type  `_left[t] == (supply as dealt for this round) - (cards of type t discarded in it)`
#             for all 8 types. `Deck.pop()` decrements nothing; `Main.discard()` is the ONLY
#             decrement in the game, and `Deck._build_deck()` resets `_left` every round - so the
#             supply shrinks exactly as fast as cards leave play, never faster, never slower. Per
#             type is the point: a double decrement of Guard plus a missed decrement of Priest
#             cancels out in a sum check and is invisible there. It also asserts the deck was reset
#             cleanly at the round start (used == 0 => `_left == the dealt supply`).
#   sum       `sum(_left) == dealt - discards`. The todo's `16 - plays` is NOT the invariant: every
#             Prince hit discards the target's hand card on top of the plays, and every elimination
#             discards the revealed hand + the revealed family (step 16).
#   pieces    the discards classified by the container they were discarded FROM: played cards (the
#             table) + hand cards (Prince victims and revealed out seats) + revealed family cards.
#             `sum == 16 - played - prince - revealed-family` is what the whole design rests on.
#
# The piece counts may deviate by ONE play: the play chain a round end abandons fires its
# `move_chosen` (so its play is counted in THIS round) and finishes its discards after the next
# round's baseline is taken (so they land in the NEXT round's window). Such a deviation is an INFO
# line, counted and reported; 2 or more in one round is a failure. The exact identities are
# unaffected: they bracket the round with the discard counter itself, not with play counts.
func check_left_accounting(rec: Dictionary, total: int, princes: int, elim: int, fam: int,
		fam_round: Array[int], eliminated_this: Array) -> bool:
	var tag: String = "round " + str(_rounds) + " accounting"
	if not bool(rec["settled"]) or not bool(rec["audited"]):
		# `settled`: a discard()/reveal animation was in flight at the round end - `_left` is decremented
		# card by card at the START of each card's animation while the card node is still in its
		# container, so the round-end snapshot is transient. `audited`: the suite runs a scripted
		# FakeDeck whose `_left` is a hand-written shape, not a counted supply (CountingMain.audit_applies).
		# Either way the round is counted and the continuous audit covered what it can.
		_unsettled_rounds += 1
		return true
	var base_left: Array = rec["base_left"]
	var base_disc: Array = rec["base_discarded"]
	var end_disc: Array = rec["discarded"]
	var base_kinds: Array = rec["base_kinds"]
	var end_kinds: Array = rec["kinds"]
	var left: Array = rec["left"]
	var ok: bool = true
	var used_sum: int = 0
	for t in left.size():
		var used: int = int(end_disc[t]) - int(base_disc[t])
		used_sum += used
		var want: int = int(base_left[t]) - used
		if int(left[t]) != want:
			ok = false
			fail(tag + ": " + Deck.card_names[t] + " ends the round at _left == " + str(int(left[t]))
				+ ", expected " + str(want) + " (dealt " + str(int(base_left[t])) + " minus " + str(used)
				+ " discarded - `Deck.pop()` decrements NOTHING, `discard()` is the only decrement in the"
				+ " game, so the supply shrinks exactly as fast as cards leave play). Cards of one type"
				+ " counted twice and cards of another type counted none cancel in a sum, so the check"
				+ " is per type")
	var dealt: int = 0
	var left_sum: int = 0
	for t in left.size():
		dealt += int(base_left[t])
		left_sum += int(left[t])
	if left_sum != dealt - used_sum:
		ok = false
		fail(tag + ": sum(_left) == " + str(left_sum) + " at the round end, expected " + str(dealt)
			+ " dealt - " + str(used_sum) + " discarded (every play discards 1 card, every Prince hit"
			+ " discards the target's hand card, every elimination discards the revealed hand and the"
			+ " revealed family - the todo's `16 - plays` counts only the first of these; and a family"
			+ " draw decrements nothing, which is what makes the supply shrink exactly as fast as cards"
			+ " leave play)")
	var pieces: Array[int] = []
	for k in end_kinds.size():
		pieces.append(int(end_kinds[k]) - int(base_kinds[k]))
	if pieces[0] + pieces[1] + pieces[2] + pieces[3] != used_sum:
		ok = false
		fail(tag + ": " + str(used_sum) + " cards left play by the discard counter, the container "
			+ "classification adds up to " + str(pieces))
	var fam_expected: int = 0
	for seat in eliminated_this:
		# an out seat takes his WHOLE remaining family with him (step 16): family size - what he drew.
		# This is the UPPER bound: a seat eliminated mid-chain by a King/Princess/Countess that the
		# round end interrupted is revealed and discarded after the round ended (the next round's
		# window), so such a reveal is not in this round's count. `Main.eliminate()`'s reveal is
		# awaited, so the direct eliminations ARE in it.
		fam_expected += fam - int(fam_round[int(seat)])
	var want: Array[int] = [total, princes + elim, fam_expected, 0]
	for k in 4:
		var dev: int = pieces[k] - want[k]
		if dev == 0:
			continue
		if k == 2 and dev < 0:
			_boundary_devs += 1  # fewer reveals than the bound: chains the round end interrupted
			print("INFO  " + tag + ": " + str(pieces[k]) + " revealed-family discard(s), at most "
				+ str(want[k]) + " predicted - a seat eliminated mid-chain by a King/Princess/Countess"
				+ " the round end interrupted is revealed and discarded in the next round's window")
			continue
		if abs(dev) > 1:
			ok = false
			fail(tag + ": " + str(pieces[k]) + " " + KIND_NAMES[k] + " discard(s), the round's own"
				+ " counters predict " + str(want[k]) + " (" + str(total) + " plays, " + str(princes)
				+ " Prince target cards + " + str(elim) + " revealed hands, at most " + str(fam_expected)
				+ " revealed family cards of the seats that went out, 0 unknown containers)")
		else:
			_boundary_devs += 1
			print("INFO  " + tag + ": " + str(pieces[k]) + " " + KIND_NAMES[k] + " discard(s) vs the"
				+ " predicted " + str(want[k]) + " - the play chain a round end abandons fires"
				+ " move_chosen in this round and discards in the next round's window")
	return ok


# The continuous audit's findings (step 17): CountingMain runs the two identities at every turn
# start, at every pre-decision state, at every decision and at both sides of every effect. Read
# them per round, so a violation is attributed to the round that produced it.
func collect_left_violations(main) -> void:
	for msg in main.left_violations:
		_left_violations += 1
		fail("_left audit: " + str(msg))
	main.clear_left_violations()


# The (draw, play, target) gate (step 11/12): `CountingMain._on_move_chosen` pairs every move that
# names a family card with the family card the same play chain draws, from inside the chain. This
# only reports what that pairing found since the last round end.
func check_draw_pairing(main) -> void:
	for msg in main.draw_mismatches:
		fail("move/draw mismatch: " + msg)
	main.clear_draw_mismatches()


func fail(msg: String) -> void:
	_failures += 1
	print("FAIL  " + msg)


func _arg(name: String, def: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return int(a.split("=", false, 1)[1])
	return def


func _arg_str(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return a.split("=", false, 1)[1]
	return def


# `--levels=1234`: digit i is seat i's AI level (1..5, see Player.AI_Level - 5 = the random mix).
func _levels_from_spec(spec: String) -> Array[Player.AI_Level]:
	var out: Array[Player.AI_Level] = []
	for i in spec.length():
		var d: int = int(spec[i])
		assert(d >= 1 and d <= 5, "--levels digits are 1..5 (AI levels)")
		out.append(Player.AI_Level.Level_1 + (d - 1))
	return out


func scores_str(main) -> String:
	var s := ""
	for p in main._players:
		s += str(p.idx) + ":" + str(p.score) + " "
	return s


# How many joint moves each AI level in the spec made, as `L1=12 L2=7 ...`.
func plays_by_level_str(spec: String) -> String:
	var s := ""
	var seen: Array[int] = []
	for i in spec.length():
		var lvl: int = int(spec[i])
		if seen.has(lvl):
			continue
		seen.append(lvl)
		s += "L" + str(lvl) + "=" + str(plays_by_level[lvl]) + " "
	return s
