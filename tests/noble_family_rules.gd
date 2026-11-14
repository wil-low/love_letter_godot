extends Node2D
# Noble Family rules suite (docs/noble-family-todo.md §A.4).
#
# TEST A pins the deal table produced by Deck.prepare_noble():
#   burn/widow 3 / 1 / 0 for 2 / 3 / 4 players (4p has NO widow pile),
#   1 first-hand card per seat (not part of the family),
#   family 5 / 4 / 3 per seat, main pile leftovers 1 / 0 / 0,
#   conservation burn + first_hand + families + main_left == 16,
#   `_left` untouched at full counts (family / first-hand / widow cards are out of
#   the main pile only, not out of play),
#   the four piles together are an exact permutation of the 16-card deck - no card
#   duplicated, no card lost, no `Unknown` type in play.
#
# TEST B pins the joint (draw, play, target) enumeration of Main.find_valid_moves() in the
# variant: one state per scripted (active card, family, protection) setup, every emitted move
# checked against the pair it plays and against the target rules, with the total move counts
# written down by hand (68 / 4 / 17 / 2) instead of recomputed from the production code, plus the
# level 1-4 draw policies over an enumerated list.
#
# TEST C (todo step 14) runs a real 4-player variant GAME on a scripted deal with every seat on
# level 1 (deterministic: `valid_moves[0]` = draw family index 0, play the active card), with the
# `tests/fake_deck.gd` scripted-deal technique. The scripted 16 cards are Guard / Handmaid /
# Countess only, so NO play can ever eliminate anybody (a Guard probe declares Priest and no seat
# ever holds a Priest): the round can only end by the family-out rule, which is what the step 14
# gate asks for.
#
# TEST D (todo step 15) runs whole scripted games whose ONLY round end is the Prince chain: the
# target redraws from his OWN family; with an empty family he falls back to the widow; with an
# empty family AND no widow card he is eliminated (the only possibility in 4p, which burns nothing).
#
# Later steps append to this file: step 16 (elimination reveal + discard accounting),
# step 31 (joint move legality, L1 determinism). Those cases use the `tests/fake_deck.gd`
# scripted-deal technique;
# TEST F (todo step 18) pins the family STACK: a private, display-only cascade of Card nodes in the
# seat's own `$Family` node - 1 node per family card, in as-dealt order, 9 px cascade, mirrored on
# the right-handed seats, inside the 84 x 48 viewport, zero input connections, rendered ONLY for the
# human seat (an AI family is data, never pixels), shrunk by every draw and refilled by every re-deal.
#
# TEST L (todo step 24) pins the MODE PICKER `game_mode/game_mode.tscn`: 3 rows (CLASSIC / NOBLE
# FAMILY / BACK) in the `start.tscn` shape - a Label row + ONE flat, full-area Button - closed at
# `_ready()`, opened by `show_rows()`, one signal per press, the panel hidden BEFORE the choice is
# emitted, zero rows visible in the tree while closed (the engine's own input gate = the "nothing
# tappable" proof), and NO script variables at all, because the mode is chosen per game and never
# persisted. Geometry is measured as global rects inside 84 x 48, non-overlapping, ordered, with the
# text width vs the row width at the game's 7 px font.
#
# TEST I (todo step 21) pins the Prince REDRAW of a HUMAN seat: a family card is NEVER picked for a
# human seat, mid-effect or at a turn start. A human target's redraw runs the SAME modal path a turn
# start runs (`Main.human_draw_from_family()`), in both shapes the Prince branch reaches - a self-Prince
# and an AI's Prince aimed at him (an AI TURN that opens the HUMAN's panel). The fallbacks stay pile /
# elimination paths that open NO panel: a 3p hit with an empty family draws THE WIDOW, a 4p hit with an
# empty family and no widow eliminates him, and an eliminated seat with an empty family reveals NOTHING.
#
# TEST M (todo step 25) pins the MODE-MENU WIRING in `application.{gd,tscn}` on the REAL application
# scene: PLAY opens the picker and starts NOTHING, a row press sets `Main.noble_family` BEFORE
# `start_game()` -> `init_players()` runs (the deal table is chosen by that flag, read once), BACK
# starts no game and sets no mode, Exit-to-menu CLEARS the mode and a following CLASSIC press deals a
# classic round with NO families and NO family draws, and `speed_run` bypasses the menu, classic-only.
#
# TEST N (todo step 26) pins the STATS data model: ONE 14-counter table PER MODE (0 = classic,
# 1 = noble family), `mode` selecting which table the page shows and which one the game writes.
# The pre-variant name `_totals_and_wins` survives as a getter/setter ALIAS of the current table, so
# `application.gd` is untouched; the setter normalizes a save loaded from `options.cfg` (a plain
# Array) to `Array[int]` and PRESERVES its length, because the application drops a stale save by its
# size. Reset clears ONLY the visible table; a classic game writes ONLY the classic table; and the
# APP is the only file that names a mode (`start_game()` and the two stats-page openers), so a variant
# game's counters can only land in the noble table.
#
# TEST A deliberately needs no Main scene at all, so the deal table is pinned
# independently of the game loop.
#
# Run:  godot --headless --path . tests/noble_family_rules.tscn
#       echo $?      # 0 = every check passed, 1 = a check failed

const DeckScene := preload("res://deck/deck.tscn")
const MainScene := preload("res://main/main.tscn")
const PlayerScene := preload("res://player/player.tscn")
const FakeDeckScript := preload("res://tests/fake_deck.gd")
const FamilySelectorScene := preload("res://family_selector/family_selector.tscn")
const GameModeScene := preload("res://game_mode/game_mode.tscn")
const CountingMainScript := "res://tests/counting_main.gd"  # load()ed at runtime: preload() of a
# script that extends Main is a cyclic dependency (this harness preloads main.tscn)

const TRIALS: int = 200
const SEED: int = 20260607
const TOTAL_CARDS: int = 16

# TEST C: the scripted 4-player supply, in DEAL ORDER (Deck.prepare_noble() pops it as
# burn 0 -> first-hand seat 0..3 -> family column 0 seat 0..3 -> column 1 -> column 2).
# Slot i of a seat's family is played on his i-th turn and his last card is never played, so the
# played multiset is 5 Guard + 3 Handmaid + 4 Countess = 12 = 4 seats x family size 3.
const NOBLE_SCRIPTED: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Handmaid, Deck.CardType.Handmaid,
	Deck.CardType.Handmaid, Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Countess,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Countess,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Countess,
]
const NOBLE_SCRIPTED_LEFT: Array[int] = [8, 0, 0, 3, 0, 0, 5, 0]  # == the scripted multiset
const NOBLE_ROUND_END_LEFT: Array[int] = [3, 0, 0, 0, 0, 0, 1, 0]  # 16 - 12 plays

# TEST D, 4p fixture (no burn -> NO widow pile, 4 first-hand cards, family 3/seat, main pile 0).
# Handmaids protect seats 0 and 1 exactly when seat 3 plays his Princes, so the Prince hits land
# on seat 2, whose family runs out under 2 own draws + 2 hits. The multiset is hand-picked (4
# Handmaids > the real deck's 1) - `tests/fake_deck.gd` rebuilds `_left` from it.
const NOBLE_4P_PRINCE: Array[Deck.CardType] = [
	Deck.CardType.Handmaid, Deck.CardType.Handmaid, Deck.CardType.Guard, Deck.CardType.Prince,
	Deck.CardType.Handmaid, Deck.CardType.Handmaid, Deck.CardType.Guard, Deck.CardType.Prince,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_4P_PRINCE_LEFT: Array[int] = [10, 0, 0, 4, 2, 0, 0, 0]  # 10 Guard, 4 Handmaid, 2 Prince
const NOBLE_4P_PRINCE_END_LEFT: Array[int] = [3, 0, 0, 0, 0, 0, 0, 0]  # 16 - 11 plays - 2 hits

# TEST D, 3p fixture (burn 1 -> widow = 1 Guard, 3 first-hand cards, family 4/seat, main pile 0).
# Seats 1 and 2 hold Princes in a row (first-hand + family[0]), so they Prince seat 0 on four
# consecutive turns: twice into his family, once into the widow, once into nothing.
const NOBLE_3P_PRINCE: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Prince,
	Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Prince, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_3P_PRINCE_LEFT: Array[int] = [12, 0, 0, 0, 4, 0, 0, 0]  # 12 Guard, 4 Prince
const NOBLE_3P_PRINCE_END_LEFT: Array[int] = [2, 0, 0, 0, 0, 0, 0, 0]  # 16 - 10 plays - 4 hits

# TEST D, 3p fixture 2 - a hit that finds the target's LAST family card. Seat 1 is the victim (the
# only seat whose family a Prince can reach at size 1: seat 2 plays Princes on turns 3 and 6, seat 1
# draws on his own turns 2 and 5), seats 0 / 1 play Handmaids so seat 2's Princes skip seat 0 and
# hit seat 1. Seat 0's Handmaids protect him on turns 2, 3, 5 and 6. No family is ever empty at a
# hit, so the 1-card widow is never touched and nobody dies: the round ends on the family-out rule.
const NOBLE_3P_PRINCE_LAST: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Handmaid, Deck.CardType.Guard, Deck.CardType.Prince,
	Deck.CardType.Handmaid, Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_3P_PRINCE_LAST_LEFT: Array[int] = [12, 0, 0, 2, 2, 0, 0, 0]  # 12 Guard, 2 Handmaid, 2 Prince
const NOBLE_3P_PRINCE_LAST_END_LEFT: Array[int] = [7, 0, 0, 0, 0, 0, 0, 0]  # 16 - 7 plays - 2 hits

# TEST D, 2p fixture - the fallback pile order with a main-pile leftover in front of the widow.
# 2p burns 3 (widow = 3 cards) and leaves 1 card in the MAIN pile, and `Deck.pop(true)` pops the
# main pile before the widow. Seat 1 holds three Princes in a row (first-hand + family[0] +
# family[1]) and hits seat 0 on turns 2, 4 and 6; seat 0 only plays Guards, so he is never
# protected and is always the target. Seat 0's family (5) is drained by 3 own draws + 2 hits, so
# the 6th turn's hit is the one and only empty-family hit this round can produce - and it takes the
# MAIN pile card, not a widow card.
const NOBLE_2P_PRINCE: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Prince, Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Guard,
	Deck.CardType.Prince, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_2P_PRINCE_LEFT: Array[int] = [13, 0, 0, 0, 3, 0, 0, 0]  # 13 Guard, 3 Prince
const NOBLE_2P_PRINCE_END_LEFT: Array[int] = [7, 0, 0, 0, 0, 0, 0, 0]  # 16 - 6 plays - 3 hits

# TEST E, 4p fixture 1 (todo step 16) - a Guard KILLS a seat that never played, so his WHOLE family
# is revealed with his hand card. Deal order: 4 first-hand cards, then the 3 family columns.
#   seat 0 Guard + [Guard, Guard, Guard]   seat 1 PRIEST + [Baron, King, Countess]
#   seat 2 Guard + [Guard, Guard, Guard]   seat 3 Guard + [Guard, Guard, Guard]
# Play 1 is seat 0's level-1 move (draw family 0, play the ACTIVE Guard, lowest index live
# opponent = seat 1, declared type Priest) -> seat 1 is eliminated, `reveal_hand == true`.
# The victim's family is Baron / King / Countess - three DISTINCT types, so the `_left` drop of the
# reveal is unambiguous. Then every seat holds only Guards, the Guard probes all declare Priest and
# all miss, so this round has exactly ONE elimination and zero Prince plays.
#   9 plays (3 per live seat), 10 turns, seat 1 out, round ends at seat 0's turn start (family 0).
#   out of play: 9 Guard (played) + Priest + Baron + King + Countess = 13 = 9 plays + 4 revealed
#   -> after play 1 `_left` == [11,...] (16 - 1 play - 4 revealed), at the round end [3,0,...] = 16 - 13
const NOBLE_4P_GUARD_KILL: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Priest, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Baron, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.King, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_4P_GUARD_KILL_LEFT: Array[int] = [12, 1, 1, 0, 0, 1, 1, 0]
const NOBLE_4P_GUARD_KILL_SEAT1_FAMILY: Array[Deck.CardType] = [
	Deck.CardType.Baron, Deck.CardType.King, Deck.CardType.Countess]
const NOBLE_4P_GUARD_KILL_DROP: Array[int] = [1, 1, 1, 0, 0, 1, 1, 0]  # the play-1 drop: played Guard + 4 revealed
const NOBLE_4P_GUARD_KILL_AFTER1: Array[int] = [11, 0, 0, 0, 0, 0, 0, 0]
const NOBLE_4P_GUARD_KILL_END_LEFT: Array[int] = [3, 0, 0, 0, 0, 0, 0, 0]

# TEST E, 4p fixture 2 - a seat Princesses HIMSELF, so the reveal is the family MINUS the card he
# drew for that play, plus the 1 card left in his hand:
#   seat 0 Guard + [Guard x3]   seat 1 Guard + [Guard x3]
#   seat 2 PRINCESS + [Baron, King, Countess]   seat 3 Guard + [Guard x3]
# Seat 2's level-1 move on turn 3 is (draw family 0 = Baron, play the ACTIVE Princess, self) -> he
# discards his Princess, keeps the Baron, and is eliminated with `reveal_hand == true`: revealed =
# hand Baron + family [King, Countess], i.e. 2 family cards, NOT 3 - the drawn one is in his hand.
# Seat 2 is a `right_score` seat (x 68) -> the reveal stack mirrors and must stay on the 84 px board.
#   plays: s0 3 (T1,T5,T8) + s1 3 (T2,T6,T9) + s2 1 (T3) + s3 3 (T4,T7,T10) = 10, 11 turns, seat 2 out,
#   round ends at seat 0's turn start. Out of play: 9 Guard + 1 Princess (played) + Baron + King +
#   Countess (revealed) = 13 -> after play 3 `_left` == [10,...] (16 - 3 plays - 3 revealed), end [3,0,...]
const NOBLE_4P_PRINCESS_KILL: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Princess, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Baron, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.King, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Guard,
]
const NOBLE_4P_PRINCESS_KILL_LEFT: Array[int] = [12, 0, 1, 0, 0, 1, 1, 1]
const NOBLE_4P_PRINCESS_KILL_SEAT2_FAMILY: Array[Deck.CardType] = [
	Deck.CardType.Baron, Deck.CardType.King, Deck.CardType.Countess]
const NOBLE_4P_PRINCESS_KILL_DROP: Array[int] = [0, 0, 1, 0, 0, 1, 1, 1]  # played Princess + hand Baron + family 2
const NOBLE_4P_PRINCESS_KILL_AFTER3: Array[int] = [10, 0, 0, 0, 0, 0, 0, 0]
const NOBLE_4P_PRINCESS_KILL_END_LEFT: Array[int] = [3, 0, 0, 0, 0, 0, 0, 0]

# TEST E, 4p fixture 3 - seat 0 is HUMAN and WINS a Baron, so `reveal_hand == false` (classic: the
# winner SAW the loser's card, the loser is not published to the table). The family still leaves
# play (it always does - it is out of the round with its owner), face-DOWN:
#   seat 0 BARON + [King, Guard, Guard]   seat 1 PRIEST + [King, Countess, Princess]
#   seat 2 Guard + [Guard x3]             seat 3 Guard + [Guard x3]
# The variant compares the ACTIVE cards, i.e. the card each seat keeps in hand (`the leftover is the
# active card`), so the human wins with the King he drew from family[0]: King 6 > Priest 2.
#   plays: s0 3 (T1 Baron, T4 King, T7 Guard) + s2 3 + s3 3 = 9, 10 turns, seat 1 out.
#   out of play: 7 Guard + Baron + King (played) + Priest + King + Countess + Princess (revealed,
#   face-down) = 13 -> after play 1 `_left` == [10,1,0,0,0,1,0,0], at the round end [3,0,0,0,0,0,0,0]
const NOBLE_4P_BARON_HUMAN: Array[Deck.CardType] = [
	Deck.CardType.Baron, Deck.CardType.Priest, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.King, Deck.CardType.King, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Princess, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_4P_BARON_HUMAN_LEFT: Array[int] = [10, 1, 1, 0, 0, 2, 1, 1]
const NOBLE_4P_BARON_HUMAN_SEAT1_FAMILY: Array[Deck.CardType] = [
	Deck.CardType.King, Deck.CardType.Countess, Deck.CardType.Princess]
const NOBLE_4P_BARON_HUMAN_DROP: Array[int] = [0, 1, 1, 0, 0, 1, 1, 1]  # played Baron + 4 revealed
const NOBLE_4P_BARON_HUMAN_AFTER1: Array[int] = [10, 0, 0, 0, 0, 1, 0, 0]
const NOBLE_4P_BARON_HUMAN_END_LEFT: Array[int] = [3, 0, 0, 0, 0, 0, 0, 0]

# TEST F (todo step 18) fixtures. 2p: burn 3 (widow 3), 1 first-hand per seat, family 5 per seat,
# 1 main-pile leftover, NO Prince and NO Priest anywhere -> no seat can ever be eliminated, so the
# whole round is a clean family-out round and the human seat's stack can be sampled 5 times.
# Deal order: burn 0..2, first-hand 3 (seat 0) / 4 (seat 1), family columns 5..14 (seat 0, seat 1),
# main pile 15.
#   seat 0: Guard + [Guard, Guard, Guard, Guard, COUNTRESS]   (his 5th card is never played: he
#   plays the ACTIVE card every turn, so the Countess is the card he keeps at the round end)
#   seat 1: Guard + [Guard, Guard, Guard, Guard, Handmaid]
# Every Guard probe declares Priest and no seat ever holds a Priest -> 10 plays, 11 turns, 0 kills.
const NOBLE_2P_STACK: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Handmaid, Deck.CardType.Handmaid,
]
const NOBLE_2P_STACK_LEFT: Array[int] = [13, 0, 0, 2, 0, 0, 1, 0]  # 13 Guard, 2 Handmaid, 1 Countess

var _failed: int = 0
var _deck: Deck

# Public so another suite can EMBED this one: `tests/smoke_games.gd` instantiates
# `tests/noble_family_rules.tscn`, sets `quit_on_fail = false` (a nested suite must never quit the
# whole game it is embedded in), awaits `suite_done` and reads the counters below. That is how the
# classic smoke test prints its NOBLE UI line: the numbers come from a real run of this suite, not
# from a copy of its checks.
var quit_on_fail: bool = true
var suite_done: bool = false
var ui_openings: int = 0
var ui_taps: int = 0
var ui_mismatch: int = 0
var ui_crowded: int = 0
var ui_leaks: int = 0
var ui_effects: int = 0
var ui_plays: int = 0
var ui_frames: int = 0
var ui_surfaces: Array = []


func fails() -> int:
	return _failed
var _c_plays: Array[int] = [0, 0, 0, 0]  # TEST C: plays per seat, counted on `move_chosen`
# main.gd / player.gd read these off the game's parent node, so the harness must expose them
var print_memory: bool = false
var print_valid_moves: bool = false
var _main  # untyped Main instance for TEST B (no init_players call, so no game loop runs)


func _ready() -> void:
	Animator._speed = 0
	RenderingServer.render_loop_enabled = false
	for i in AudioServer.bus_count:
		AudioServer.set_bus_mute(i, true)

	seed(SEED)
	_deck = DeckScene.instantiate()
	add_child(_deck)

	await _test_deal_table()
	await _test_joint_moves()
	await _test_family_out_round_end()
	await _test_left_audit_real_deck()
	await _test_prince_paths()
	await _test_elimination_reveal()
	await _test_family_stack()
	await _test_family_selector()
	await _test_human_modal()
	await _test_prince_human_modal()
	await _test_modal_rails()
	await _test_deal_presentation()
	await _test_game_mode()
	# TEST N is placed BEFORE TEST M, not appended at the end of the list: Godot's stdout is block-buffered
	# when it is redirected, and the suite's LAST few kilobytes of prints are gone from the log (measured:
	# the committed suite's log ends at M4's last check and its M5 checks and its summary line are missing,
	# in the baseline too). A new section placed last would therefore have NO printed evidence, which is how
	# step 26's first three runs were read as "the suite died at M5". Order is functionally irrelevant -
	# every fixture builds and frees its own app - so the section that must be READ goes second-to-last.
	await _test_stats_tables()
	await _test_mode_menu()
	await await_frames(1)

	print("\n==========================")
	if _failed == 0:
		print("ALL CHECKS PASSED")
	else:
		print(str(_failed) + " CHECK(S) FAILED")
	print("==========================")
	suite_done = true
	if quit_on_fail:
		get_tree().quit(1 if _failed > 0 else 0)


# ----------------------------------------------------------------------------------------
# TEST A: the noble deal table, for 2 / 3 / 4 players.
# ----------------------------------------------------------------------------------------
func _test_deal_table() -> void:
	print("\n########## TEST A: noble deal table (burn 3/1/0, first-hand 1/seat, ")
	print("family 5/4/3, main leftovers 1/0/0) ##########")
	for count: int in [2, 3, 4]:
		var burn: int = Deck.NOBLE_BURN[count]
		var fam: int = Deck.NOBLE_FAMILY_SIZE[count]
		var main_expected: int = TOTAL_CARDS - burn - count * (1 + fam)

		var ok_table: bool = burn + count * (1 + fam) <= TOTAL_CARDS
		var ok_widow := true
		var ok_widow_sprite := true
		var ok_first := true
		var ok_families := true
		var ok_main := true
		var ok_conservation := true
		var ok_left := true
		var ok_permutation := true
		var ok_typed := true

		for t in TRIALS:
			var families: Array = _deck.prepare_noble(count)

			# the widow is the burn pile; in 4p it does not exist at all
			ok_widow = ok_widow and (_deck._widow_cards.size() == burn)
			ok_widow_sprite = ok_widow_sprite and (_deck._widow.visible == (burn > 0))
			# 1 card per seat, dealt before the families, not part of any family
			ok_first = ok_first and (_deck.first_hand.size() == count)
			# one private family per seat, equal sizes, as-dealt order, typed
			ok_families = ok_families and (families.size() == count)
			for i in count:
				ok_families = ok_families and (families[i].size() == fam)
				ok_typed = ok_typed and (families[i] is Array[Deck.CardType])
			# leftovers stay in the main pile; the main sprite mirrors it
			ok_main = ok_main and (_deck._cards.size() == main_expected)
			ok_main = ok_main and (_deck._main.visible == (main_expected > 0))
			# burn + first-hand + families + main = the whole deck
			ok_conservation = ok_conservation and (
				burn + _deck.first_hand.size()
				+ family_cards_total(families)
				+ _deck._cards.size() == TOTAL_CARDS
			)
			# family dealing decrements nothing
			ok_left = ok_left and (_left_counts() == Deck.card_count)
			# the four piles are a permutation of the deck: no duplicate, none lost
			ok_permutation = ok_permutation and (_piles_multiset(families) == Deck.card_count)

		var prefix := (str(count) + "p: burn " + str(burn) + ", family " + str(fam)
			+ ", main " + str(main_expected))
		check(ok_table, prefix + ": deal table fits in 16 cards ("
			+ str(burn) + " + " + str(count) + " x (1 + " + str(fam) + ") <= 16)")
		check(ok_widow, prefix + ": widow holds exactly the " + str(burn)
			+ " burned card(s) over " + str(TRIALS) + " deals")
		check(ok_widow_sprite, prefix + ": widow sprite visible == (burn > 0)"
			+ (" (no widow pile in 4p)" if burn == 0 else ""))
		check(ok_first, prefix + ": exactly " + str(count) + " first-hand card(s), 1 per seat")
		check(ok_families, prefix + ": " + str(count) + " families of " + str(fam)
			+ " card(s) each, equal per seat")
		check(ok_typed, prefix + ": each family is an Array[Deck.CardType] (assignable to Player.family)")
		check(ok_main, prefix + ": main pile keeps " + str(main_expected) + " leftover card(s)")
		check(ok_conservation, prefix + ": conservation burn + first-hand + families + main == 16")
		check(ok_left, prefix + ": `_left` still equals Deck.card_count - dealing decrements nothing")
		check(ok_permutation, prefix + ": widow + first-hand + families + main is a permutation"
			+ " of the 16-card deck (no duplicate, none lost, no Unknown)")


# how many family cards a deal produced in total (all seats are checked equal above)
func family_cards_total(families: Array) -> int:
	var total := 0
	for f in families:
		total += (f as Array).size()
	return total


# `_left` as a plain Array[int], for elementwise comparison with Deck.card_count
func _left_counts() -> Array:
	var out: Array = []
	for n in _deck._left.size():
		out.append(_deck._left[n])
	return out


# multiset of every card the deal produced: main pile + widow + first-hand + all families
func _piles_multiset(families: Array) -> Array:
	var counts: Array = []
	for i in Deck.card_count.size():
		counts.append(0)
	var piles: Array = [_deck._cards, _deck._widow_cards, _deck.first_hand]
	for f in families:
		piles.append(f)
	for pile in piles:
		for c in pile:
			var t: int = c as int
			# an Unknown / out-of-range type in a pile means a card was invented by the deal
			if t < 0 or t >= counts.size():
				return [-1]
			counts[t] += 1
	return counts


# ----------------------------------------------------------------------------------------
# TEST B: the joint (draw, play, target) enumeration + the level 1-4 draw policies.
# A Main scene is instantiated but NEVER started (no init_players call), so the game loop does
# not run: the harness sets the seat's 1-card hand, his family and the protection flags by hand,
# then calls the production Main.find_valid_moves() and Player.select_move() on that state.
# ----------------------------------------------------------------------------------------
func _test_joint_moves() -> void:
	print("\n########## TEST B: joint (draw, play, target) moves (step 11) ##########")
	_main = MainScene.instantiate()
	add_child(_main)
	await await_frames(1)
	_main.noble_family = true
	# fills `_left` with the full counts, which is what eval_moves reads as `left_cards`
	_main._deck.prepare_noble(4)

	# ---- the expected counts, written out by hand (4 seats, nobody protected) ----
	# family [Baron, Handmaid, Princess] in as-dealt order, active card = Guard:
	#   f0 Baron    : Guard x 3 targets x 7 guesses = 21   Baron   x 3 targets = 3
	#   f1 Handmaid : Guard x 3 x 7 = 21                   Handmaid self        = 1
	#   f2 Princess : Guard x 3 x 7 = 21                   Princess self        = 1 (variant only)
	var fam_a: Array = [Deck.CardType.Baron, Deck.CardType.Handmaid, Deck.CardType.Princess]
	var moves_a: Array[Move] = _state(Deck.CardType.Guard, fam_a, 4, [false, false, false, false])
	check(moves_a.size() == 3 * 21 + 3 + 1 + 1, "Guard + family [Baron, Handmaid, Princess] (4p): "
		+ str(moves_a.size()) + " moves, expected " + str(3 * 21 + 3 + 1 + 1))
	check(legal_move_set(moves_a, Deck.CardType.Guard, fam_a, 4),
		"  ... every move plays a card of its own pair, names that draw, targets a legal seat")
	check(moves_a[0]._drawn_family_idx == 0 and moves_a[0]._played_card_idx == 0,
		"the first move draws family index 0 (as-dealt order) and plays the active card")

	# Countess + a man forces the Countess play; Countess + Princess is free, and the Princess
	# self-play exists in the variant enumeration only.
	var fam_b: Array = [Deck.CardType.Prince, Deck.CardType.King, Deck.CardType.Princess]
	var moves_b: Array[Move] = _state(Deck.CardType.Countess, fam_b, 4, [false, false, false, false])
	check(moves_b.size() == 1 + 1 + 2, "Countess + family [Prince, King, Princess] (4p): "
		+ str(moves_b.size()) + " moves, expected 1 + 1 + 2 = 4 (Countess forced twice)")
	check(legal_move_set(moves_b, Deck.CardType.Countess, fam_b, 4),
		"  ... no move plays the Prince/King next to the Countess")

	# 3 seats, both opponents protected: a Prince can only be played on the self seat, and a Guard
	# probe is allowed against a protected seat because every other seat is protected too
	#   f0 Handmaid : Prince on self = 1   Handmaid self = 1
	#   f1 Guard    : Prince on self = 1   Guard x 2 targets x 7 guesses = 14
	var fam_c: Array = [Deck.CardType.Handmaid, Deck.CardType.Guard]
	var moves_c: Array[Move] = _state(Deck.CardType.Prince, fam_c, 3, [false, true, true, false])
	check(moves_c.size() == 1 + 1 + 1 + 14, "Prince + family [Handmaid, Guard] (3p, both opponents "
		+ "protected): " + str(moves_c.size()) + " moves, expected 1 + 1 + 1 + 14 = 17")
	check(legal_move_set(moves_c, Deck.CardType.Prince, fam_c, 3),
		"  ... Prince reaches only the self seat, Guard probes reach the protected seats")

	# The pair that forces a Princess: two Princesses in one seat is impossible in classic (1 copy
	# in the deck) and reachable in the variant. The move list must not be empty - an empty list
	# would strand the seat with no move at all.
	var fam_d: Array = [Deck.CardType.Princess]
	var moves_d: Array[Move] = _state(Deck.CardType.Princess, fam_d, 2, [false, false, false, false])
	check(moves_d.size() == 2, "Princess + family [Princess] (2p): " + str(moves_d.size())
		+ " moves, expected 2 (both cards of the pair are a Princess)")
	check(not moves_d.is_empty() and legal_move_set(moves_d, Deck.CardType.Princess, fam_d, 2),
		"  ... the forced Princess play is a legal self-targeted move, so a seat never has zero moves")

	# A 2-card hand in the variant is the human placeholder path (step 20 replaces it with the
	# modal): classic enumeration, no draws, no Princess play.
	var moves_e: Array[Move] = _state_2_cards(Deck.CardType.Guard, Deck.CardType.Baron, 4)
	check(moves_e.size() == 3 * 7 + 3, "variant seat with a 2-card hand (human placeholder): "
		+ str(moves_e.size()) + " moves, expected Guard 3 x 7 + Baron 3 = 24")
	var no_draws := true
	for m in moves_e:
		no_draws = no_draws and not m.is_noble()
	check(no_draws, "  ... a 2-card hand enumerates classic Moves (no family draw in any of them)")
	var princess_moves := 0
	for m in moves_e:
		if m.played_type() == Deck.CardType.Princess:
			princess_moves += 1
	check(princess_moves == 0, "  ... a Princess is never enumerated outside the joint enumeration")

	# the level checks run on scenario C's own board state, so rebuild it first
	_seat(Deck.CardType.Prince, fam_c, 3, [false, true, true, false])
	_test_levels(moves_c)


# The level 1-4 policies over one enumerated joint-move list (todo step 12).
func _test_levels(moves: Array[Move]) -> void:
	var p = _main._players[0]
	var left: Array[int] = _main._deck._left

	p.ai_level = Player.AI_Level.Level_1
	var l1: Move = p.select_move(moves, left)
	check(l1 == moves[0] and l1._drawn_family_idx == 0,
		"level 1 takes the first joint move (family index 0, as-dealt order): " + str(l1))

	p.ai_level = Player.AI_Level.Level_2
	var distinct: Dictionary = {}
	var ok_l2 := true
	for i in 60:
		var m: Move = p.select_move(moves, left)
		ok_l2 = ok_l2 and (m in moves)
		distinct[str(m._drawn_family_idx) + "/" + str(m._played_card_idx)] = true
	check(ok_l2, "level 2 only ever picks an enumerated move (60 samples)")
	check(distinct.size() > 1, "level 2 spreads over the list: " + str(distinct.size())
		+ " distinct (draw, play) pairs out of " + str(moves.size()) + " moves")

	var min_drawn: Deck.CardType = moves[0]._drawn_type
	for m in moves:
		if m._drawn_type < min_drawn:
			min_drawn = m._drawn_type
	var by_draw: Array[Move] = []
	var cheap_exists := false
	for m in moves:
		if m._drawn_type == min_drawn:
			by_draw.append(m)
			if m.played_type() <= m._leftover_type:
				cheap_exists = true
	p.ai_level = Player.AI_Level.Level_3
	var ok_l3 := true
	for i in 40:
		var m: Move = p.select_move(moves, left)
		if m._drawn_type != min_drawn:
			ok_l3 = false
		if cheap_exists and m.played_type() > m._leftover_type:
			ok_l3 = false
	check(ok_l3, "level 3 draws the cheapest family card (" + Deck.card_names[min_drawn]
		+ ", " + str(len(by_draw)) + " candidate move(s)) and plays the cheaper card of the pair "
		+ "whenever such a play exists (40 samples)")

	# level 4 = the existing weighted eval, no new scoring terms: a 0-score move (a Princess
	# self-play has no eval branch) can never win while anything in the list scores.
	p.ai_level = Player.AI_Level.Level_4
	p.eval_moves(moves, left)
	var sum := 0
	for m in moves:
		sum += m._score
	var ok_l4 := true
	if sum > 0:
		for i in 40:
			if p.select_move(moves, left)._score == 0:
				ok_l4 = false
	check(sum > 0, "level 4 scores the joint list (sum of _score = " + str(sum) + ")")
	check(ok_l4, "level 4 never plays a 0-score move (the Princess self-play) while a scoring "
		+ "move exists (40 samples)")


# Build one variant decision state for seat 0 (1 hand card + family) and enumerate it.
func _state(active_t: Deck.CardType, family: Array, count: int,
		protected_flags: Array) -> Array[Move]:
	_seat(active_t, family, count, protected_flags)
	return _main.find_valid_moves()


# The same with a 2-card hand - the classic selection the human seat gets until step 20.
func _state_2_cards(a: Deck.CardType, b: Deck.CardType, count: int) -> Array[Move]:
	_seat(a, [], count, [false, false, false, false])
	_add_card(_main._players[0], b)
	return _main.find_valid_moves()


func _seat(active_t: Deck.CardType, family: Array, count: int, protected_flags: Array) -> void:
	for i in 4:
		var p = _main._players[i]
		p.active = i < count
		p.ai_level = Player.AI_Level.Level_1 if i < count else Player.AI_Level.Disabled
		p.protected = protected_flags[i]
		p.clear_hand()
		p.clear_family()
	_main._cur_player = 0
	_add_card(_main._players[0], active_t)
	var fam: Array[Deck.CardType] = []
	for t in family:
		fam.append(t)
	_main._players[0].family = fam
	# `_other_protected`, exactly as new_turn() computes it
	var other_protected := true
	for pl in _main._players:
		if pl.is_active() and not pl.protected and pl.idx != 0:
			other_protected = false
	_main._other_protected = other_protected


func _add_card(p: Player, t: Deck.CardType) -> void:
	# exactly the production order (Main.deal_card): the card enters the tree in the animation
	# layer first - `Card.type` / `faceup` setters touch the sprite, which only exists once the
	# node is in the tree - and only then `Player.add_card` reparents it into the hand.
	var c = _main.card_scene.instantiate()
	_main._animation_layer.add_child(c)
	c.type = t
	c.faceup = true
	p.add_card(c)


# Every property a joint move must have, checked move by move:
# 1. the draw is a real family index and `_drawn_type` is that family card;
# 2. the pair: playing one of (active, family[f]) keeps the other, so `_leftover_type` is forced;
# 3. `_played_card` matches the played slot (null when only the drawn card is played);
# 4. Countess + man plays the Countess;
# 5. the target follows the type rules (self-only for Handmaid/Countess/Princess, Prince hits an
#    unprotected seat incl. self, Guard probes name a guessable type, the rest hit opponents);
# 6. no (draw, play, target, type) combination is generated twice.
func legal_move_set(moves: Array[Move], active_t: Deck.CardType, family: Array,
		count: int) -> bool:
	var ok := true
	var seen: Dictionary = {}
	for m in moves:
		var f: int = m._drawn_family_idx
		ok = ok and f >= 0 and f < family.size() and m._drawn_type == family[f]
		var played: Deck.CardType = m.played_type()
		var kept: Deck.CardType = family[f] if played == active_t else active_t
		ok = ok and (played == active_t or played == family[f])
		ok = ok and m._leftover_type == kept
		ok = ok and ((m._played_card_idx == 0) == (played == active_t and m._played_card != null))
		if m._played_card_idx == 0:
			ok = ok and m._played_card == _main._players[0].hand.get_child(0)
		if m._played_card_idx == 1:
			ok = ok and m._played_card == null
		if is_countess_pair(active_t, family[f]):
			ok = ok and played == Deck.CardType.Countess
		ok = ok and legal_target(m, played, count)
		var key := str(f) + "/" + str(m._played_card_idx) + "/" + str(m._target_player) + "/"
		key += str(m._target_type)
		ok = ok and not seen.has(key)
		seen[key] = true
	return ok


func is_countess_pair(a: Deck.CardType, b: Deck.CardType) -> bool:
	return (a == Deck.CardType.Countess or b == Deck.CardType.Countess) and (
		_main._players[0].is_man(a) or _main._players[0].is_man(b))


func legal_target(m: Move, played: Deck.CardType, count: int) -> bool:
	var tgt: int = m._target_player
	if played == Deck.CardType.Handmaid or played == Deck.CardType.Countess \
			or played == Deck.CardType.Princess:
		return tgt == -1
	if tgt < 0 or tgt >= count or not _main._players[tgt].is_active():
		return false
	var target_protected: bool = _main._players[tgt].protected
	if played == Deck.CardType.Prince:
		return not target_protected
	if played == Deck.CardType.Guard:
		return tgt != 0 and (not target_protected or _main._other_protected)
	return tgt != 0 and not target_protected


# ----------------------------------------------------------------------------------------
# TEST C (todo step 14): a whole scripted 4-player variant round.
#
# The rule under test: "the round ends at TURN START when the seat to act has an empty family",
# and the corollary the same step demands: an AI seat does NOT draw at turn start - the family
# draw belongs to the chosen move (step 13), so exactly ONE family draw happens per play.
#
# Every seat is level 1 -> `valid_moves[0]` = (draw family index 0, play the active card), so the
# whole round is deterministic: seat i plays first-hand, family[0], family[1] on his 1st/2nd/3rd
# turn and keeps family[2]. 12 plays, zero eliminations (the scripted supply has no Priest in any
# hand, so every Guard probe misses by construction), and the 13th turn starts at seat 0 with an
# empty family - the round ends there and nowhere else.
# ----------------------------------------------------------------------------------------
func _test_family_out_round_end() -> void:
	print("\n########## TEST C: a 4p round ends exactly at the turn start with an empty family (step 14) ##########")
	var main = MainScene.instantiate()
	var card_scene: PackedScene = main.card_scene  # set_script resets exported vars
	main.set_script(load(CountingMainScript))
	main.card_scene = card_scene
	# the deck script goes on BEFORE the scene enters the tree, so the Deck node's @onready
	# references are resolved by the test script (set_script on a ready node leaves them null)
	var deck = main.get_node("Table/Deck")
	deck.set_script(FakeDeckScript)
	deck.scripted = NOBLE_SCRIPTED
	deck.scripted_left = NOBLE_SCRIPTED_LEFT
	add_child(main)
	main.noble_family = true
	for i in 4:
		main._players[i].ai_level = Player.AI_Level.Level_1  # deterministic seat, seat 0 is NOT human
	for i in 4:
		main._players[i].move_chosen.connect(_count_c_play.bind(i))
	await main.init_players(SEED)
	# init_players() does not await the deal coroutine, so poll until the opening deal settled
	await await_until(func() -> bool:
		var ready := true
		for p in main._players:
			ready = ready and p.hand.get_child_count() == 1 and p.family_size() == Deck.NOBLE_FAMILY_SIZE[4]
		return ready)

	# --- the scripted deal, as the production deal table applies it in 4p ---
	var fam: int = Deck.NOBLE_FAMILY_SIZE[4]
	check(main._deck.first_hand.size() == 4, "4p deal: 1 first-hand card per seat (4 cards)")
	for p in main._players:
		check(p.family_size() == fam, "seat " + str(p.idx) + " holds a family of " + str(fam)
			+ " scripted cards: " + family_str(p))
	check(deck._widow_cards.is_empty() and !deck._widow.visible,
		"4p burns nothing -> no widow pile exists (empty and hidden)")
	check(deck._cards.is_empty() and !deck._main.visible,
		"4p main pile: 16 - 0 burn - 4 first-hand - 12 family = 0 leftovers (empty and hidden)")
	var supply := 0
	for n in deck._left.size():
		supply += deck._left[n]
	check(supply == TOTAL_CARDS, "the scripted supply is 16 cards and `_left` mirrors it ("
		+ str(supply) + "), so the discard accounting of a whole round is assertable")

	# --- play 4 whole rounds and check every one of them ---
	var seen_rounds: int = 0
	var seen_fam: Array[int] = [0, 0, 0, 0]
	var seen_idx: Array[int] = [0, 0, 0, 0]
	var seen_elim: int = 0
	var seen_pile: int = 0
	var seen_first_hand: int = 0
	var seen_turns: Array[int] = [0, 0, 0, 0]
	var rounds: Array = []  # per round: total plays (cross-check of the harness counters)
	for _f in 20000:
		if main.round_end_actor.size() > seen_rounds:
			var r: int = seen_rounds
			seen_rounds += 1
			var prefix := "round " + str(r + 1) + ":"
			var actor: int = main.round_end_actor[r]
			var fams: Array = main.round_end_families[r]
			var hands: Array = main.round_end_hands[r]
			var left: Array = main.round_end_left[r]
			var turns: Array = main.round_end_turns[r]
			var start_seat: int = main.round_start_actor[r]
			var turns_total := 0
			for j in 4:
				turns_total += int(turns[j]) - seen_turns[j]
				seen_turns[j] = int(turns[j])
			var drew: Array[int] = [0, 0, 0, 0]
			var drew_idx: Array = []
			var total: int = 0
			for j in 4:
				drew[j] = main.family_draws[j] - seen_fam[j]
				seen_fam[j] = main.family_draws[j]
				var k: int = seen_idx[j]
				while k < main.family_draw_idx[j].size():
					drew_idx.append(main.family_draw_idx[j][k])
					k += 1
				seen_idx[j] = main.family_draw_idx[j].size()
				total += _c_plays[j]
			var elim_delta: int = main.eliminations - seen_elim
			seen_elim = main.eliminations
			var pile_delta: int = main.pile_draws - seen_pile
			seen_pile = main.pile_draws

			check(total == 4 * fam, prefix + " " + str(total) + " plays == 4 seats x family size "
				+ str(fam) + ": the round ran to the family-out end, it never stopped earlier")
			check(turns_total == 4 * fam + 1, prefix + " " + str(turns_total) + " turns == 4 x "
				+ str(fam) + " plays + 1: the round ended on the turn that found the empty family, i.e."
				+ " at TURN START, after every playable turn was taken")
			check(actor == start_seat, prefix + " the round ended on seat " + str(actor) + ", the same seat"
				+ " that opened it (seat " + str(start_seat) + "): 4 seats x " + str(fam)
				+ " family cards means the seat to act on the " + str(4 * fam + 1) + "th turn is the seat "
				+ "that took the 1st turn, so the family-out rule ends the round there")
			check(int(fams[actor]) == 0, prefix + " the seat to act has an EMPTY family: that is the"
				+ " variant's only round-end rule (" + str(int(fams[actor])) + " family card left)")
			var fam_total := 0
			for j in 4:
				fam_total += int(fams[j])
			check(fam_total == 0, prefix + " every family is exhausted (sum " + str(fam_total)
				+ "), no seat was cut off before his last card")
			check(elim_delta == 0, prefix + " no elimination (" + str(elim_delta) + "): the scripted plays"
				+ " (Guard probes on non-Priests, Handmaid, Countess) cannot kill a seat, so the family-out"
				+ " rule is the only way this round could end")
			check(pile_delta == 0, prefix + " zero draws from the main pile / the widow ("
				+ str(pile_delta) + " Deck.pop draws): the turn-start draw is a family draw only")
			var fh_delta: int = main.first_hand_deals - seen_first_hand
			seen_first_hand = main.first_hand_deals
			check(fh_delta == 4, prefix + " " + str(fh_delta) + " first-hand cards dealt (1 per seat,"
				+ " animated through deal_card with an explicit type) - the round was re-dealt")
			var one_draw_per_play := true
			for j in 4:
				# THE step 14 assertion: seat plays == family draws == family size. A turn-start
				# placeholder draw would make family_draws 4 > family size (and crash pop_family).
				one_draw_per_play = one_draw_per_play and drew[j] == fam and drew[j] == _c_plays[j]
			check(one_draw_per_play, prefix + " every seat drew exactly " + str(fam)
				+ " family cards in exactly " + str(fam) + " plays - one draw per play, no turn-start"
				+ " draw for an AI seat (draws " + str(drew) + ", plays " + str(_c_plays) + ")")
			var idx_zero_only := true
			for k in drew_idx:
				idx_zero_only = idx_zero_only and int(k) == 0
			check(idx_zero_only, prefix + " every draw used family index 0 (as-dealt order): "
				+ str(drew_idx))
			var one_card := true
			for j in 4:
				one_card = one_card and int(hands[j]) == 1
			check(one_card, prefix + " every live seat holds exactly 1 card at the round end ("
				+ str(hands) + ")")
			var left_ok := true
			var left_sum := 0
			for n in left.size():
				left_sum += int(left[n])
				left_ok = left_ok and int(left[n]) == NOBLE_ROUND_END_LEFT[n]
			check(left_ok, prefix + " `_left` == " + str(left) + ", expected "
				+ str(NOBLE_ROUND_END_LEFT) + " (16 - 12 plays, family draws decremented nothing)")
			check(left_sum == TOTAL_CARDS - total, prefix + " sum(_left) == 16 - " + str(total)
				+ " plays == " + str(left_sum))
			rounds.append(total)
			for j in 4:
				_c_plays[j] = 0
		if seen_rounds >= 4:
			break
		await get_tree().process_frame

	check(seen_rounds >= 4, "4 scripted rounds ran (" + str(seen_rounds) + " observed), every one of"
		+ " them a 12-play family-out end: " + str(rounds))
	check(main.draws_checked > 0 and main.draw_mismatches.is_empty(),
		"every move named the family card its own play chain drew (" + str(main.draws_checked)
		+ " pairings, " + str(main.draw_mismatches.size()) + " mismatches)")
	_check_left_audit(main, "TEST C (the 12-play family-out game)")
	# the scripted deal is re-applied every round (families are re-dealt, never carried over)
	var redeal := true
	for p in main._players:
		redeal = redeal and p.active
	check(redeal, "the next round is dealt and the seats are live again (families are re-dealt every"
		+ " round, they are not carried over)")
	for p in main._players:
		p.clear_hand()
		check(p.hand.get_child_count() == 0, "seat " + str(p.idx) + " hand cleared")
	main.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# TEST C2 (todo step 17): the continuous `_left` audit on the REAL deck.
#
# TEST C and every fixture after it run on `FakeDeckScript`, whose `_left` is a hand-written SHAPE
# (its `deal_card()` decrements `_left.find(true)`, the type with most left, not the type it hands
# out). The audit's per-type identity
#     _left[t] == (supply as dealt for this round) - (cards of type t discarded in it)
# is a statement about the REAL deck's accounting - `Main.discard()` is the ONLY decrement, `Deck.pop`
# decrements nothing, `Deck._build_deck()` resets the supply every round - so on those fixtures the
# audit skips and their own end-of-round checks are the gate. This fixture is the counterpart: the
# real 16-card supply (`Deck.card_count`), four level-1 seats, seed fixed so the shuffle is
# reproducible. The plays are NOT scripted, so eliminations, Prince hits, reveals and family-out ends
# land wherever the cards fall - which is the point: the identity has to hold at EVERY audit point
# (turn start, pre-decision state, decision, both sides of every effect), continuously, not only at
# the round-end snapshot the smoke suite reads.
# ----------------------------------------------------------------------------------------
func _test_left_audit_real_deck() -> void:
	print("\n########## TEST C2: the continuous `_left` audit on the real 16-card supply (step 17) ##########")
	var main = MainScene.instantiate()
	var card_scene: PackedScene = main.card_scene  # set_script resets exported vars
	main.set_script(load(CountingMainScript))
	main.card_scene = card_scene
	var deck = main.get_node("Table/Deck")
	add_child(main)  # the real Deck script STAYS on: no set_script here, the audit audits real accounting
	main.noble_family = true
	for i in 4:
		main._players[i].ai_level = Player.AI_Level.Level_1  # deterministic seat policy, seat 0 is not human
		main._players[i].move_chosen.connect(_count_c_play.bind(i))
	await main.init_players(SEED)
	await await_until(func() -> bool:
		var ready := true
		for p in main._players:
			ready = ready and p.hand.get_child_count() == 1 and p.family_size() == Deck.NOBLE_FAMILY_SIZE[4]
		return ready)

	check(main.audit_applies(), "the fixture runs the REAL `Deck` script, so `_left` is counted (the"
		+ " other fixtures script it and the audit skips there)")
	var supply: int = 0
	var dealt: Array[int] = []
	for t in deck._left.size():
		supply += int(deck._left[t])
		dealt.append(int(Deck.card_count[t]))
	check(supply == TOTAL_CARDS, "the supply at the first turn is " + str(supply) + " cards, the real"
		+ " 16 (`Deck.card_count`: 4p burns 0, 4 first-hand, 12 family, 0 leftovers) - the audit"
		+ " measures the DEAL, not the main pile, which the variant never draws from")
	var base: Array[int] = main.baseline_left()
	var base_ok: bool = base.size() == dealt.size()
	for t in dealt.size():
		base_ok = base_ok and int(base[t]) == int(dealt[t])
	check(base_ok, "the round's baseline `_left` == " + str(base) + " == `Deck.card_count` " + str(dealt)
		+ ": the deck is reset at the round start with NOTHING discarded, and the baseline is taken at"
		+ " the first turn, when every card of the supply has exactly one home")
	var base_kinds: Array[int] = main.baseline_kinds()
	var kinds_zero: bool = true
	for k in base_kinds.size():
		kinds_zero = kinds_zero and int(base_kinds[k]) == 0
	check(kinds_zero, "the baseline discard counters are all zero (" + str(base_kinds)
		+ "): the deal itself discards nothing, so every card the round accounts for is a card that"
		+ " left play")

	var seen_rounds: int = 0
	var per_round: Array = []  # per round: [plays, discards, eliminated seats]
	for _f in 20000:
		if main.round_end_actor.size() > seen_rounds:
			var rec: Dictionary = main.round_end_records[seen_rounds]
			var tag: String = "real-deck round " + str(seen_rounds + 1)
			seen_rounds += 1
			var left: Array = rec["left"]
			var b_left: Array = rec["base_left"]
			var b_disc: Array = rec["base_discarded"]
			var e_disc: Array = rec["discarded"]
			var bk: Array = rec["base_kinds"]
			var ek: Array = rec["kinds"]
			var disc: int = 0
			for k in 4:
				disc += int(ek[k]) - int(bk[k])
			var plays: int = int(ek[0]) - int(bk[0])  # cards discarded FROM the table are the plays
			var hands: int = int(ek[1]) - int(bk[1])
			var fams: int = int(ek[2]) - int(bk[2])
			var other: int = int(ek[3]) - int(bk[3])
			per_round.append([plays, disc, hands, fams, other])
			check(bool(rec["settled"]) and bool(rec["audited"]), tag + ": the round-end snapshot is a"
				+ " settled moment of a real-deck round, so the accounting is assertable there")
			var b_sum: int = 0
			var l_sum: int = 0
			var exact: bool = true
			for t in left.size():
				var used: int = int(e_disc[t]) - int(b_disc[t])
				b_sum += int(b_left[t])
				l_sum += int(left[t])
				exact = exact and int(left[t]) == int(b_left[t]) - used
			check(exact, tag + ": `_left` at the round end == " + str(left) + ", and per type it is"
				+ " exactly the dealt supply minus what left play (" + str(disc) + " discards)")
			check(b_sum == TOTAL_CARDS, tag + ": the round was dealt a full " + str(b_sum)
				+ "-card supply -> `Deck._build_deck()` reset `_left` at the round start, every round,"
				+ " the families included")
			check(l_sum == TOTAL_CARDS - disc, tag + ": sum(_left) == " + str(l_sum) + " == 16 - "
				+ str(disc) + " discards (" + str(plays) + " plays + " + str(hands) + " hand cards + "
				+ str(fams) + " revealed family cards + " + str(other) + " other)")
			check(other == 0, tag + ": no card left play through an unknown container")
		if seen_rounds >= 3:
			break
		await get_tree().process_frame

	check(seen_rounds >= 3, str(seen_rounds) + " real-deck rounds ran with the audit live")
	_check_left_audit(main, "TEST C2 (the real 16-card supply)")
	print("INFO  TEST C2 per round [plays, discards, hand cards, revealed family cards, other]: "
		+ str(per_round))
	main.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# TEST D (todo step 15): the Prince redraw chain - the target's OWN family first, the widow as
# the fallback pile, and elimination when he has neither.
#
# Both fixtures are whole scripted games, every seat on level 1 (`valid_moves[0]` = draw family
# index 0, play the ACTIVE card, first legal target in seat-index order), so the round is fully
# deterministic. The Prince hits are forced by Handmaids: an acting seat self-targets only when he
# is the lowest-index live unprotected seat, so protecting seats 0/1 aims seat 3's Prince at seat 2.
# The 4p fixture has NO widow at all (4p burns nothing); the 3p fixture has a 1-card widow, so one
# 3p round delivers all three outcomes: family draw, widow fallback, elimination.
#
# 4p derivation (deal order == scripted order: 4 first-hand cards, then the 3 family columns):
#   seat 0 = Handmaid + [Handmaid, Guard, Guard]   seat 1 = Handmaid + [Handmaid, Guard, Guard]
#   seat 2 = Guard    + [Guard, Guard, Guard]      seat 3 = Prince  + [Prince, Guard, Guard]
#   T1 s0 Handmaid (protected)   T2 s1 Handmaid (protected)
#   T3 s2 Guard -> s3 declares Priest, misses (s3 holds the Prince)
#   T4 s3 Prince -> s2 (s0/s1 protected): s2 family 2 -> 1, his hand card discarded, family[0] drawn
#   T5 s0 Handmaid (protected)   T6 s1 Handmaid (protected)
#   T7 s2 Guard -> s3 declares Priest, misses; s2's own draw empties his family (1 -> 0)
#   T8 s3 Prince -> s2: family 0, NO widow in 4p -> s2 is ELIMINATED
#   T9 s0, T10 s1, T11 s3 (Guard probes, all misses) -> T12 s0 finds an empty family: round over
#   => 11 plays, 12 turns, 2 Prince hits, 1 elimination (seat 2), 0 pile draws.
#      out of play: 7 Guard (5 played + 2 target hand cards) + 4 Handmaid + 2 Prince = 13 = 11+2
#      -> `_left` == [3,0,0,0,0,0,0,0]
#
# 3p derivation (widow = 1 Guard; family size 4):
#   seat 0 = Guard + [Guard x4]   seat 1 = Prince + [Prince, Guard, Guard, Guard]
#   seat 2 = Prince + [Prince, Guard, Guard, Guard]
#   T1 s0 Guard -> s1 declares Priest, misses (s1 holds the Prince)
#   T2 s1 Prince -> s0 (family 3 -> 2, hand redrawn from the family)
#   T3 s2 Prince -> s0 (family 2 -> 1, hand redrawn from the family)
#   T4 s0 Guard -> s1 declares Priest, misses; his own draw empties his family (1 -> 0)
#   T5 s1 Prince -> s0: family 0, widow has 1 card -> he draws THE WIDOW (widow 1 -> 0, hand 1)
#   T6 s2 Prince -> s0: family 0 AND widow 0 -> s0 is ELIMINATED (in 3p, once the widow is spent)
#   T7 s1, T8 s2, T9 s1, T10 s2 (Guard probes, all miss) -> T11 s1 finds an empty family: round over
#   => 10 plays, 11 turns, 4 Prince hits, 1 elimination (seat 0), exactly 1 pile draw = the widow.
#      out of play: 10 Guard (6 played + 4 target hand cards) + 4 Prince = 14 = 10+4
#      -> `_left` == [2,0,0,0,0,0,0,0]
# ----------------------------------------------------------------------------------------
func _test_prince_paths() -> void:
	print("\n########## TEST D: Prince - family draw, widow fallback, elimination (step 15) ##########")
	await _test_prince_4p()
	await _test_prince_3p()
	await _test_prince_last_family_card()
	await _test_prince_2p_mainpile()


func _test_prince_4p() -> void:
	var main = _scripted_main(4, NOBLE_4P_PRINCE, NOBLE_4P_PRINCE_LEFT)
	await _settle_deal(main)
	check(main._deck._widow_cards.is_empty() and !main._deck._widow.visible,
		"4p setup: 4 burns nothing -> the widow pile does not exist (empty and hidden), so a Prince hit"
		+ " on a seat with an empty family has no fallback")
	check(main._deck._cards.is_empty() and !main._deck._main.visible,
		"4p setup: the main pile keeps 16 - 0 burn - 4 first-hand - 12 family = 0 cards, so the widow"
		+ " fallback has no main-pile card in front of it either")
	var recs: Array = await _run_to_first_round_end(main)
	_check_effect_log_basics(recs, main)

	check(recs.size() == 11, "4p round: " + str(recs.size()) + " plays (11 derived: 4 seats x 3 family"
		+ " cards, seat 2's 3 are eaten by 2 own draws + 2 Prince hits, and the eliminated seat plays"
		+ " 2 times only)")
	var turns: Array = main.round_end_turns[0]
	var turn_total: int = 0
	for t in turns:
		turn_total += int(t)
	check(turn_total == 12 and int(main.round_end_actor[0]) == 0,
		"4p round: " + str(turn_total) + " turns == 11 plays + 1, ended by seat "
		+ str(main.round_end_actor[0]) + " (seat 0 opened it): the round ended at the TURN START that"
		+ " found an empty family, not on the elimination")

	var prince_plays: Array[int] = []
	for i in recs.size():
		if int(recs[i]["played"]) == Deck.CardType.Prince:
			prince_plays.append(i + 1)
	check(prince_plays == [4, 8], "4p: the Prince plays are the 4th and 8th plays " + str(prince_plays)
		+ " (seats 0 and 1 are protected by their Handmaids on both, so the Prince aims at the lowest"
		+ " index live unprotected seat = seat 2)")
	var hit_targets := true
	for n in prince_plays:
		hit_targets = hit_targets and int(recs[n - 1]["target"]) == 2
	check(hit_targets, "4p: both Prince plays target seat 2")

	# the first hit: family draw (family 2 -> 1), hand back to exactly 1 card, no pile touched
	var r4: Dictionary = recs[3]
	check(int(r4["before"]["fams"][2]) == 2, "4p hit 1 (play 4): seat 2 held 2 family cards when the"
		+ " Prince hit him -> he MUST redraw from his own family, not from a pile")
	check(int(r4["after"]["fams"][2]) == 1 and int(r4["after"]["hands"][2]) == 1
			and bool(r4["after"]["active"][2]),
		"4p hit 1: seat 2 family 2 -> 1, hand == 1 card, still in the round (the Prince never leaves a"
		+ " seat with 0 or 2 cards)")
	check(int(r4["before"]["widow"]) == 0 and int(r4["after"]["widow"]) == 0,
		"4p hit 1: the widow pile was empty before and after (there is no widow in 4p)")

	# the second hit: family 0 and no widow -> elimination
	var r8: Dictionary = recs[7]
	check(int(r8["before"]["fams"][2]) == 0, "4p hit 2 (play 8): seat 2's family was ALREADY empty when"
		+ " the Prince hit him (emptied by his 3rd own draw on play 7): the Prince ate the 2nd and 3rd,"
		+ " he drew the 1st himself")
	check(int(r8["after"]["widow"]) == 0 and int(r8["after"]["left_sum"]) == TOTAL_CARDS - 8 - 2,
		"4p hit 2: no fallback card exists to draw -> sum(_left) == 16 - 8 plays - 2 hits ="
		+ " " + str(int(r8["after"]["left_sum"])))
	check(!bool(r8["after"]["active"][2]) and int(r8["after"]["hands"][2]) == 0,
		"4p hit 2: seat 2 is ELIMINATED (out of the round, 0 hand cards) - an empty family and no"
		+ " widow leaves no other outcome")
	check(main.eliminations == 1 and main.eliminated_seats == [2],
		"4p round: exactly 1 elimination, seat " + str(main.eliminated_seats))
	check(main.pile_draws == 0, "4p round: ZERO draws from the main pile / the widow ("
		+ str(main.pile_draws) + ") - the Prince is the only pile-drawing play in the variant and in 4p"
		+ " no pile exists")
	var widow_hidden := true
	for r in recs:
		widow_hidden = widow_hidden and !bool(r["after"]["widow_visible"])
	check(widow_hidden, "4p round: the widow sprite stayed hidden through all " + str(recs.size())
		+ " plays (it never exists in 4p)")

	var fams_at_end: Array = main.round_end_families[0]
	var fam_total := 0
	for f in fams_at_end:
		fam_total += int(f)
	check(fam_total == 0, "4p round: every family is exhausted at the round end (sum " + str(fam_total)
		+ "), 12 family cards == 4 seats x 3, and 2 of them left play as the Prince targets' hand cards")
	check(main.family_draws[2] == 3, "4p round: seat 2 drew exactly 3 family cards (" + str(main.family_draws[2])
		+ ") = 2 own plays + 2 hits, one card each: the 4th hit drew NOTHING (empty family, no widow)")
	var idx_zero_only := true
	var draws_total := 0
	for i in 4:
		draws_total += main.family_draws[i]
		for k in main.family_draw_idx[i]:
			idx_zero_only = idx_zero_only and int(k) == 0
	check(idx_zero_only, "4p round: every family draw used index 0 (as-dealt order) - the Prince redraw"
		+ " never picks a family card of its own")
	check(draws_total == 12, "4p round: 12 family draws in total (" + str(draws_total)
		+ ") == 4 seats x family size 3: 11 plays + the 2 hits that found a family == 13 draws of"
		+ " which 12 had a card, the 2 hits on an empty family drew none")
	_check_left_end(recs, NOBLE_4P_PRINCE_END_LEFT, "4p")
	_check_pairings(main)
	main.queue_free()
	await await_frames(2)


func _test_prince_3p() -> void:
	var main = _scripted_main(3, NOBLE_3P_PRINCE, NOBLE_3P_PRINCE_LEFT)
	await _settle_deal(main)
	check(main._deck._widow_cards.size() == 1 and main._deck._widow.visible,
		"3p setup: burn 1 -> the widow holds exactly the 1 burned card and is the ONLY fallback pile"
		+ " (the main pile keeps 16 - 1 - 3 - 12 = 0 cards)")
	var recs: Array = await _run_to_first_round_end(main)
	_check_effect_log_basics(recs, main)

	check(recs.size() == 10, "3p round: " + str(recs.size()) + " plays (10 derived: 4 Prince hits on"
		+ " seat 0, 2 plays by seat 0 before he is out, 4 by seat 1, 3 by seat 2)")
	var turns: Array = main.round_end_turns[0]
	var turn_total: int = 0
	for t in turns:
		turn_total += int(t)
	check(turn_total == 11 and int(main.round_end_actor[0]) == 1,
		"3p round: " + str(turn_total) + " turns == 10 plays + 1, ended by seat "
		+ str(main.round_end_actor[0]) + ": the elimination of seat 0 does NOT end the round, the"
		+ " family-out rule does (seat 1 empties his family on the 11th turn)")

	var prince_plays: Array[int] = []
	for i in recs.size():
		if int(recs[i]["played"]) == Deck.CardType.Prince:
			prince_plays.append(i + 1)
	check(prince_plays == [2, 3, 5, 6], "3p: the Prince plays are 2, 3, 5, 6 " + str(prince_plays)
		+ " - seats 1 and 2 hold Prince as their active card on four consecutive turns (first-hand,"
		+ " then family[0] drawn by the previous hit)")
	var targets_zero := true
	for n in prince_plays:
		targets_zero = targets_zero and int(recs[n - 1]["target"]) == 0
	check(targets_zero, "3p: all four Prince plays target seat 0 (he never plays a Handmaid, so he is"
		+ " the lowest index live unprotected seat)")

	# hits 1 and 2: family draws
	var family_hits_ok := true
	for n in [2, 3]:
		var r: Dictionary = recs[n - 1]
		var victim: int = int(r["target"])
		var fam_before: int = int(r["before"]["fams"][victim])
		var fam_after: int = int(r["after"]["fams"][victim])
		family_hits_ok = family_hits_ok and fam_before > 0 and fam_after == fam_before - 1
		family_hits_ok = family_hits_ok and int(r["after"]["hands"][victim]) == 1
		family_hits_ok = family_hits_ok and int(r["after"]["widow"]) == 1
	check(family_hits_ok, "3p hits 1 + 2 (plays 2, 3): seat 0's family 4->3->2->1, hand back to 1 card"
		+ " each time, the widow UNTOUCHED (3 -> family 3 and 2 at the hit) - a family card is eaten"
		+ " before any fallback card is considered")

	# hit 3: family 0 -> the widow is the fallback
	var r5: Dictionary = recs[4]
	check(int(r5["before"]["fams"][0]) == 0 and int(r5["before"]["widow"]) == 1,
		"3p hit 3 (play 5): seat 0's family is EMPTY (his own draw on play 4 took the last card) and"
		+ " the widow still holds its 1 card -> the widow is the fallback pile")
	check(int(r5["after"]["widow"]) == 0 and int(r5["after"]["hands"][0]) == 1
			and int(r5["after"]["fams"][0]) == 0 and bool(r5["after"]["active"][0]),
		"3p hit 3: seat 0 drew THE WIDOW (widow 1 -> 0, hand == 1 card, family still 0, still in the"
		+ " round) - the widow is the ONLY pile the variant ever draws from")
	check(!main._deck._widow.visible, "3p hit 3: the widow sprite is hidden once the widow is spent"
		+ " (update_piles() keeps it in sync)")
	check(main.pile_draws == 1, "3p round: exactly " + str(main.pile_draws)
		+ " draw from a pile, and it is this widow fallback - never a turn-start draw")

	# hit 4: family 0 AND widow 0 -> elimination, in 3p too
	var r6: Dictionary = recs[5]
	check(int(r6["before"]["fams"][0]) == 0 and int(r6["before"]["widow"]) == 0,
		"3p hit 4 (play 6): family 0 and widow 0 - the fallback is spent, so nothing is left to draw")
	check(!bool(r6["after"]["active"][0]) and int(r6["after"]["hands"][0]) == 0,
		"3p hit 4: seat 0 is ELIMINATED - no widow card left is the only way a 3p seat goes out by a"
		+ " Prince, so the widow really is the last line of defence")
	check(main.eliminations == 1 and main.eliminated_seats == [0],
		"3p round: exactly 1 elimination, seat " + str(main.eliminated_seats)
		+ " (the Guard probes all declare Priest and every target holds a Guard, so nothing else dies)")

	var fams_at_end: Array = main.round_end_families[0]
	var fam_total := 0
	for f in fams_at_end:
		fam_total += int(f)
	check(fam_total == 0, "3p round: every family is exhausted at the round end (sum " + str(fam_total)
		+ "), seat 0's 4 family cards are all out of his family: 3 draws + the 2 hits that found"
		+ " an empty family drew none")
	check(main.family_draws[0] == 4 and main.family_draws[1] == 4 and main.family_draws[2] == 4,
		"3p round: family draws per seat " + str(main.family_draws) + " == family size 4 each: the"
		+ " elimination of seat 0 does not make his family drawable by anybody")
	_check_left_end(recs, NOBLE_3P_PRINCE_END_LEFT, "3p")
	_check_pairings(main)
	main.queue_free()
	await await_frames(2)


# The one case the two fixtures above cannot produce: a hit that finds exactly ONE family card. In
# 4p the hits land on turns 4 and 8 and seat 2 draws on turn 7 in between, so his family is 2 then
# 0 at the hits; in the 3p fixture seat 0 is hit on turns 2, 3 (family 3, 2) and 5, 6 (family 0).
# Here seat 2's Princes (turns 3 and 6) sit one turn after seat 1's own draws (turns 2 and 5), so
# the family is 3 at the first hit and 1 at the second: the target consumes his LAST family card and
# stays in the round. A `family.size() >= 2` test in the Prince branch passes every other fixture of
# this suite (the 3p fixture's widow fallback then happens to land at the same play), so THIS round
# is what pins "family first, the whole family, and the widow only when it is really empty".
func _test_prince_last_family_card() -> void:
	var main = _scripted_main(3, NOBLE_3P_PRINCE_LAST, NOBLE_3P_PRINCE_LAST_LEFT)
	await _settle_deal(main)
	check(main._deck._widow_cards.size() == 1 and main._deck._widow.visible,
		"3p fixture 2 setup: widow 1 Guard, family 4 per seat, main pile 0 - the widow is reachable"
		+ " but must stay untouched as long as any family card exists")
	var recs: Array = await _run_to_first_round_end(main)
	_check_effect_log_basics(recs, main)

	check(recs.size() == 7, "3p fixture 2: " + str(recs.size()) + " plays (7 derived: seat 0 plays 3"
		+ " times, seat 1 twice, seat 2 twice, and the 2 Prince hits are plays 3 and 6)")
	var turns: Array = main.round_end_turns[0]
	var turn_total: int = 0
	for t in turns:
		turn_total += int(t)
	check(turn_total == 8 and int(main.round_end_actor[0]) == 1,
		"3p fixture 2: " + str(turn_total) + " turns == 7 plays + 1, ended by seat "
		+ str(main.round_end_actor[0]) + ": seat 1's family hit 0 on turn 6, so turn 8 is the turn"
		+ " start that finds him out of family cards - the family-out rule, not an elimination")

	var prince_plays: Array[int] = []
	for i in recs.size():
		if int(recs[i]["played"]) == Deck.CardType.Prince:
			prince_plays.append(i + 1)
	check(prince_plays == [3, 6], "3p fixture 2: the Prince plays are 3 and 6 " + str(prince_plays)
		+ " - seat 2 plays his first-hand Prince on turn 3 and family[0] on turn 6")
	var targets_ok := true
	for n in prince_plays:
		targets_ok = targets_ok and int(recs[n - 1]["target"]) == 1
	check(targets_ok, "3p fixture 2: both Prince plays target seat 1 - seat 0 is protected by his"
		+ " Handmaids (played on turns 1 and 4), seat 1 never plays one, and the target is the lowest"
		+ " index live unprotected seat")

	var hit1: Dictionary = recs[2]
	check(int(hit1["before"]["fams"][1]) == 3,
		"3p fixture 2 hit 1 (play 3): seat 1's family is 3 (his own draw on turn 2 took the 4th card)"
		+ " -> 3 family cards left, the widow is not in the picture")
	check(int(hit1["after"]["fams"][1]) == 2 and int(hit1["after"]["hands"][1]) == 1
			and int(hit1["after"]["widow"]) == 1 and bool(hit1["after"]["active"][1]),
		"3p fixture 2 hit 1: family draw 3 -> 2, hand back to 1 card, widow still 1, seat 1 in the round")

	var hit2: Dictionary = recs[5]
	check(int(hit2["before"]["fams"][1]) == 1,
		"3p fixture 2 hit 2 (play 6): seat 1's family is exactly 1 (turn 5 was his own last draw) -"
		+ " THE case: the target holds one family card, and it is the last one")
	check(int(hit2["after"]["fams"][1]) == 0 and int(hit2["after"]["hands"][1]) == 1
			and int(hit2["after"]["widow"]) == 1 and bool(hit2["after"]["active"][1]),
		"3p fixture 2 hit 2: the Prince takes the LAST family card (family 1 -> 0), NOT the widow"
		+ " (widow 1 -> 1, hand == 1 card, seat 1 is still in the round) - an empty family is what"
		+ " opens the fallback, not a small family")

	check(main.pile_draws == 0, "3p fixture 2: " + str(main.pile_draws) + " draws from a pile the"
		+ " whole round - the widow sprite stayed visible and its 1 card was never touched")
	check(main.eliminations == 0 and main.eliminated_seats.is_empty(),
		"3p fixture 2: no elimination (" + str(main.eliminated_seats) + ") - every hit found a family"
		+ " card, and the Guard probes all declare Priest against Guard hands")
	check(main.family_draws[0] == 3 and main.family_draws[1] == 4 and main.family_draws[2] == 2,
		"3p fixture 2: family draws per seat " + str(main.family_draws) + " - seat 1's 4 family cards"
		+ " are 2 own draws + 2 hits, seat 0's 3rd draw (turn 7) takes his last family card, seat 2"
		+ " played and drew twice")
	var fams_at_end: Array = main.round_end_families[0]
	check(int(fams_at_end[1]) == 0,
		"3p fixture 2: the seat that ended the round (seat 1) has family 0 - the family-out rule"
		+ " fired on the seat to act, nothing else")
	check(int(fams_at_end[0]) == 1 and int(fams_at_end[2]) == 2,
		"3p fixture 2: the other live seats still hold family cards (" + str(fams_at_end)
		+ " per seat): the round ends on the SEAT TO ACT being out, not on every family being empty")
	_check_left_end(recs, NOBLE_3P_PRINCE_LAST_END_LEFT, "3p fixture 2")
	_check_pairings(main)
	main.queue_free()
	await await_frames(2)


# 2p is the only player count with a main-pile leftover (16 - 3 burn - 2 first-hand - 2 x 5 family
# = 1), and `Deck.pop(true)` pops the main pile before the widow - so the 2p Prince fallback is
# main pile first, widow second. It also shows the consequence: the empty-family window is ONE turn
# (between the draw that empties a family and that seat's own turn-start check), so that single 1-card
# main pile absorbs the round's only empty-family hit and the 3-card widow stays inert.
func _test_prince_2p_mainpile() -> void:
	var main = _scripted_main(2, NOBLE_2P_PRINCE, NOBLE_2P_PRINCE_LEFT)
	await _settle_deal(main)
	var deck: Deck = main._deck
	check(deck._widow_cards.size() == 3 and main._deck._widow.visible,
		"2p setup: burn 3 -> the widow holds 3 cards and is visible")
	var main_pile := 0
	# `_left` is every card not in the discard pile: main pile + widow + every family + every hand
	# (`Deck.discard()` is the only decrement), so the main pile size falls out of the deal
	for n in deck._left.size():
		main_pile += int(deck._left[n])
	main_pile -= deck._widow_cards.size()
	for p in main._players:
		if p.is_active():
			main_pile -= p.family_size()
			main_pile -= p.hand.get_child_count()
	check(main_pile == 1, "2p setup: the main pile keeps 16 - 3 burn - 2 first-hand - 10 family = 1"
		+ " card (computed from the dealt piles: " + str(main_pile) + ") - the only fallback card that"
		+ " sits IN FRONT of the widow")

	var recs: Array = await _run_to_first_round_end(main)
	_check_effect_log_basics(recs, main)

	check(recs.size() == 6, "2p: " + str(recs.size()) + " plays (6 derived: seat 0 plays 3 times"
		+ " (turns 1, 3, 5), seat 1 three times (turns 2, 4, 6), and seats 2/3 are disabled)")
	var turns: Array = main.round_end_turns[0]
	var turn_total: int = 0
	for t in turns:
		turn_total += int(t)
	check(turn_total == 7 and int(main.round_end_actor[0]) == 0,
		"2p: " + str(turn_total) + " turns == 6 plays + 1, ended by seat 0 - seat 0's own draw on turn"
		+ " 5 took his 5th family card (3 own + 2 hits), so turn 7 finds his family empty")

	var prince_plays: Array[int] = []
	for i in recs.size():
		if int(recs[i]["played"]) == Deck.CardType.Prince:
			prince_plays.append(i + 1)
	var all_on_zero := true
	for n in prince_plays:
		all_on_zero = all_on_zero and int(recs[n - 1]["target"]) == 0
	check(prince_plays == [2, 4, 6] and all_on_zero,
		"2p: the Prince plays are 2, 4, 6 " + str(prince_plays) + ", all on seat 0 - seat 1 plays"
		+ " first-hand Prince, then the family[0] / family[1] Princes the previous hit handed him, and"
		+ " seat 0 never plays a Handmaid so he is always the target")

	var hit1: Dictionary = recs[1]
	check(int(hit1["before"]["fams"][0]) == 4 and int(hit1["after"]["fams"][0]) == 3
			and int(hit1["after"]["widow"]) == 3 and int(hit1["after"]["main_pile"]) == 1,
		"2p hit 1 (play 2): family 4 -> 3 (seat 0's own draw on turn 1 took one of his 5 family cards),"
		+ " the widow (3) and the 1-card main pile are untouched")
	var hit2: Dictionary = recs[3]
	check(int(hit2["before"]["fams"][0]) == 2 and int(hit2["after"]["fams"][0]) == 1
			and int(hit2["after"]["widow"]) == 3,
		"2p hit 2 (play 4): family 2 -> 1 (seat 0 drew on turns 1 and 3, so 2 cards were left) - the"
		+ " widow is still untouched, the family still has a card")

	var hit3: Dictionary = recs[5]
	var main_before: int = int(hit3["before"]["main_pile"])
	var main_after: int = int(hit3["after"]["main_pile"])
	check(int(hit3["before"]["fams"][0]) == 0 and main_before == 1 and int(hit3["before"]["widow"]) == 3
			and int(hit3["before"]["on_table"]) == 1,
		"2p hit 3 (play 6): the family is empty, the main pile holds its 1 leftover card, the widow"
		+ " its 3 - the full fallback chain is in play at once (the 1 card the snapshot counts on the"
		+ " table is the played Prince itself, which `discard()` has not counted yet)")
	check(main_after == 0 and int(hit3["after"]["widow"]) == 3 and int(hit3["after"]["hands"][0]) == 1
			and bool(hit3["after"]["active"][0]),
		"2p hit 3: seat 0 drew THE MAIN PILE leftover (main pile 1 -> 0), NOT a widow card (widow"
		+ " 3 -> 3): `Deck.pop(true)` pops the main pile first, so the fallback order is family ->"
		+ " main pile -> widow")
	check(!deck._main.visible, "2p hit 3: the main pile sprite is hidden once its leftover is spent"
		+ " (update_piles() keeps it in sync)")
	check(main.pile_draws == 1, "2p: exactly " + str(main.pile_draws) + " draw from a pile the whole"
		+ " round - the empty-family window is one turn long, so 1 is all a 2p round can produce, and"
		+ " the 1-card main pile absorbs it: in 2p the widow is never drawn")
	check(main.eliminations == 0 and main.eliminated_seats.is_empty(),
		"2p: no elimination (" + str(main.eliminated_seats) + ") - the main pile absorbed the only"
		+ " empty-family hit, so nothing was left undrawable")
	check(main.family_draws[0] == 5 and main.family_draws[1] == 3,
		"2p: family draws per seat " + str(main.family_draws) + " - seat 0's 5 family cards are 3 own"
		+ " draws + 2 hits (the 3rd hit found 0 and drew none), seat 1 draws on his own 3 turns")
	_check_left_end(recs, NOBLE_2P_PRINCE_END_LEFT, "2p")
	_check_pairings(main)
	main.queue_free()
	await await_frames(2)


# Start a whole game on a scripted deal: the fake deck replays the scripted supply through the
# production Noble deal table, and the counting Main records the events a harness cannot poll.
func _scripted_main(count: int, scripted: Array[Deck.CardType], scripted_left: Array[int]):
	var main = MainScene.instantiate()
	var card_scene: PackedScene = main.card_scene  # set_script resets exported vars
	main.set_script(load(CountingMainScript))
	main.card_scene = card_scene
	var deck = main.get_node("Table/Deck")
	deck.set_script(FakeDeckScript)
	deck.scripted = scripted
	deck.scripted_left = scripted_left
	add_child(main)
	main.noble_family = true
	for i in 4:
		main._players[i].ai_level = Player.AI_Level.Level_1 if i < count else Player.AI_Level.Disabled
	return main


# Play the first round of a scripted game and return its effect log (one record per play, in play
# order, recorded around resolve_effect()). The slice stops at the round end, which is appended by
# round_over() BEFORE any later play resolves, so every record belongs to round 1.
func _settle_deal(main) -> void:
	await main.init_players(SEED)
	var fam: int = Deck.NOBLE_FAMILY_SIZE[int(main._player_count)]
	# init_players() does not await the deal coroutine, so poll until the opening deal settled
	await await_until(func() -> bool:
		var ready := true
		for p in main._players:
			if p.is_active():
				ready = ready and p.hand.get_child_count() == 1 and p.family_size() == fam
		return ready)


func _run_to_first_round_end(main) -> Array:
	var slice: Array = []
	for _f in 20000:
		if main.round_end_actor.size() > 0:
			slice = main.effect_log.duplicate(true)
			break
		await get_tree().process_frame
	return slice


# Invariants every play must leave behind: no live seat with 0 or 2 cards, and the exact card
# accounting. In these fixtures every elimination is Prince-caused (the Guard probes all declare
# Priest and no seat ever holds one), so every card that left play is either a played card (1 per
# play) or a Prince target's hand card (1 per Prince play):
#   sum(_left) == 16 - plays - prince_hits
# A non-Prince elimination would add one more decrement (set_inactive discards the victim's hand),
# which is why this formula is asserted on these scripted rounds only, not in the smoke suite.
func _check_effect_log_basics(recs: Array, main) -> void:
	check(recs.size() > 0, "the round recorded " + str(recs.size())
		+ " effect records (resolve_effect runs exactly once per play)")
	var one_card := true
	var offenders: Array = []
	var left_ok := true
	var min_left := true
	var piles_ok := true
	for r in recs:
		var after: Dictionary = r["after"]
		for i in 4:
			if bool(after["active"][i]):
				one_card = one_card and int(after["hands"][i]) == 1
				one_card = one_card and int(after["fams"][i]) >= 0
			elif int(after["hands"][i]) != 0:
				one_card = false
			if int(after["hands"][i]) != 1 and bool(after["active"][i]):
				offenders.append("play " + str(r["plays"]) + " (" + Deck.card_names[int(r["played"])]
						+ " on " + str(r["target"]) + "): live seat " + str(i) + " holds "
						+ str(int(after["hands"][i])) + " cards, family " + str(int(after["fams"][i])))
		var expected: int = TOTAL_CARDS - int(r["plays"]) - int(r["prince_hits"])
		left_ok = left_ok and int(after["left_sum"]) == expected
		for n in after["left"]:
			min_left = min_left and int(n) >= 0
		# the derived main-pile size must never go negative, before or after the effect resolved
		for side in ["before", "after"]:
			var s: Dictionary = r[side]
			piles_ok = piles_ok and int(s["main_pile"]) >= 0 and int(s["widow"]) >= 0
			for n in s["left"]:
				min_left = min_left and int(n) >= 0
	for o in offenders:
		print("  (offender) " + str(o))
	check(one_card, "every play left exactly 1 hand card in every live seat (the invariant the whole"
		+ " Noble Family design rests on, checked at every one of the " + str(recs.size())
		+ " effect boundaries)")
	check(left_ok, "sum(_left) == 16 - plays - Prince plays at EVERY play of the round: cards leave"
		+ " play on a play (1) and on a Prince hit (the target's hand card, 1), and family / widow"
		+ " dealing decrements nothing")
	check(min_left, "no `_left` counter ever went negative, in the BEFORE and the AFTER snapshot"
		+ " (discard()'s assert would have fired)")
	check(piles_ok, "the derived pile sizes (main pile = `_left` total - widow - families - hands -"
		+ " cards on the table) never went negative either - the identity the harness derives them"
		+ " from holds at every snapshot")


func _check_left_end(recs: Array, expected: Array[int], tag: String) -> void:
	var last: Dictionary = recs[recs.size() - 1]["after"]
	var ok := true
	for n in expected.size():
		ok = ok and int(last["left"][n]) == expected[n]
	check(ok, tag + " round end: `_left` == " + str(last["left"]) + ", expected " + str(expected)
		+ " (the scripted supply minus every card that left play)")


func _check_pairings(main) -> void:
	check(main.draws_checked > 0 and main.draw_mismatches.is_empty(),
		"every move named the family card its own play chain drew (" + str(main.draws_checked)
		+ " pairings, " + str(main.draw_mismatches.size()) + " mismatches)")
	_check_left_audit(main, "scripted game")


# Todo step 17 in the scripted fixtures: the CONTINUOUS accounting audit that `CountingMain` runs at
# every turn start, at every pre-decision state, at every decision (the moment the seat commits its
# (draw, play, target) triple) and at both sides of every effect. The per-type identity
#   _left[t] == (supply as dealt for this round) - (cards of type t discarded in it)
# holds at every one of those points (`Deck.pop()` decrements nothing, `Main.discard()` is the only
# decrement, `Deck._build_deck()` resets the supply every round), and with it the two things the
# whole accounting of the variant rests on: a family draw decrements nothing, and an eliminated
# seat's revealed family is discarded exactly once. On the REAL deck the numbers are exact, so a
# violation is a hard failure. A fixture on `FakeDeckScript` is a scripted fiction (`deal_card()`
# decrements `_left.find(true)`, the type with most left, not the type handed out; the supply is an
# arbitrary multiset), so the audit skips there and the fixture keeps its own exact per-type end
# checks written against that shape (`END_LEFT`, `NOBLE_ROUND_END_LEFT`, ...).
func _check_left_audit(main, tag: String = "scripted game") -> void:
	var applies: bool = main.audit_applies()
	check(main.left_audits > 0 or not applies, tag + ": the continuous `_left` audit ran "
		+ str(main.left_audits) + " time(s), " + str(main.left_skips) + " skipped - the accounting is"
		+ " checked at every boundary, not at round ends only")
	if not applies:
		print("INFO  " + tag + ": a `FakeDeckScript` fixture - its `_left` is a hand-written SHAPE, not"
			+ " a counted supply, so the audit skipped. The fixture's own per-type end checks are the"
			+ " accounting gate here")
	var first: Array[String] = []
	for i in mini(4, main.left_violations.size()):
		first.append(str(main.left_violations[i]))
	check(main.left_violations.is_empty(), tag + ": 0 accounting violation(s) over "
		+ str(main.left_audits) + " audit point(s)" + ("" if first.is_empty() else ", first: " + str(first)))
	main.clear_left_violations()


func family_str(p: Player) -> String:
	var s := "["
	for t in p.family:
		s += Deck.card_names[t] + " "
	return s + "]"


func _count_c_play(m: Move, seat: int) -> void:
	_c_plays[seat] += 1


func await_until(cond: Callable, max_frames: int = 4000) -> void:
	for i in max_frames:
		if cond.call():
			return
		await get_tree().process_frame
	print("  (await_until timed out)")


# ----------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------
func check(ok: bool, desc: String) -> void:
	print((("  PASS  " + desc) if ok else ("  FAIL  " + desc)))
	if !ok:
		_failed += 1


func await_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


# ----------------------------------------------------------------------------------------
# TEST E helpers (todo step 16) - the elimination reveal
# ----------------------------------------------------------------------------------------
const BOARD := Rect2(0, 0, 84, 75)  # main.tscn seats sit at (5,31) (5,0) (68,0) (68,31), 21 x 44 seats


func _rn(cards: Array) -> Array:
	# a reveal/discard record's cards, as NAMES, in the order they were materialized
	var out: Array = []
	for c in cards:
		out.append(Deck.card_names[int(c["type"])].strip_edges())
	return out


func _faceups(cards: Array) -> Array:
	var out: Array = []
	for c in cards:
		out.append(bool(c["faceup"]))
	return out


func _xs(cards: Array) -> Array:
	var out: Array = []
	for c in cards:
		out.append(int(c["x"]))
	return out


func _ftypes(family: Array[Deck.CardType]) -> Array:
	var out: Array = []
	for t in family:
		out.append(int(t))
	return out


func _check_reveal(main, tag: String, seat: int, shown: bool, fam_size: int, names: Array,
		xs: Array, origin: Vector2) -> void:
	# What `Main.reveal_out_family()` materialized, read from INSIDE the call (see counting_main):
	# production discards and frees those exact nodes right after it returns, and at `_speed = 0` the
	# whole reveal -> discard -> free chain can settle within a single frame, so nothing outside sees it.
	check(main.reveal_calls == 1 and main.reveal_log.size() == 1, tag + ": the reveal ran exactly once for the"
		+ " round's " + str(main.eliminations) + " elimination(s) (" + str(main.reveal_calls)
		+ " calls) - an empty family is a call that materializes 0 cards, not a skipped call")
	var rec: Dictionary = main.reveal_log[0] if main.reveal_log.size() > 0 else {}
	check(int(rec.get("seat", -99)) == seat, tag + ": the reveal is the out seat's (seat "
		+ str(rec.get("seat", -99)) + " expected " + str(seat) + ")")
	check(bool(rec.get("shown", !shown)) == shown, tag + ": the reveal's `show` == reveal_hand ("
		+ str(rec.get("shown", "?")) + " expected " + str(shown) + ") - reveal_hand gates the FLIP only, a family"
		+ " always leaves play with its owner, so only its visibility is gated")
	var cards: Array = rec.get("cards", [])
	check(int(rec.get("family_size", -1)) == fam_size, tag + ": the reveal materializes the family DATA ("
		+ str(rec.get("family_size", -1)) + " expected " + str(fam_size) + ") - the cards the seat never drew are"
		+ " still in the data, and the card he drew at the turn start is revealed from his HAND, not from the family")
	check(_rn(cards) == names, tag + ": the revealed family cards are the family data in AS-DEALT order ("
		+ str(_rn(cards)) + " expected " + str(names) + ")")
	check(int(rec.get("faceups", -1)) == (names.size() if shown else 0), tag + ": " + str(rec.get("faceups", -1))
		+ " of " + str(names.size()) + " revealed cards ended face-up, expected "
		+ str(names.size() if shown else 0) + " - face-down when reveal_hand is false")
	check(str(rec.get("container", "")) == "Family", tag + ": the revealed cards sit in ONE container named"
		+ " Family - the seat's own $Family stack node (step 18), not a throwaway (" + str(rec.get("container", ""))
		+ ") - the 44 px seat has room for a 3-card cascade below the badge row, the hand row has not (it holds 2"
		+ " cards at decision time)")
	check(bool(rec.get("parent_is_seat")), tag + ": the container is a CHILD OF THE SEAT, so the stack follows the"
		+ " seat's position, its scale and its fade (a seat fades at 0.6, a card only at 0.3)")
	check(rec.get("pos") == origin, tag + ": the stack starts at the seat-local " + str(origin) + " (recorded "
		+ str(rec.get("pos")) + ") - the seat's own top-left corner is on the badge (y -23) and the score (x 11), so"
		+ " the stack starts below the badge, where the card row sits")
	var seat_y: int = int(main._players[seat].global_position.y)
	var cont_y: int = int(rec.get("pos", Vector2(-1, -1)).y)
	var cascade_ok := true
	for i in cards.size():
		cascade_ok = cascade_ok and bool(cards[i]["in_container"])
		cascade_ok = cascade_ok and int(cards[i]["global_y"]) == seat_y + cont_y
	check(cascade_ok, tag + ": every revealed card is INSIDE the container, at the container's own y - a stack is not"
		+ " a row: a container that ignores its children's position renders nothing")
	check(_xs(cards) == xs, tag + ": the cascade steps by " + str(Main.FAMILY_CASCADE_STEP) + " px and MIRRORS on the"
		+ " right-handed seats (" + str(_xs(cards)) + " expected " + str(xs) + ") - x 26 + 9*i ends at 61 + the 11 px"
		+ " card on a seat at x 68, off the 84 px board, and the mirrored x -11 - 18 - 11 reaches -4 on a seat at x 5")
	var on_board := true
	for c in cards:
		on_board = on_board and int(c["global_x"]) >= int(BOARD.position.x) \
			and int(c["global_x"]) + 11 <= int(BOARD.position.x) + int(BOARD.size.x) \
			and int(c["global_y"]) >= int(BOARD.position.y) \
			and int(c["global_y"]) + 17 <= int(BOARD.position.y) + int(BOARD.size.y)
	check(on_board, tag + ": every revealed card is fully INSIDE the " + str(BOARD.size) + " play area - 9 px is the"
		+ " biggest cascade step that fits 3 cards on a 44 px tall seat")
	check(int(rec.get("input_connections", -1)) == 0, tag + ": the revealed cards connect NO input_event ("
		+ str(rec.get("input_connections", -1)) + ") - the Card scene's Area2D fills the whole 11 x 17 rect, so"
		+ " connected cards would steal the tap from the hand behind them (the human's own turn starts 1 frame later"
		+ " and the tap chain is 600 ms per tap)")


func _check_family_discard(main, tag: String, names: Array, faceup: bool, hand_names: Array) -> void:
	# The revealed cards must leave play through the ONE path that decrements `_left`.
	var idx: int = -1
	for i in main.discard_log.size():
		if str(main.discard_log[i]["container"]) == "Family":
			idx = i
			break
	check(idx >= 0, tag + ": the revealed family left play through `Main.discard()` (" + str(main.discard_log.size())
		+ " discard() calls recorded, none on the stack container) - only `discard()` decrements `_left`, so a family"
		+ " that leaves any other way is invisible to the supply")
	if idx < 0:
		return
	var rec: Dictionary = main.discard_log[idx]
	check(_rn(rec["cards"]) == names, tag + ": the discarded family cards are exactly the revealed ones ("
		+ str(_rn(rec["cards"])) + " expected " + str(names) + ")")
	var want: Array = []
	for i in names.size():
		want.append(faceup)
	check(_faceups(rec["cards"]) == want, tag + ": the family is discarded " + ("face-UP" if faceup else "face-DOWN")
		+ " (" + str(_faceups(rec["cards"])) + " expected " + str(want) + ") - the same gate as the hand:"
		+ " `hide_afterwards` already flips a compared card back face-down, `reveal_hand` is the variant gate")
	check(idx + 1 < main.discard_log.size(), tag + ": a hand discard is recorded after the family discard")
	# find the out seat's hand discard: `discard()` is a coroutine and its calls OVERLAP (a played card
	# leaves the table by animation, so a call finishes when its animation finishes, not when it starts),
	# so the records are in COMPLETION order, not in call order
	var hand_idx: int = -1
	for i in range(idx + 1, main.discard_log.size()):
		if str(main.discard_log[i]["container"]) == "Hand":
			hand_idx = i
			break
	if hand_idx >= 0:
		var nxt: Dictionary = main.discard_log[hand_idx]
		# the hand has its own card count, so the face-up expectation is per hand card
		var hand_want: Array = []
		for i in hand_names.size():
			hand_want.append(faceup)
		check(str(nxt["container"]) == "Hand" and _rn(nxt["cards"]) == hand_names
			and _faceups(nxt["cards"]) == hand_want, tag + ": the out seat's hand card(s) leave the same way ("
			+ str(nxt["container"]) + " " + str(_rn(nxt["cards"])) + " " + str(_faceups(nxt["cards"]))
			+ " expected Hand " + str(hand_names) + " " + str(hand_want) + ")")


func _check_left_drop(recs: Array, play_no: int, tag: String, expected_after: Array, drop: Array) -> void:
	var b: Array = recs[play_no - 1]["before"]["left"]
	var a: Array = recs[play_no - 1]["after"]["left"]
	var got_drop: Array = []
	for i in expected_after.size():
		got_drop.append(int(b[i]) - int(a[i]))
	check(got_drop == drop, tag + ": `_left` dropped by EXACTLY the played card + the revealed hand + family cards ("
		+ str(got_drop) + " expected " + str(drop) + ") - a Guard kill moves 5 cards out of the supply and 4 of them"
		+ " are revealed, so an uncounted family shows up right here")
	var sum: int = 0
	for i in a.size():
		sum += int(a[i])
	check(int(recs[play_no - 1]["after"]["left_sum"]) == sum, tag + ": the recorded `_left` sum is the elementwise sum"
		+ " (" + str(recs[play_no - 1]["after"]["left_sum"]) + " vs " + str(sum) + ") - the sum is all the classic"
		+ " 16 - plays - princes rule ever reads, so the elementwise view is the variant's only probe")
	check(a == expected_after, tag + ": `_left` after play " + str(play_no) + " == " + str(expected_after) + " ("
		+ str(a) + ") - the family is invisible to the classic rule, so the variant's number is exactly this many"
		+ " plays + reveals out of 16")


func _check_discard_totals(main, tag: String, scripted_left: Array, expected: Array) -> void:
	# The ONLY way to prove a card is counted EXACTLY once: `discarded` counts every card that left play through
	# `discard()`, and `scripted - _left` is what the game BELIEVES left play.
	var got: Array = []
	for i in main.discarded.size():
		got.append(main.discarded[i])
	var want: Array = []
	for i in scripted_left.size():
		want.append(int(scripted_left[i]) - int(expected[i]))
	check(got == want, tag + ": every card left play EXACTLY ONCE - discard() moved " + str(got)
		+ " cards per type, the supply says " + str(want) + " (scripted " + str(scripted_left) + " minus `_left` "
		+ str(expected) + ") - `_left` alone cannot show a double decrement: a family counted twice and a family"
		+ " counted zero times can add up to the same total")
	check(main.round_end_left.size() > 0, tag + ": round_over() snapshotted `_left` - the re-deal overwrites"
		+ " `_deck._left` 1-2 frames after the round end at `_speed = 0`, so a live read is not the round-end state")


func _check_round_end(recs: Array, main, tag: String, turn_counts: Array, actor: int, elims: Array,
		hand_sizes: Array, family_sizes: Array, end_left: Array) -> void:
	var end: Dictionary = recs[recs.size() - 1]["after"]
	var plays: int = recs.size()
	var end_actor: int = -1  # the seat whose turn start ended the round, -1 when the round never ended
	if main.round_end_actor.size() > 0:
		end_actor = main.round_end_actor[0]
	var got_hands: Array = []
	var got_fams: Array = []
	for p in main._players:
		got_hands.append(p.hand.get_child_count())
		got_fams.append(p.family_size())
	var turns: int = 0
	if main.round_end_turns.size() > 0:
		for n in main.round_end_turns[0]:
			turns += int(n)
	check(main.round_end_turns.size() > 0 and main.round_end_turns[0] == turn_counts, tag
		+ ": turns per seat are " + str(turn_counts) + " (" + str(main.round_end_turns[0])
		+ ") - every live seat takes exactly one turn per family card he draws, an eliminated seat stops taking"
		+ " turns, and the LAST turn of the round is the empty-family turn-start that ends it")
	check(turns == plays + 1, tag + ": " + str(turns) + " turns == " + str(plays)
		+ " plays + 1 (the ending turn-start draws nothing, so it is not a play)")
	check(int(end["left_sum"]) >= 0, tag + ": the round-end `_left` is a real number")
	check(end_actor == actor, tag + ": the round ends at seat " + str(actor) + "'s turn start (" + str(end_actor)
		+ ") - the family-empty check runs at the turn start, not after the last play")
	check(main.eliminations == elims.size() and main.eliminated_seats == elims, tag
		+ ": eliminations are " + str(elims) + " (" + str(main.eliminated_seats) + ") - a revealed card resolves NO"
		+ " effect, so the reveal adds none: a revealed Guard never matches a declared Priest")
	check(main.pile_draws == 0, tag + ": no Prince was played (" + str(main.pile_draws)
		+ " pile draws) - the reveal never triggers a draw")
	check(got_hands == hand_sizes, tag + ": the out seat's hand is empty, every live seat holds 1 card ("
		+ str(got_hands) + " expected " + str(hand_sizes) + ") - an out seat leaves with nothing in his hand AND no"
		+ " family")
	check(got_fams == family_sizes, tag + ": every family is empty at the round end (" + str(got_fams)
		+ " expected " + str(family_sizes) + ") - the live seats drew all their cards and the out seat's family DATA"
		+ " was cleared the moment he left, so a round-end snapshot never shows a dead seat holding family")
	check(main.round_end_left.size() > 0, tag + ": round_over() snapshotted `_left` for the round end")
	if main.round_end_left.size() > 0:
		var l: Array = main.round_end_left[0]
		var ls: int = 0
		for i in l.size():
			ls += int(l[i])
		var want: int = 0
		for i in end_left.size():
			want += int(end_left[i])
		check(l == end_left, tag + ": `_left` at the round end == " + str(end_left) + " (" + str(l) + ") - "
			+ str(16 - want) + " cards left play: " + str(plays) + " plays + the revealed hand + family")
		check(ls == want, tag + ": the round-end `_left` sums to " + str(want) + " (" + str(ls) + ") - " + str(plays)
			+ " plays + reveals out of 16, the classic rule's shape with the reveals added")


func _check_no_family_leak(main, tag: String) -> void:
	# Step 18: the stack is the seat's OWN scene node, so it SURVIVES the reveal by design - what must
	# not survive is a CARD in it. A revealed family that stayed rendered is a ghost family: it shows
	# cards that are already in the discard pile, and it hides the next round's re-deal.
	var leaked: String = ""
	for p in main._players:
		for ch in p.family_root.get_children():
			if ch is Card:
				leaked += " seat " + str(p.idx) + "=" + Deck.card_names[int(ch.type)].strip_edges()
	check(leaked.is_empty(), tag + ": no family card survives the round in any seat's stack (" + leaked + ") - the"
		+ " reveal discards the stack's cards through `discard()` and `clear_family()` drops the data, so a"
		+ " stack renders exactly `family_size()` cards and never more")
	var stacks: int = 0
	for p in main._players:
		stacks += 1 if p.family_root.get_parent() == p else 0
	check(stacks == 4, tag + ": every seat owns exactly ONE $Family node as its own child (" + str(stacks)
		+ " of 4) - one stack per seat, the human's menu and the reveal surface, so a reveal never needs a"
		+ " throwaway container that a later round would have to clean up")
	# todo step 17: the same continuous accounting audit the scripted C/D fixtures get via
	# `_check_pairings`; the E fixtures (seats eliminated mid-chain) are exactly where a double
	# decrement of the revealed hand + family would show up, and the audit ran on both sides of every
	# effect of these games
	_check_left_audit(main, tag)


func _check_e_basics(recs: Array, main, tag: String) -> void:
	# The invariants every variant round must keep on EVERY recorded play. The classic
	# `sum(_left) == 16 - plays - prince_hits` is NOT asserted here: these rounds eliminate seats that
	# are not Prince victims, and a non-Prince elimination discards a hand AND a family, so the classic
	# formula has no term for what leaves. The elementwise `_left` checks below are the variant's probe.
	check(recs.size() > 0, tag + ": the round recorded " + str(recs.size())
		+ " effect records (resolve_effect runs exactly once per play)")
	var one_card := true
	var neg_ok := true
	var fam_ok := true
	for r in recs:
		var after: Dictionary = r["after"]
		for i in 4:
			if bool(after["active"][i]):
				one_card = one_card and int(after["hands"][i]) == 1
			else:
				one_card = one_card and int(after["hands"][i]) == 0
			# the out seat's family is cleared ON THE SPOT (step 16), so an inactive seat never keeps family
			fam_ok = fam_ok and (int(after["fams"][i]) == 0 if !bool(after["active"][i]) else int(after["fams"][i]) >= 0)
		for side in ["before", "after"]:
			for n in r[side]["left"]:
				neg_ok = neg_ok and int(n) >= 0
			neg_ok = neg_ok and int(r[side]["main_pile"]) >= 0
	check(one_card, tag + ": after every play every LIVE seat holds EXACTLY 1 card and an out seat holds 0 - the"
		+ " variant's `the leftover is the active card` invariant, checked at all " + str(recs.size())
		+ " effect boundaries")
	check(fam_ok, tag + ": no inactive seat ever holds family cards - the family leaves play WITH its owner, in the"
		+ " same `set_inactive()` that discards his hand")
	check(neg_ok, tag + ": no `_left` count and no derived main pile ever went negative - a double decrement drives a"
		+ " count below the cards that exist, which is how a family counted twice shows up")


# Step 20: a human turn start STOPS at the modal. `new_turn()` no longer hands the seat a family
# card - it opens the panel and awaits the tap - so a harness that drives the human seat has to TAP,
# or every human turn stalls at the modal (measured: `await_until timed out`, and the whole fixture's
# assertions cascade from a seat that never got his card). The tap is the synthetic `input_event`
# TEST G fires, so the harness taps the SAME Area2D a finger taps in a real run.
#
# Returns true when it took a draw. A human turn start with an EMPTY family never opens a panel (the
# round ends there), and a seat that is already in his play selection has already drawn - both cases
# must return, not stall: 4p burns nothing, so a 3-card family runs out on the 4th turn start and the
# last human turn is a round end, not a draw.
func _human_draw(main, idx: int, max_frames: int = 2000) -> bool:
	var sel = main._family_selector
	var p = main._players[0]
	for i in max_frames:
		if sel.is_open():
			var cards: Array = _fs_cards(sel)
			if idx >= 0 and idx < cards.size():
				_fs_tap(cards[idx]["node"])
			await await_until(func() -> bool: return !sel.is_open())
			return true
		if p._state == Player.State.SELECT_CARD and p.hand.get_child_count() == 2:
			return false  # no draw to take: the seat is already choosing his play
		await get_tree().process_frame
	return false


# The human seat 0 plays by tapping: `_on_card_played` is what Player emits on a card tap, and
# `_on_target_player_selected` / `_on_target_type_selected` are what the target / type selectors emit.
# The seat always plays his ACTIVE card (hand[0]) - the variant's real decision is which card to KEEP.
# `draw_idx` is the family card he CHOOSES at turn start (step 20: the modal tap); a self-target play
# (Handmaid / Countess) never opens a target selector, so the target step is state-gated.
func _human_play(main, target: int, type: Deck.CardType, draw_idx: int = 0) -> void:
	var p = main._players[0]
	await _human_draw(main, draw_idx)
	await await_until(func() -> bool:
		return p._state == Player.State.SELECT_CARD and p.hand.get_child_count() == 2)
	await main._on_card_played(p.hand.get_child(0))
	if p._state == Player.State.INPUT_OTHER_P or p._state == Player.State.INPUT_ANY_P:
		await await_until(func() -> bool:
			return p._state == Player.State.INPUT_OTHER_P)
		await main._on_target_player_selected(target)
		if p._state == Player.State.INPUT_T:
			await main._on_target_type_selected(type)
	await await_until(func() -> bool:
		return main._cur_player != 0)


func _settle_deal_human(main, w: Dictionary = {}) -> void:
	# `_settle_deal()` polls for "1 hand card + a full family" in every seat, which the HUMAN seat can
	# never satisfy: his turn start opens the family modal (step 20) and waits for a tap, so he is
	# settled at 2 cards with ONE family card drawn - the harness taps index 0, the as-dealt card the
	# scripted fixtures were written against. A caller that wants the panel WATCHED from the FIRST turn
	# start passes the watcher dict, so it starts before that first tap.
	await main.init_players(SEED)
	if not w.is_empty():
		_watch_modal(main, w)
	await _human_draw(main, 0)
	var fam: int = Deck.NOBLE_FAMILY_SIZE[int(main._player_count)]
	await await_until(func() -> bool:
		var ready := true
		for p in main._players:
			if p.is_active() and p.idx > 0:
				ready = ready and p.hand.get_child_count() == 1 and p.family_size() == fam
		return ready and main._players[0].hand.get_child_count() == 2 \
			and main._players[0].family_size() == fam - 1)


func _scripted_main_human(count: int, scripted: Array[Deck.CardType], scripted_left: Array[int]):
	var main = _scripted_main(count, scripted, scripted_left)
	# `init_players()` asserts that every seat but 0 is NOT human, so the variant's human seat is set
	# after the seats are built. The todo's UI phase puts the human at seat 0, so this is also the shape
	# the real menu runs - a human seat is the ONLY way to reach `reveal_hand == false` on a Baron win.
	main._players[0].ai_level = Player.AI_Level.Human
	return main


# ----------------------------------------------------------------------------------------
# TEST E (todo step 16): the elimination reveal
#
# The rule: an out seat reveals his hand AND his private family, the revealed cards move to the discard
# pile, they resolve NO effects, and every one of them is counted in `_left` exactly once. Step 16 is a
# PRODUCTION change, not a test-only one: the family data is cleared the moment its owner leaves, so the
# round-end snapshot and the next round's re-deal both see a consistent world.
# ----------------------------------------------------------------------------------------
func _test_elimination_reveal() -> void:
	print("--- TEST E1 (4p Guard kill: the victim never played, so his WHOLE family is revealed) ---")
	await _test_elim_guard_reveal()
	print("--- TEST E2 (4p Princess self-kill: the reveal is the family MINUS the card he drew) ---")
	await _test_elim_princess_reveal()
	print("--- TEST E3 (4p, human WINS a Baron: reveal_hand false, the family leaves play face-DOWN) ---")
	await _test_elim_baron_hidden()


func _test_elim_guard_reveal() -> void:
	var main = _scripted_main(4, NOBLE_4P_GUARD_KILL, NOBLE_4P_GUARD_KILL_LEFT)
	await _settle_deal(main)
	var seat1_family: Array = _ftypes(main._players[1].family)
	var recs: Array = await _run_to_first_round_end(main)
	var tag := "E1"
	_check_e_basics(recs, main, tag)
	_check_no_family_leak(main, tag)

	check(seat1_family == _ftypes(NOBLE_4P_GUARD_KILL_SEAT1_FAMILY), tag + ": seat 1's family is dealt as"
		+ " [Baron, King, Countess] (" + str(seat1_family) + ") - 3 DISTINCT types, so the reveal's `_left` drop is"
		+ " unambiguous. A 4p family is 3 cards and Guards are 12 of 16, so 3 Guards per seat is a legal supply")
	check(int(recs[0]["played"]) == int(Deck.CardType.Guard) and int(recs[0]["target"]) == 1
		and int(recs[0]["target_type"]) == int(Deck.CardType.Priest), tag + ": play 1 is seat 0's level-1 move ("
		+ Deck.card_names[int(recs[0]["played"])].strip_edges() + " on seat " + str(recs[0]["target"]) + " declared "
		+ Deck.card_names[int(recs[0]["target_type"])].strip_edges() + ") - level 1 plays valid_moves[0], the lowest"
		+ " index live opponent, and the declared-type loop starts at Priest. Seat 1's FIRST-HAND card is the Priest")
	check(int(recs[0]["after"]["left_sum"]) == 11, tag + ": play 1 eliminates seat 1 (" + str(main.eliminations)
		+ " elimination, seat " + str(main.eliminated_seats[0]) + ") - the victim never played, so NOTHING of his"
		+ " family was ever drawn, and 16 - 1 play - 4 revealed cards = 11")

	_check_reveal(main, tag, 1, true, 3, ["Baron", "King", "Countess"], [0, 9, 18], Main.FAMILY_STACK_ORIGIN)
	_check_family_discard(main, tag, ["Baron", "King", "Countess"], true, ["Priest"])
	_check_left_drop(recs, 1, tag, NOBLE_4P_GUARD_KILL_AFTER1, NOBLE_4P_GUARD_KILL_DROP)
	_check_round_end(recs, main, tag, [4, 0, 3, 3], 0, [1], [1, 0, 1, 1], [0, 0, 0, 0],
		NOBLE_4P_GUARD_KILL_END_LEFT)
	_check_discard_totals(main, tag, NOBLE_4P_GUARD_KILL_LEFT, NOBLE_4P_GUARD_KILL_END_LEFT)
	# Free the fixture: a scripted `Main` keeps playing rounds on its own, and a running fixture prints
	# its turns into this log AND shares the `Animator` singleton with the next fixture.
	main.queue_free()
	await await_frames(2)


func _test_elim_princess_reveal() -> void:
	var main = _scripted_main(4, NOBLE_4P_PRINCESS_KILL, NOBLE_4P_PRINCESS_KILL_LEFT)
	await _settle_deal(main)
	var seat2_family: Array = _ftypes(main._players[2].family)
	var recs: Array = await _run_to_first_round_end(main)
	var tag := "E2"
	_check_e_basics(recs, main, tag)
	_check_no_family_leak(main, tag)

	check(seat2_family == _ftypes(NOBLE_4P_PRINCESS_KILL_SEAT2_FAMILY), tag + ": seat 2's family is dealt as"
		+ " [Baron, King, Countess] (" + str(seat2_family) + ")")
	check(int(recs[2]["played"]) == int(Deck.CardType.Princess) and int(recs[2]["target"]) == -1, tag
		+ ": play 3 (turn 3, seat 2's FIRST play) is the ACTIVE Princess on HIMSELF (target " + str(recs[2]["target"])
		+ " = -1, the self-play index) - seat 2 drew family[0] = Baron, so the Princess is his active card, which is"
		+ " what a level-1 seat plays with the 1 forced -1 (self) left")
	check(main.eliminations == 1 and main.eliminated_seats[0] == 2, tag + ": play 3 eliminates seat 2 ("
		+ str(main.eliminated_seats) + ") - a Princess play discards its own player")

	# THE step-16 number: the family leaves play WITH its owner, minus the card he drew for that play
	_check_reveal(main, tag, 2, true, 2, ["King", "Countess"], [0, -9], Main.FAMILY_STACK_MIRROR)
	_check_family_discard(main, tag, ["King", "Countess"], true, ["Baron"])
	_check_left_drop(recs, 3, tag, NOBLE_4P_PRINCESS_KILL_AFTER3, NOBLE_4P_PRINCESS_KILL_DROP)
	_check_round_end(recs, main, tag, [4, 3, 1, 3], 0, [2], [1, 1, 0, 1], [0, 0, 0, 0],
		NOBLE_4P_PRINCESS_KILL_END_LEFT)
	_check_discard_totals(main, tag, NOBLE_4P_PRINCESS_KILL_LEFT, NOBLE_4P_PRINCESS_KILL_END_LEFT)

	var fam_drawn: Array = []
	for i in main.family_draws.size():
		fam_drawn.append(main.family_draws[i])
	check(fam_drawn[2] == 1, tag + ": seat 2 drew EXACTLY 1 family card (" + str(fam_drawn[2])
		+ ") - his family was 3, the reveal is 2 and the drawn card sits in his hand: 3 = 2 + 1, so no card is"
		+ " counted twice and no card is lost. The classic 16 - plays - princes rule has NO term for a family")
	check(fam_drawn[1] == 3, tag + ": a seat that stayed live drew all 3 family cards (" + str(fam_drawn[1])
		+ ") - an eliminated seat stops drawing together with his family, so his undrawn cards leave play with him")
	main.queue_free()
	await await_frames(2)


func _test_elim_baron_hidden() -> void:
	var main = _scripted_main_human(4, NOBLE_4P_BARON_HUMAN, NOBLE_4P_BARON_HUMAN_LEFT)
	await _settle_deal_human(main)
	var tag := "E3"
	var seat1_family: Array = _ftypes(main._players[1].family)
	check(main._players[0].is_human(), tag + ": seat 0 is human - the variant's menu seat - so a WON Baron runs the"
		+ " classic `reveal_hand == false` branch (`set_inactive(tp, !p.is_human())`)")
	check(seat1_family == _ftypes(NOBLE_4P_BARON_HUMAN_SEAT1_FAMILY), tag + ": seat 1's family is dealt as"
		+ " [King, Countess, Princess] (" + str(seat1_family) + ") - 4 distinct types in the reveal, so the `_left`"
		+ " drop pins the reveal even when nothing is face-up")

	# the human plays his 3 cards by tapping: Baron on seat 1, then the King, then a Guard (declared Priest)
	await _human_play(main, 1, Deck.CardType.Priest)
	var play1: Dictionary = main.effect_log[0]
	var active_after_play1: int = int(main._players[0].hand.get_child(0).type)
	await _human_play(main, 2, Deck.CardType.Priest)
	await _human_play(main, 2, Deck.CardType.Priest)
	# the human's last play is mid-round: the seats behind him keep playing, and the round ends at the
	# turn start that finds an empty family - settle it before asserting the round-end state
	var settle: int = 0
	while main.round_end_actor.size() == 0 and settle < 400:
		await get_tree().process_frame
		settle += 1
	var recs: Array = main.effect_log.duplicate(true)
	_check_e_basics(recs, main, tag)
	_check_no_family_leak(main, tag)

	check(int(play1["played"]) == int(Deck.CardType.Baron) and int(play1["target"]) == 1, tag
		+ ": the human's play 1 is the Baron on seat 1 (" + Deck.card_names[int(play1["played"])].strip_edges()
		+ " -> seat " + str(play1["target"]) + ")")
	check(int(play1["target_type"]) == int(Deck.CardType.Unknown), tag + ": a Baron declares NO type ("
		+ Deck.card_names[int(play1["target_type"])].strip_edges() + ") - `_target_type` belongs to the Guard, so a"
		+ " Baron play must leave it untouched")
	check(active_after_play1 == int(Deck.CardType.King), tag + ": the human's ACTIVE card after play 1 is the King from"
		+ " family[0] (" + Deck.card_names[active_after_play1].strip_edges() + ") - the variant draws a family card"
		+ " FIRST, so the Baron is the played card and the King is the card the Baron compares (`the leftover is the"
		+ " active card`)")
	check(int(play1["after"]["left_sum"]) == 11, tag + ": King 6 > Priest 2, so seat 1 is eliminated ("
		+ str(main.eliminations) + " elimination) - 16 - 1 played Baron - 4 revealed (Priest + 3 family) = 11")

	# reveal_hand == false: the family is materialized FACE-DOWN and discarded FACE-DOWN
	_check_reveal(main, tag, 1, false, 3, ["King", "Countess", "Princess"], [0, 9, 18], Main.FAMILY_STACK_ORIGIN)
	_check_family_discard(main, tag, ["King", "Countess", "Princess"], false, ["Priest"])
	_check_left_drop(recs, 1, tag, NOBLE_4P_BARON_HUMAN_AFTER1, NOBLE_4P_BARON_HUMAN_DROP)
	_check_round_end(recs, main, tag, [4, 0, 3, 3], 0, [1], [1, 0, 1, 1], [0, 0, 0, 0],
		NOBLE_4P_BARON_HUMAN_END_LEFT)
	_check_discard_totals(main, tag, NOBLE_4P_BARON_HUMAN_LEFT, NOBLE_4P_BARON_HUMAN_END_LEFT)
	main.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# TEST F (todo step 18): the family stack - a private, display-only cascade in the seat's own node
#
# The rule the gate asks for is "look at your noble family at any time", with NO extra widget: the
# family is rendered as 1 Card node per family card, in the seat's own `$Family` node, cascading by
# 9 px in the seat's free bottom strip. Four things are pinned here, because every one of them is a
# rule a later step depends on:
#   1. ORDER - the stack is `family` in as-dealt order, never sorted, rebuilt (not appended) on every
#      change, so the top-left card is always the family card the seat would draw next.
#   2. VISIBILITY - a family is PRIVATE: the human seat renders, an AI seat renders NOTHING (his
#      family is data only). `force` is the elimination reveal, the one moment a family becomes public.
#   3. GEOMETRY - one node per card at 9 px, mirrored on the `right_score` seats, fully inside the
#      84 x 48 viewport, in the strip to the RIGHT of the 2 hand cards (they never overlap).
#   4. NO INPUT - the stack cards connect no `input_event`: Card's Area2D covers the whole 11 x 17
#      rect, so a connected stack card would steal the hand's tap.
# ----------------------------------------------------------------------------------------
const VIEWPORT := Rect2(0, 0, 84, 48)  # 672 x 384 window at window scale 8


func _test_family_stack() -> void:
	print("--- TEST F1 (unit): render_family() - order, cascade, mirror, visibility, clearing ---")
	await _test_stack_unit()
	print("--- TEST F2 (2p, family 5): the human's stack IS his family, 5 cards inside 84x48, AI shows nothing ---")
	await _test_stack_2p()
	print("--- TEST F3 (4p, family 3): the stack follows every draw; an out seat's stack leaves with him ---")
	await _test_stack_4p()


func _stack_nodes(p: Player) -> Array:
	# the live stack, in tree order == cascade order == family order
	var out: Array = []
	for ch in p.family_root.get_children():
		if ch is Card:
			out.append({
				"type": int(ch.type),
				"faceup": bool(ch.faceup),
				"x": int(ch.position.x),
				"global_x": int(ch.global_position.x),
				"global_y": int(ch.global_position.y),
				"conns": int(ch.input_event.get_connections().size()),
			})
	return out


func _rects(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		out.append("[" + str(int(n["global_x"])) + "," + str(int(n["global_y"])) + "]-"
			+ "[" + str(int(n["global_x"]) + 11) + "," + str(int(n["global_y"]) + 17) + "]")
	return out


# The whole stack contract, readable from any Player (a unit probe, a live seat, an out seat).
func _check_stack_p(tag: String, p: Player, names: Array, xs: Array, faceup: bool = true) -> void:
	var nodes: Array = _stack_nodes(p)
	check(p.family_root.get_parent() == p and str(p.family_root.name) == "Family", tag + ": seat "
		+ str(p.idx) + "'s stack is his OWN $Family child (" + str(p.family_root.get_parent())
		+ ") - the stack is part of the seat, so it follows the seat's position, its scale and its fade")
	check(int(p.family_root.get_child_count()) == p.family_size(), tag + ": seat " + str(p.idx)
		+ " renders EXACTLY one node per family card (" + str(p.family_root.get_child_count())
		+ " nodes, family " + str(p.family_size()) + ") - the stack is a VIEW of the data: a rebuild that"
		+ " appends would grow a ghost card every draw, a rebuild that forgets one hides a card the seat owns")
	check(_rn(nodes) == names, tag + ": seat " + str(p.idx) + "'s stack is his family in AS-DEALT order ("
		+ str(_rn(nodes)) + " expected " + str(names) + ") - never sorted: the order is the level 1"
		+ " determinism and the Prince's `family[0]` draw")
	check(_xs(nodes) == xs, tag + ": the cascade is x " + str(xs) + " (" + str(_xs(nodes))
		+ ") - 9 px steps leave 2 px visible slivers on 11 px cards")
	var ups := true
	var conns := 0
	for n in nodes:
		ups = ups and bool(n["faceup"]) == faceup
		conns += int(n["conns"])
	check(ups, tag + ": every stack card is face-" + ("UP" if faceup else "DOWN") + " ("
		+ str(_faceups(nodes)) + ") - the human reads his own family, a reveal is face-DOWN when the hand"
		+ " is not published")
	check(conns == 0, tag + ": the stack connects NO input_event (" + str(conns)
		+ ") - a stack card covers a full 11 x 17 Area2D, so a connected one would steal the hand's tap")
	var inside := true
	for n in nodes:
		inside = inside and int(n["global_x"]) >= int(VIEWPORT.position.x) \
			and int(n["global_x"]) + 11 <= int(VIEWPORT.position.x) + int(VIEWPORT.size.x) \
			and int(n["global_y"]) >= int(VIEWPORT.position.y) \
			and int(n["global_y"]) + 17 <= int(VIEWPORT.position.y) + int(VIEWPORT.size.y)
	check(inside, tag + ": every stack card is fully INSIDE the " + str(VIEWPORT.size)
		+ " viewport (" + str(_rects(nodes)) + ") - a family stack may not need a scroll, a zoom or a widget")


# F1: the rendering contract on bare seats - no game loop, so every branch of `render_family()` is
# reached directly (a live game only ever exercises the human branch + the reveal branch).
func _test_stack_unit() -> void:
	var tag := "F1"
	# `add_child` FIRST: `Player.ai_level`'s setter touches `_badge` / `_score_digit`, which are
	# `@onready` children, so setting it on a seat that is not in the tree yet writes to Nil nodes
	# (a script error, and the badge/score visibility the setter applies is silently lost).
	var p = PlayerScene.instantiate()
	add_child(p)
	p.ai_level = Player.AI_Level.Human
	await await_frames(1)
	p.position = Vector2(5, 31)  # seat 0 on the real board
	var pr = PlayerScene.instantiate()
	pr.right_score = true  # BEFORE `add_child`: `Player._ready()` mirrors the stack off `right_score`
	add_child(pr)
	pr.ai_level = Player.AI_Level.Human
	await await_frames(1)
	pr.position = Vector2(68, 31)  # seat 3 on the real board (x 68, right-handed)
	var ai = PlayerScene.instantiate()
	ai.right_score = true  # a right-handed seat, x 68 - the stack must mirror onto the board, so it
	add_child(ai)  # has to be set before `_ready()` reads it
	ai.ai_level = Player.AI_Level.Level_3
	await await_frames(1)
	ai.position = Vector2(68, 0)

	check(p.family_root.position == Player.FAMILY_STACK_ORIGIN and int(p.family_root.position.x) == 26, tag
		+ ": the stack starts at seat-local (26, 0) = global (31, 31) on seat 0 - right of his 2 hand cards"
		+ " (x 0..24), in the free bottom strip, below the badge row and the score label")
	check(pr.family_root.position == Player.FAMILY_STACK_MIRROR, tag + ": a `right_score` seat's stack starts at ("
		+ str(pr.family_root.position) + ") == FAMILY_STACK_MIRROR - the seat sits at x 68, so the stack grows LEFT"
		+ " (its `_ready()` mirrors it, the cascade step is negated)")
	check(pr.family_cascade_step() == -Player.FAMILY_CASCADE_STEP, tag + ": the cascade mirrors too ("
		+ str(pr.family_cascade_step()) + ") - a mirrored origin with a right-growing cascade walks off the board")
	check(int(p.family_root.get_child_count()) == 0, tag + ": a seat with no family renders an EMPTY stack ("
		+ str(p.family_root.get_child_count()) + " nodes) - the empty family is the round-end signal, not a widget")

	# DESCENDING types + two identical cards: a sort would be visible in the order AND in the cascade
	var fam: Array[Deck.CardType] = [
		Deck.CardType.Princess, Deck.CardType.King, Deck.CardType.Guard, Deck.CardType.King]
	p.family = fam
	p.render_family()
	_check_stack_p(tag, p, ["Princess", "King", "Guard", "King"], [0, 9, 18, 27])
	check(int(p.family_root.get_global_position().x) == 31, tag + ": the strip's first card is at global x 31 ("
		+ str(int(p.family_root.get_global_position().x)) + ") - the free strip the todo pins at x 31..78, y 31..48")
	var last: Card = p.family_root.get_child(3)
	check(int(last.global_position.x) + 11 == 69, tag + ": 4 stack cards end at global x 69 ("
		+ str(int(last.global_position.x) + 11) + ") = 31 + 9*3 + 11 - so the 2p row of 5 family cards ends at 77"
		+ " (31 + 36 + 11), 7 px inside the 84 px viewport; 9 px is the BIGGEST step that fits 5 cards, because the"
		+ " 2 hand cards take global x 5..29 (13 px pitch) and the stack takes 31..77")
	# `Main.drawn_card_position(i) = (13*i, 31)` at scale 1: 2 hand cards take seat-local x 0..24
	var hand_right: int = 13 + 11
	check(hand_right == 24 and 24 <= int(Player.FAMILY_STACK_ORIGIN.x), tag + ": seat 0's 2nd hand card ends at"
		+ " seat-local x 24 (" + str(hand_right) + ") and the stack starts at 26 - the family row is RIGHT of the"
		+ " hand row, 2 px apart, so a stack card can never cover the card the human has to tap")
	check(int(p.family_root.get_child_count()) == 4, tag + ": the same 4-card family renders 4 nodes ("
		+ str(p.family_root.get_child_count()) + ") - 2 Kings in one family is legal (2 copies in the deck) and the"
		+ " stack keeps them as 2 separate slivers, in the order they were dealt")

	# the render is a REBUILD: re-render 3x and the node count must not grow
	p.render_family()
	p.render_family()
	p.render_family()
	check(int(p.family_root.get_child_count()) == 4, tag + ": 3 re-renders of the same family still give 4 nodes ("
		+ str(p.family_root.get_child_count()) + ") - every family change re-renders, so a leak here would pile up"
		+ " one ghost card per draw")

	# a draw pops the data and the stack re-renders from the NEW first card (x always starts at 0)
	var drawn: Deck.CardType = p.pop_family(0)
	p.render_family()
	_check_stack_p(tag, p, ["King", "Guard", "King"], [0, 9, 18])
	check(drawn == Deck.CardType.Princess, tag + ": the popped card is family index 0 ("
		+ Deck.card_names[int(drawn)].strip_edges() + ") and the stack now starts with the NEXT as-dealt card - the"
		+ " cascade always shows what is left, starting at x 0")

	# the visibility rule, on a seat that is NOT human: data yes, pixels no
	var afam: Array[Deck.CardType] = [Deck.CardType.King, Deck.CardType.Countess, Deck.CardType.Prince]
	ai.family = afam
	ai.render_family()
	check(int(ai.family_root.get_child_count()) == 0 and ai.family_size() == 3, tag + ": an AI seat renders"
		+ " NOTHING from a 3-card family (" + str(ai.family_root.get_child_count()) + " nodes, family "
		+ str(ai.family_size()) + ") - the family is PRIVATE: `render_family()` without `force` is the menu"
		+ " render and a menu only exists for the human seat")
	ai.render_family(false, true)
	check(int(ai.family_root.get_child_count()) == 3, tag + ": `force` renders an AI family ("
		+ str(ai.family_root.get_child_count()) + " nodes) - that is the elimination reveal, the one moment a"
		+ " private family becomes public (`reveal_out_family` is its only caller)")
	_check_stack_p(tag, ai, ["King", "Countess", "Prince"], [0, -9, -18], false)
	ai.render_family()
	check(int(ai.family_root.get_child_count()) == 0, tag + ": the menu render takes an AI stack back to 0 nodes ("
		+ str(ai.family_root.get_child_count()) + ") - a revealed family never stays rendered after its owner's round")

	# clearing the data clears the nodes (and the NODE lives on: it is part of the seat scene)
	p.clear_family()
	check(p.family_size() == 0 and int(p.family_root.get_child_count()) == 0, tag + ": `clear_family()` clears the"
		+ " data AND the stack (" + str(p.family_root.get_child_count()) + " nodes) - a stack that outlives its data"
		+ " renders a ghost family in the next round")
	check(p.family_root.get_parent() == p and p.family_root.name == "Family", tag + ": clearing frees the CARDS, not"
		+ " the stack node (" + str(p.family_root.get_parent()) + ") - the same node serves the reveal, the menu and"
		+ " the next round's re-deal, so `set_inactive()` must NOT free it")
	# typed-array assignment is a REFERENCE (`p.family = fam` shared `fam` with the seat, and the
	# `clear_family()` above emptied it), so a probe hands its own copy to every seat
	var fam2: Array[Deck.CardType] = [
		Deck.CardType.Princess, Deck.CardType.King, Deck.CardType.Guard, Deck.CardType.King]
	pr.family = fam2
	pr.render_family()
	_check_stack_p(tag, pr, ["Princess", "King", "Guard", "King"], [0, -9, -18, -27])
	var prlast: Card = pr.family_root.get_child(3)
	check(int(prlast.global_position.x) >= 21 and int(prlast.global_position.x) + 11 <= 84, tag + ": a mirrored"
		+ " 4-card stack stays on the board (x " + str(int(prlast.global_position.x)) + ".."
		+ str(int(prlast.global_position.x) + 11) + ") - 68 - 11 - 27 = 30, the left edge a 5-card stack reaches is 21")
	pr.clear_family()
	p.queue_free()
	pr.queue_free()
	ai.queue_free()
	await await_frames(2)


# settle a re-deal WITHOUT re-initializing the players (`init_players` would reset the seats and
# their AI levels, which is exactly what a round-2 re-deal must not do). The human seat is the only
# seat with a guaranteed state at the settle moment: an AI seat's family depends on how many turns
# he already had, which depends on which seat the round starts at (`round_over()` picks a winner).
func _settle_redeal(main, fam: int) -> void:
	# the re-deal's first turn start is a human turn start too, so it stops at the family modal (step 20)
	await _human_draw(main, 0)
	var frames: int = 0
	while frames < 400:
		if main._players[0].hand.get_child_count() == 2 and main._players[0].family_size() == fam - 1:
			return
		await get_tree().process_frame
		frames += 1


# F2: a whole 2p round played by the human - family 5 per seat, 11 turns, 10 plays, NO elimination
# (no Priest anywhere). The stack is sampled after every one of the human's 5 plays: the rule is
# "the stack renders `family`", so the sample is the family minus the draws the seat already made,
# in as-dealt order. The AI seat is sampled at the same 6 moments: 0 nodes every time.
func _test_stack_2p() -> void:
	var main = _scripted_main_human(2, NOBLE_2P_STACK, NOBLE_2P_STACK_LEFT)
	await _settle_deal_human(main)
	var tag := "F2"
	var p0 = main._players[0]
	var p1 = main._players[1]
	check(int(p0.family_root.get_global_position().x) == 31 and int(p0.family_root.get_global_position().y) == 31, tag
		+ ": seat 0's stack origin is global (31, 31) on the REAL board (seat at (5, 31), stack at seat-local (26, 0))"
		+ " - the free bottom strip, right of his hand cards, below the badge row")
	for i in [2, 3]:
		check(main._players[i].family_root.position == Main.FAMILY_STACK_MIRROR, tag + ": the x 68 seat " + str(i)
			+ " mirrors its stack to (" + str(main._players[i].family_root.position) + ") - Disabled in a 2p game and"
			+ " rendered at all, the mirror is the geometry its reveal would use in a 4p game")
	_check_stack_p(tag + " after the deal", p0, ["Guard", "Guard", "Guard", "Countess"], [0, 9, 18, 27])
	check(p0.family_size() == 4 and p0.hand.get_child_count() == 2, tag + ": the human holds the 2-card hand AND 4"
		+ " family cards at his first decision (family 5 - the turn-start draw) - the 5th family card is the Countess"
		+ " he will still own at the round end")
	var hand_right := 0
	for ch in p0.hand.get_children():
		hand_right = max(hand_right, int(ch.global_position.x) + 11)
	var stack_left: int = 999
	for n in _stack_nodes(p0):
		stack_left = min(stack_left, int(n["global_x"]))
	check(hand_right == 29 and stack_left == 31, tag + ": the human's 2 hand cards end at global x 29 and his stack"
		+ " starts at 31 (" + str(hand_right) + " / " + str(stack_left) + ") - 2 px apart on one 48 px-high row, so"
		+ " the family never covers a card he has to tap and never needs a second row")
	check(int(p1.family_root.get_child_count()) == 0 and p1.family_size() == 5, tag + ": seat 1 (AI) holds a FULL 5"
		+ "-card family and renders 0 nodes - the family is private, so the human sees NO pixels of what the AI seat"
		+ " is about to draw")
	var steps: Array = [
		[["Guard", "Guard", "Guard", "Countess"], [0, 9, 18, 27]],
		[["Guard", "Guard", "Countess"], [0, 9, 18]],
		[["Guard", "Countess"], [0, 9]],
		[["Countess"], [0]],
		[[], []],
	]
	for k in 5:
		await _human_play(main, 1, Deck.CardType.Priest)
		_check_stack_p(tag + " after the human's play " + str(k + 1), main._players[0], steps[k][0], steps[k][1])
		check(int(main._players[1].family_root.get_child_count()) == 0, tag + ": the AI seat's stack is still empty"
			+ " after play " + str(k + 1) + " (" + str(main._players[1].family_root.get_child_count())
			+ " nodes, family " + str(main._players[1].family_size()) + ")")
	var settle: int = 0
	while main.round_end_actor.size() == 0 and settle < 400:
		await get_tree().process_frame
		settle += 1
	check(main.round_end_actor.size() > 0 and int(main.round_end_turns[0][0]) == 6
		and int(main.round_end_turns[0][1]) == 5, tag + ": the 2p round settled at its 11th turn ("
		+ str(main.round_end_turns[0]) + " turn-starts per seat = 11, " + str(main.effect_log.size())
		+ " plays, [6, 5, 0, 0] expected) - the stack test plays a FULL round, so the round-end and re-deal"
		+ " checks below run on a real production state")
	check(main.eliminations == 0, tag + ": 0 seats left the round - a Guard probe declares Priest and no seat ever"
		+ " held one, so the round ends PURELY on the family-empty rule")
	check(main.pile_draws == 0, tag + ": 0 main-pile draws - 2p keeps 1 card in the pile and no Prince was played, so"
		+ " the widow stays a fallback the whole round")
	_check_stack_p(tag + " at the round end", main._players[0], [], [])
	_check_stack_p(tag + " at the round end", main._players[1], [], [])
	check(main._players[0].family_size() == 0 and main._players[1].family_size() == 0, tag + ": both families are"
		+ " empty at the round end (" + str(main._players[0].family_size()) + ", "
		+ str(main._players[1].family_size()) + ") - 10 plays for 10 family cards, and the 11th turn-start finds an"
		+ " empty family: the actor is seat " + str(main.round_end_actor[0]))
	# the round-2 re-deal: families are PRIVATE, PER-SEAT and re-dealt EVERY round
	await main._on_round_over_pressed()
	await _settle_redeal(main, Deck.NOBLE_FAMILY_SIZE[2])
	_check_stack_p(tag + " round 2", main._players[0], ["Guard", "Guard", "Guard", "Countess"], [0, 9, 18, 27])
	check(int(main._players[1].family_root.get_child_count()) == 0 and main._players[1].family_size() >= 4
		and main._players[1].family_size() <= 5, tag + " round 2: the AI family is re-dealt INVISIBLE (0 nodes,"
		+ " family " + str(main._players[1].family_size()) + ") - a re-deal renders nothing on an AI seat and refills"
		+ " the human's stack in the SAME node, so the family menu survives every round")
	main.queue_free()
	await await_frames(2)


# F3: the 4p E3 position, seen from the stack. Seat 0 (human) plays a Baron on seat 1 at play 1: seat 1
# leaves the round with 3 family cards he never touched. His stack must be empty BEFORE (private) and
# empty AFTER (revealed, discarded, cleared) - the 3 cards are visible in exactly one moment.
func _test_stack_4p() -> void:
	var main = _scripted_main_human(4, NOBLE_4P_BARON_HUMAN, NOBLE_4P_BARON_HUMAN_LEFT)
	await _settle_deal_human(main)
	var tag := "F3"
	var p0 = main._players[0]
	var p1 = main._players[1]
	_check_stack_p(tag + " after the deal", p0, ["Guard", "Guard"], [0, 9])
	check(p0.family_size() == 2, tag + ": the human's family is down to 2 (family 3 - the King he drew at the first"
		+ " turn start) - the stack starts at the card that is LEFT, so what he sees is exactly what he can draw")
	check(int(p1.family_root.get_child_count()) == 0 and p1.family_size() == 3, tag + ": seat 1 holds a FULL 3-card"
		+ " family (King, Countess, Princess) and renders 0 nodes - the human cannot see the cards he is about to"
		+ " publish with his Baron, so the family is a private resource the opponent keeps from him")
	for i in [2, 3]:
		check(int(main._players[i].family_root.get_child_count()) == 0, tag + ": seat " + str(i)
			+ " (AI) renders NOTHING at family size " + str(main._players[i].family_size()) + " ("
			+ str(main._players[i].family_root.get_child_count())
			+ " nodes) - an AI seat renders nothing at family 3, at family 0 and at every size between: his family is"
			+ " data, and the human cannot see what an opponent draws out of")
	await _human_play(main, 1, Deck.CardType.Priest)  # the Baron on seat 1 -> seat 1 is out
	check(main.reveal_log.size() == 1, tag + ": ONE reveal call for the elimination (" + str(main.reveal_log.size())
		+ ") - the family is published once, not once per card and not once per effect")
	var rec: Dictionary = main.reveal_log[0]
	check(bool(rec.get("is_seat_stack", false)), tag + ": the reveal renders INTO the seat's own `$Family` node ("
		+ str(rec.get("container", "")) + ") - not a throwaway container: the stack is the seat's surface for the menu,"
		+ " the reveal and the next round's re-deal")
	check(int(rec.get("cards", []).size()) == 3, tag + ": the reveal published all 3 of seat 1's family cards ("
		+ str(rec.get("cards", []).size()) + " nodes) - the whole family, in as-dealt order, not the 1 card he would"
		+ " have drawn next")
	_check_stack_p(tag + " seat 1 after his reveal", main._players[1], [], [])
	check(p1.family_size() == 0, tag + ": seat 1's family data is cleared with his cards (" + str(p1.family_size())
		+ " cards, " + str(int(p1.family_root.get_child_count())) + " nodes) - an out seat has no family to draw, and"
		+ " a stack that kept his cards would render them in every later round")
	_check_stack_p(tag + " after the elimination", main._players[0], ["Guard", "Guard"], [0, 9])
	await _human_play(main, 2, Deck.CardType.Priest)  # T4: the King, the family[1] Guard is now the leftover
	_check_stack_p(tag + " after the human's play 2", main._players[0], ["Guard"], [0])
	await _human_play(main, 2, Deck.CardType.Priest)  # T7: the Guard
	_check_stack_p(tag + " after the human's play 3", main._players[0], [], [])
	var settle: int = 0
	while main.round_end_actor.size() == 0 and settle < 400:
		await get_tree().process_frame
		settle += 1
	check(main.round_end_actor.size() > 0 and int(main.round_end_actor[0]) == 0, tag + ": the round settled on seat"
		+ " 0's turn start with an empty family (actor " + str(main.round_end_actor) + ") - 11 turns, 9 plays, the"
		+ " seat 1 elimination at play 1")
	for i in [1, 2, 3]:
		check(int(main._players[i].family_root.get_child_count()) == 0, tag + ": at the round end seat " + str(i)
			+ " renders an empty stack (" + str(main._players[i].family_root.get_child_count()) + " nodes, family "
			+ str(main._players[i].family_size()) + ") - no ghost family on an out seat, none on an AI seat")
	await main._on_round_over_pressed()
	await _settle_redeal(main, Deck.NOBLE_FAMILY_SIZE[4])
	_check_stack_p(tag + " round 2", main._players[0], ["Guard", "Guard"], [0, 9])
	check(int(main._players[0].family_size()) == 2 and p0.hand.get_child_count() == 2, tag + " round 2: the re-deal"
		+ " refilled 3 family cards and the first turn start already spent the King (family 2, hand 2) - the stack is"
		+ " refilled in the SAME node every round, no new widget, no leftover card from round 1")
	# an elimination lasts ONE round: `_new_round()` calls `init_discard_pile(_player_count)`, which
	# re-enables every seat, so the out seat returns to a fresh, invisible family in the next round
	check(int(main._players[1].family_root.get_child_count()) == 0 and main._players[1].family_size() >= 3, tag
		+ " round 2: seat 1 is back in the round with a FULL 3-card family and 0 rendered nodes (family "
		+ str(main._players[1].family_size()) + ") - his revealed family is gone (round 1), a new private one is dealt"
		+ " to him, and the human sees none of it")
	check(int(main._players[3].family_root.get_child_count()) == 0
		and main._players[3].family_size() >= 2 and main._players[3].family_size() <= 3, tag
		+ " round 2: seat 3 is BACK in the round (level " + str(main._players[3].ai_level) + ", family "
		+ str(main._players[3].family_size()) + " of 3) and renders 0 nodes - an elimination lasts ONE round:"
		+ " `_new_round()` calls `init_discard_pile(_player_count)`, which re-enables every seat, and the seat that"
		+ " was out is re-dealt a family the human cannot see")
	main.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# TEST G (todo step 19): the family draw MODAL (`family_selector/family_selector.tscn`)
#
# TEST F's stack is the human's VIEW of his family; the modal is where he CHOOSES. Pinned here:
#  1. `open(family)` REBUILDS one row of face-up cards from the family data - as-dealt order,
#     12 px pitch at y 22, up to 5 cards, the 5-card row centred on the Table inside 84 x 48;
#  2. a tap reports the FAMILY INDEX (`draw_selected(family_idx)`): Main pops `family[idx]`, so the
#     panel reports WHICH of his cards he picked and can never invent a card or rename one;
#  3. exactly ONE emission per `open()`, the panel closes itself on the tap (no modal leak), a tap
#     after the choice commits nothing, and a tap outside the row does nothing;
#  4. NO cancel/BACK control exists (the draw is mandatory): the panel contains no Control node at
#     all, so the only tappable nodes are the family cards;
#  5. the row is a COPY of the family data and the panel never touches the seat: a family pop while
#     the modal is open cannot retype a card on screen, and `open()`/`close()` pop nothing.
#
# A headless "tap" is: `Input.action_press("left_click")` - `InputEvent.is_action_pressed()` reads
# the Input singleton's ACTION STATE, not the event - then fire the `Area2D.input_event` signal the
# panel connected, then release the action.
# ----------------------------------------------------------------------------------------
const FS_ORIGIN := Vector2(12, 22)
const FS_PITCH: int = 12
const FS_MAX: int = 5


func _test_family_selector() -> void:
	print("--- TEST G1 (unit): open() rebuilds the family as ONE tappable row of face-up cards ---")
	await _test_fs_open()
	print("--- TEST G2: a tap reports the family INDEX, exactly once, and closes the modal ---")
	await _test_fs_tap()
	print("--- TEST G3: a copy of the data, no cancel control, close() drops the row ---")
	await _test_fs_copy()


func _fs_panel():
	var sel = FamilySelectorScene.instantiate()
	add_child(sel)
	return sel


# The panel's row, in tree order == family order (the same dict shape `_rn` / `_xs` / `_faceups`
# read, plus the node, so a harness can fire the card's own `input_event` signal)
func _fs_cards(sel) -> Array:
	var out: Array = []
	for ch in sel.get_children():
		if ch is Card:
			out.append({
				"type": int(ch.type),
				"faceup": bool(ch.faceup),
				"x": int(ch.position.x),
				"y": int(ch.position.y),
				"conns": int(ch.input_event.get_connections().size()),
				"mod": int(int(ch.modulate.a * 100)),
				"node": ch,
			})
	return out


func _fs_tap(card: Node) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	Input.action_press("left_click")
	card.emit_signal("input_event", null, ev, 0)
	Input.action_release("left_click")


func _fs_ys(cards: Array) -> Array:
	var out: Array = []
	for c in cards:
		out.append(int(c["y"]))
	return out


func _fs_mods(cards: Array) -> Array:
	var out: Array = []
	for c in cards:
		out.append(int(c["mod"]))
	return out


# Every Control node under the panel, at any depth: a Button is a way to leave the modal without
# drawing, which the variant rules forbid (the turn-start draw and a Prince redraw are mandatory)
func _fs_controls(sel: Node) -> Array:
	var out: Array = []
	for ch in sel.get_children():
		if ch is Control:
			out.append(str(ch.get_class()) + ":" + str(ch.name))
		out.append_array(_fs_controls(ch))
	return out


# A DESCENDING family of distinct, real-deal-legal types: a sort of the row is visible in the order
# (and a sort would break the index -> card mapping, which is what G2 pins)
func _fs_family(size: int) -> Array[Deck.CardType]:
	var all: Array[Deck.CardType] = [
		Deck.CardType.Princess, Deck.CardType.Countess, Deck.CardType.King, Deck.CardType.Prince,
		Deck.CardType.Handmaid]
	var out: Array[Deck.CardType] = []
	for i in size:
		out.append(all[i])
	return out


func _fs_family_names(size: int) -> Array:
	var all: Array = ["Princess", "Countess", "King", "Prince", "Handmaid"]
	var out: Array = []
	for i in size:
		out.append(all[i])
	return out


func _fs_max_family() -> int:
	var m: int = 0
	for n in Deck.NOBLE_FAMILY_SIZE.size():
		m = max(m, int(Deck.NOBLE_FAMILY_SIZE[n]))
	return m


func _fs_inside(cards: Array) -> bool:
	var inside: bool = true
	for c in cards:
		inside = inside and int(c["x"]) >= 0 and int(c["x"]) + 11 <= 84 \
			and int(c["y"]) >= 0 and int(c["y"]) + 17 <= 48
	return inside


func _fs_rects(cards: Array) -> Array:
	var out: Array = []
	for c in cards:
		out.append("[" + str(int(c["x"])) + "," + str(int(c["y"])) + "]-"
			+ "[" + str(int(c["x"]) + 11) + "," + str(int(c["y"]) + 17) + "]")
	return out


# G1: the row itself - geometry, order, visibility, tappability, the 5-card cap, the rebuild
func _test_fs_open() -> void:
	var tag := "G1"
	var sel = _fs_panel()
	await await_frames(1)
	check(!sel.visible and !sel.is_open(), tag + ": the panel is CLOSED at scene setup (visible "
		+ str(sel.visible) + ", armed " + str(sel.is_open()) + ") - a panel open at startup eats taps"
		+ " before a family exists, and step 20 shows it through `open()` only")
	check(int(sel.get_child_count()) == 1, tag + ": an empty panel is ONE node (the selection sprite) -"
		+ " the row is BUILT FROM DATA on every open, so a panel that kept the previous family's cards"
		+ " would show a family the seat does not own")
	check(_fs_max_family() == FS_MAX, tag + ": the panel's " + str(FS_MAX) + "-card cap IS the deal"
		+ " table's biggest family (`Deck.NOBLE_FAMILY_SIZE` max " + str(_fs_max_family()) + ", 2p)"
		+ " - a full family fits in one row, so the human chooses among ALL of it, with no paging and"
		+ " no hidden card")

	var fam: Array[Deck.CardType] = _fs_family(FS_MAX)
	sel.open(fam)
	var cards: Array = _fs_cards(sel)
	check(sel.visible and sel.is_open(), tag + ": `open()` OPENS the panel (visible " + str(sel.visible)
		+ ", armed " + str(sel.is_open()) + ")")
	check(cards.size() == FS_MAX, tag + ": a 5-card family renders 5 cards (" + str(cards.size())
		+ ") - 1 node per family card, like the seat's stack")
	check(_rn(cards) == _fs_family_names(FS_MAX), tag + ": the row is the family in AS-DEALT order ("
		+ str(_rn(cards)) + " expected " + str(_fs_family_names(FS_MAX)) + ") - never sorted: the row"
		+ " order IS the index order Main pops, so a sorted row draws a card other than the one tapped")
	check(_xs(cards) == [12, 24, 36, 48, 60], tag + ": the row is x " + str(FS_ORIGIN.x) + " + i *"
		+ str(FS_PITCH) + " (" + str(_xs(cards)) + ") - a 12 px pitch on 11 px cards leaves a 1 px gap,"
		+ " so 5 tap targets of 11 x 17 px (88 x 136 px on screen at scale 8) never merge into one")
	check(_fs_ys(cards) == [22, 22, 22, 22, 22], tag + ": every card sits at y " + str(FS_ORIGIN.y)
		+ " (" + str(_fs_ys(cards)) + ") - ONE row, centred over the Table: below the top seat row"
		+ " (y 0..17) and above the target-selection labels (y 36+)")
	var ups: bool = true
	for c in cards:
		ups = ups and bool(c["faceup"])
	check(ups, tag + ": every card of the row is FACE-UP (" + str(_faceups(cards))
		+ ") - these are the human's OWN private family cards, he is allowed to see them; the panel is"
		+ " the one place a family is face-up on a screen that never publishes an AI family")
	var conns: int = 0
	for c in cards:
		conns += int(c["conns"])
	check(conns == cards.size() and _fs_cards(sel).size() == cards.size(), tag + ": every card connects"
		+ " EXACTLY ONE input_event (" + str(conns) + " connections, " + str(cards.size())
		+ " cards) - the row is tappable (the stack of step 18 connects ZERO: it is a view, this is the"
		+ " control) and a card with 2 connections would emit the draw twice per tap")
	check(_fs_inside(cards), tag + ": the whole row is INSIDE the 84 x 48 viewport ("
		+ str(_fs_rects(cards)) + ") - no scroll, no zoom, no second row on a phone")
	var last: Card = cards[FS_MAX - 1]["node"]
	check(int(FS_ORIGIN.x) == 12 and int(last.position.x) + 11 == 71, tag + ": a full row spans x"
		+ " 12..71, i.e. centred on the 84 px board (centre 41.5 vs the board's 42) - the modal is"
		+ " 'centred over the Table', and 12 px of pitch x 5 cards is the widest row that stays centred")
	check(_fs_controls(sel).is_empty(), tag + ": the panel contains NO Control/Button node ("
		+ str(_fs_controls(sel)) + ") - there is no cancel, no BACK, no 'draw the last card' shortcut:"
		+ " the draw is MANDATORY, so the only way out of the modal is a family card")

	# a re-open is a REBUILD from the new data, not an append to the old row
	sel.open(_fs_family(3))
	var three: Array = _fs_cards(sel)
	check(three.size() == 3, tag + ": re-opening with a 3-card family renders 3 cards ("
		+ str(three.size()) + "), not 5 + 3 - the modal shows the family the seat has NOW (a Prince"
		+ " redraw is asked from a family that already lost cards, and a 4p family is 3, never 5)")
	check(_xs(three) == [12, 24, 36] and _rn(three) == _fs_family_names(3), tag + ": the 3-card row"
		+ " starts at the same x " + str(FS_ORIGIN.x) + " (" + str(_xs(three)) + ") - the row is left-"
		+ " anchored on the same slot, so the family's first card is always under the same finger")
	check(_fs_inside(three), tag + ": the 3-card row is inside the viewport (" + str(_fs_rects(three))
		+ ") - 3p and 4p families (4 and 3 cards) fit the same row the 2p family of 5 fits")

	# an empty family never opens a panel: the row would have no tap target and the turn would stick
	var fam0: Array[Deck.CardType] = []
	sel.open(fam0)
	check(!sel.visible and !sel.is_open() and int(sel.get_child_count()) == 1, tag + ": `open()` on an"
		+ " EMPTY family refuses to open AND closes the 3-card row it was showing (visible "
		+ str(sel.visible) + ", cards " + str(int(sel.get_child_count()) - 1) + ") - an empty family"
		+ " means the round is over (turn start) or the target is out (Prince); a modal with no card to"
		+ " tap is a deadlocked turn, and a modal that stayed open on its previous row is a family the"
		+ " seat no longer owns")

	# the selection sprite: the tapped card flashes, the rest fade (no confirm step exists, so this
	# is the choice flash, not a confirmation widget)
	sel.open(_fs_family(4))
	sel.set_selection(2)
	var four: Array = _fs_cards(sel)
	check(four.size() == 4 and _fs_mods(four) == [25, 25, 100, 25], tag + ": `set_selection(2)` dims"
		+ " every card but the chosen one (" + str(_fs_mods(four)) + ") - the human sees which card his"
		+ " tap committed, at 672 x 384 with 11 px cards and no hover state")
	var spr: Sprite2D = sel.get_node("FamilySelection") as Sprite2D
	check(bool(spr.visible) and int(spr.position.x) == int(four[2]["x"]) and int(spr.position.y)
		== int(four[2]["y"]), tag + ": the selection sprite moves ONTO the chosen card at ("
		+ str(int(spr.position.x)) + ", " + str(int(spr.position.y)) + ") - the SAME selection sprite"
		+ " the type selector uses, so the tap feedback is the one the player already knows")
	sel.set_selection(-1)
	check(!bool(spr.visible) and _fs_mods(_fs_cards(sel)) == [100, 100, 100, 100],
		tag + ": `set_selection(-1)` clears the sprite and the dimming - a panel that stayed dimmed"
		+ " would look like a card was already picked, i.e. like the draw is done")
	sel.close()
	check(!sel.visible and !sel.is_open(), tag + ": `close()` closes the panel (visible "
		+ str(sel.visible) + ", armed " + str(sel.is_open()) + ")")
	await await_frames(2)
	check(int(sel.get_child_count()) == 1, tag + ": `close()` drops the ROW (children "
		+ str(int(sel.get_child_count())) + " = the sprite only) - a closed panel that keeps its cards"
		+ " keeps tappable Area2D zones over the board and a copy of a family that no longer exists")
	sel.queue_free()
	await await_frames(2)


# G2: the tap -> index contract, the one step 20 awaits on
func _test_fs_tap() -> void:
	var tag := "G2"
	var sel = _fs_panel()
	await await_frames(1)
	var draws: Array[int] = []
	sel.draw_selected.connect(func(i: int) -> void: draws.append(i))
	# the MIDDLE card is tapped first, then the first, then the last: a panel that hardcodes index 0
	# (the step 7 placeholder draw) passes "tap card 0" and fails here
	for i in [2, 0, 4]:
		var fam: Array[Deck.CardType] = _fs_family(FS_MAX)
		sel.open(fam)
		var cards: Array = _fs_cards(sel)
		draws.clear()
		_fs_tap(cards[i]["node"])
		check(draws.size() == 1, tag + ": tapping family card " + str(i) + " emitted EXACTLY ONE choice"
			+ " (" + str(draws.size()) + " emissions) - the tap IS the draw: no confirm step to await,"
			+ " no second emission for Main to consume")
		check(draws.size() == 1 and draws[0] == i, tag + ": the emitted family index IS the tapped"
			+ " card's index in the as-dealt family (got " + str(draws) + ", tapped " + str(i)
			+ ") - the panel reports an index, not a type, so Main pops `family[idx]`"
			+ " (a panel that reported the FIRST index would be the step 7 placeholder, i.e. the human"
			+ " would never get to choose)")
		check(draws.size() == 1 and int(fam[draws[0]]) == int(cards[i]["type"]), tag + ": the emitted"
			+ " index names the card he tapped (" + Deck.card_names[int(fam[draws[0]])].strip_edges()
			+ " at family index " + str(draws[0]) + ", tapped "
			+ Deck.card_names[int(cards[i]["type"])].strip_edges() + ") - index and card agree, so the"
			+ " card that leaves the family is the card that flies to his hand")
		check(!sel.visible and !sel.is_open(), tag + ": the panel closed ITSELF on the tap (visible "
			+ str(sel.visible) + ", armed " + str(sel.is_open()) + ") - Main awaits one signal, and a"
			+ " panel left open after it is the stuck overlay step 22 guards against")
		var refused: bool = sel.select(i)
		check(!refused and draws.size() == 1, tag + ": a SECOND tap on the same index (a real double"
			+ " tap on a 11 px target) is refused (" + str(refused) + ", emissions " + str(draws.size())
			+ ") - one emission per `open()`, so a double tap cannot pop two family cards and cannot"
			+ " break the 1-hand-card invariant the whole design rests on")
		await await_frames(2)

	# taps that are not a choice: out of the row, a negative index, a closed panel
	sel.open(_fs_family(3))
	draws.clear()
	check(!sel.select(3) and draws.is_empty() and sel.is_open(), tag + ": index 3 of a 3-card row is"
		+ " refused (emissions " + str(draws.size()) + ") and the panel STAYS OPEN (" + str(sel.is_open())
		+ ") - a tap outside the cards does nothing, the human still has to draw")
	check(!sel.select(-1) and draws.is_empty() and sel.is_open(), tag + ": index -1 is refused ("
		+ str(draws.size()) + " emissions) - no 'nothing' option exists, the draw is mandatory")
	check(!sel.select(99) and draws.is_empty() and sel.is_open(), tag + ": an out-of-range index is"
		+ " refused (" + str(draws.size()) + " emissions) - the panel cannot name a family card that"
		+ " does not exist, so Main's `pop_family(idx)` is always in range")
	sel.close()
	draws.clear()
	check(!sel.select(0) and draws.is_empty() and !sel.is_open(), tag + ": a CLOSED panel commits"
		+ " nothing (" + str(draws.size()) + " emissions) - the guard is the panel's own arm flag, not"
		+ " the node's visibility, so a stale connected card from a previous row cannot fire a draw"
		+ " into the next `await`")
	# re-arming: the same panel serves every turn of a game
	sel.open(_fs_family(4))
	draws.clear()
	_fs_tap(_fs_cards(sel)[3]["node"])
	check(draws.size() == 1 and draws[0] == 3, tag + ": re-opening the SAME panel arms it again (emitted"
		+ " " + str(draws) + ") - one panel node serves every turn start and every Prince redraw of a"
		+ " game, so a one-shot connection would strand the human's next turn")
	sel.queue_free()
	await await_frames(2)


# G3: the panel is a VIEW of the data, never its owner
func _test_fs_copy() -> void:
	var tag := "G3"
	var sel = _fs_panel()
	await await_frames(1)
	var fam: Array[Deck.CardType] = _fs_family(FS_MAX)
	var shown: Array = _rn(_fs_cards(sel))
	sel.open(fam)
	var row: Array = _rn(_fs_cards(sel))
	check(row == _fs_family_names(FS_MAX) and shown.is_empty(), tag + ": `open()` is what builds the"
		+ " row (before: " + str(shown) + ", after: " + str(row) + ") - the panel renders nothing on"
		+ " construction, so it can be a permanently-allocated node of `main.tscn` (step 20)")
	# the seat's family can only change through Main; the panel must not retype what the human sees
	fam.pop_at(0)
	check(_rn(_fs_cards(sel)) == row, tag + ": a family pop WHILE the modal is open does not retype the"
		+ " row (" + str(_rn(_fs_cards(sel))) + " == " + str(row) + ") - the row is a COPY, so the"
		+ " human always chooses among the cards he was shown; Main's exclusivity (step 22: nothing"
		+ " draws from a family while its modal is open) is what keeps the index aligned")
	check(int(fam.size()) == FS_MAX - 1, tag + ": the seat's family really shrank (" + str(fam.size())
		+ " of " + str(FS_MAX) + ") - the panel copied the types, it did not take over the array")
	var untouched: Array[Deck.CardType] = _fs_family(FS_MAX)
	var before_types: Array = _ftypes(untouched)
	sel.close()
	sel.open(untouched)
	check(_ftypes(untouched) == before_types, tag + ": `open()` NEVER pops the family it shows ("
		+ str(_ftypes(untouched)) + " == " + str(before_types) + ") - the panel reports an index and"
		+ " Main does the pop, so a panel that also popped would delete a card the seat never played"
		+ " and desync the `_left` accounting (a family card leaves play only when it is played)")
	sel.close()
	var kept: Array = _ftypes(untouched)
	check(kept == before_types, tag + ": and `close()` leaves the family array alone TOO (" + str(kept)
		+ " == " + str(before_types) + ") - the destructive half is the one that matters: a panel that"
		+ " keeps the family BY REFERENCE (an untyped `var types = family` shares the seat's array, the"
		+ " trap step 17 hit) would EMPTY the seat's family in its own close(): the seat loses cards he"
		+ " never played, his draw is skipped and the `_left` census desyncs")
	await await_frames(2)
	check(_fs_controls(sel).is_empty(), tag + ": closing and re-opening never CREATES a control ("
		+ str(_fs_controls(sel)) + ") - the modal has no cancel/BACK at any point of a game, not"
		+ " just on the first open")
	check(int(sel.get_child_count()) == 1, tag + ": after `close()` the panel is back to the bare"
		+ " sprite node (children " + str(int(sel.get_child_count())) + ") - a row that survives its"
		+ " modal is a ghost family a tap can still hit")
	sel.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# TEST H (todo step 20): the human's mandatory family draw goes through the MODAL
#
# Step 20 is a PRODUCTION change, not a fixture: `main.tscn` carries the panel (a sibling of
# `TypeSelector`, z 10, hidden) and `Main.human_draw_from_family()` hides the Table, opens the panel
# on the seat's family, AWAITS the tapped index, closes it, shows the Table and pops `p.family[idx]`.
# The step 7 placeholder (auto-pick index 0) is GONE, so a human turn start now stops at the panel:
# the modal is the only way a human seat draws a family card.
#
# H1 the gate: at the human's turn start the panel is open and NOTHING has been drawn - 1 hand card,
#   the full family, the Table hidden, the play selection closed, no other surface visible, and the
#   row is ONLY his own family, in as-dealt order. With no tap the turn just waits: no timeout, no
#   fallback auto-pick.
# H2 the tap: a NON-FIRST index is honoured - the card that lands in his hand, the card his stack no
#   longer shows, the family that gets published when he leaves the round, and the recorded drawn index
#   all name family[1], not family[0]. A Guard (rank 0) loses the Baron he plays with it, so the tap
#   also decides WHICH seat leaves the round, and an out seat never sees the modal again.
# H3 a whole round: 5 turn starts = 5 openings, all on seat 0, no AI turn ever opens it, the main pile
#   is never drawn, and the round still ends on the family-empty rule (an empty family ends the round,
#   it never opens a panel that cannot be tapped).
# ----------------------------------------------------------------------------------------
func _test_human_modal() -> void:
	print("--- TEST H1 (4p, the human's turn start waits on the modal, nothing drawn) ---")
	await _test_modal_open()
	print("--- TEST H2 (4p, a tap on family index 1 draws family[1], and the Guard loses him his own Baron) ---")
	await _test_modal_tap_index()
	print("--- TEST H3 (2p, a whole round of modal draws: 5 openings, all on seat 0) ---")
	await _test_modal_round()


# Per-frame watcher of the panel (a coroutine, run alongside the plays): a RISING EDGE of `is_open()`
# is one turn start that asked for a draw, so `actors` is the list of seats that had a family modal -
# the family is PRIVATE, so a panel on an AI turn would be an AI seat's family published on screen.
func _watch_modal(main, w: Dictionary) -> void:
	var prev := false
	while int(w["frames"]) < 4000 and not bool(w["stop"]):
		w["frames"] = int(w["frames"]) + 1
		var now: bool = main._family_selector.is_open()
		if now and not prev:
			w["openings"] = int(w["openings"]) + 1
			w["actors"].append(int(main._cur_player))
			w["rows"].append(_rn(_fs_cards(main._family_selector)))
			if int(main._cur_player) != 0:
				w["ai_open"] = int(w["ai_open"]) + 1
			if main._table.visible:
				w["table_open"] = int(w["table_open"]) + 1
			if main._type_selector.visible or main._select_other_player.visible \
					or main._select_any_player.visible:
				w["crowded"] = int(w["crowded"]) + 1
		prev = now
		await get_tree().process_frame


func _modal_watcher() -> Dictionary:
	return {"frames": 0, "openings": 0, "actors": [], "rows": [], "ai_open": 0, "table_open": 0,
		"crowded": 0, "stop": false}


func _left_sum(main) -> int:
	var s := 0
	for t in main._deck._left.size():
		s += int(main._deck._left[t])
	return s


func _test_modal_open() -> void:
	var tag := "H1"
	var main = _scripted_main_human(4, NOBLE_4P_BARON_HUMAN, NOBLE_4P_BARON_HUMAN_LEFT)
	await main.init_players(SEED)
	var sel = main._family_selector
	await await_until(func() -> bool: return sel.is_open())
	var p0 = main._players[0]
	var row: Array = _fs_cards(sel)
	check(sel.get_parent() == main, tag + ": the panel is MAIN's node (" + str(sel.get_parent())
		+ "), a sibling of the selectors - the family is one seat's private DATA (the stack lives in the"
		+ " seat, step 18), the CHOOSING is the manager's (design.md), so the modal is allocated once in"
		+ " main.tscn and serves every turn start of every round")
	check(int(sel.z_index) == 10 and int(sel.get_index()) > int(main._type_selector.get_index()), tag
		+ ": the panel sits at z 10 after the type selector in the tree (" + str(int(sel.z_index))
		+ ", index " + str(int(sel.get_index())) + " vs " + str(int(main._type_selector.get_index()))
		+ ") - same z as the type selector, so the last one in the tree wins the tap; a family modal that"
		+ " lost its taps to the type selector is an unopenable draw")
	check(bool(sel.visible) and sel.is_open(), tag + ": the panel IS open at the human's turn start -"
		+ " the mandatory draw is HIS choice, so the turn waits for him")
	check(not main._table.visible, tag + ": the Table is hidden while the modal is open - the draw comes"
		+ " BEFORE any play, so the played-card slot has nothing to do with the choice")
	check(not main._type_selector.visible and not main._select_other_player.visible
		and not main._select_any_player.visible, tag + ": no other selector surface is visible - one"
		+ " interactive panel per human turn, so a tap is never ambiguous")
	check(_rn(row) == ["King", "Guard", "Guard"], tag + ": the row is HIS OWN family, in as-dealt order ("
		+ str(_rn(row)) + ") - the panel offers exactly the cards he can draw, in the order they were dealt")
	check(_xs(row) == [12, 24, 36] and _fs_ys(row) == [22, 22, 22] and _fs_inside(row), tag
		+ ": the row is one line at (" + str(_xs(row)) + ", " + str(_fs_ys(row)) + "), inside "
		+ str(VIEWPORT.size) + " - the whole family is tappable at once, no paging, no scroll")
	check(_faceups(row) == [true, true, true], tag + ": every row card is face-UP (" + str(_faceups(row))
		+ ") - he chooses among HIS OWN cards")
	var conns := 0
	for c in row:
		conns += int(c["conns"])
	check(conns == row.size(), tag + ": exactly one `input_event` per row card (" + str(conns)
		+ " for " + str(row.size()) + " cards) - the row is the only tappable thing in the panel")
	check(row.size() == p0.family_size(), tag + ": the row is the family, one card per family card ("
		+ str(row.size()) + " vs family " + str(p0.family_size()) + ") - no extra card, no hidden card")
	check(p0.hand.get_child_count() == 1, tag + ": the human holds EXACTLY his active card while he"
		+ " chooses - the draw has not happened, so the modal cannot be a decoration on top of a draw that"
		+ " already took place")
	check(p0.family_size() == 3, tag + ": the family is untouched while the panel is open ("
		+ str(p0.family_size()) + ") - opening the modal draws nothing, only the tap does")
	check(int(main.family_draws[0]) == 0 and int(main.family_draw_idx[0].size()) == 0, tag
		+ ": NO family card has been drawn at the gate (" + str(main.family_draws[0]) + " draws, indices "
		+ str(main.family_draw_idx[0]) + ") - the step 7 placeholder (auto-pick index 0) is gone: the"
		+ " human's draw has no auto-pick, so an un-tapped panel means an undrawn family")
	check(int(main.pile_draws) == 0 and int(main.first_hand_deals) == 4, tag + ": the variant drew"
		+ " nothing from the main pile at a turn start (" + str(main.pile_draws) + " pile draws, "
		+ str(main.first_hand_deals) + " first-hand deals) - the family replaces the turn-start pile draw,"
		+ " the widow stays a Prince-only fallback")
	check(p0._state == Player.State.IDLE and not p0.current_mark.visible, tag
		+ ": the play selection is NOT open at the gate (state " + str(p0._state) + ", mark "
		+ str(bool(p0.current_mark.visible)) + ") - the human chooses the DRAW first, the PLAY comes after"
		+ " the card is in his hand, which is the whole point of the variant turn")
	check(main.effect_log.is_empty() and int(main._cur_player) == 0, tag + ": the gate is the FIRST turn"
		+ " start of the round, seat 0's (" + str(main.effect_log.size()) + " plays so far, actor "
		+ str(main._cur_player) + ") - the draw gate is a turn START, not a play")
	for i in [1, 2, 3]:
		check(int(main._players[i].family_size()) == 3
			and int(main._players[i].family_root.get_child_count()) == 0, tag + ": seat " + str(i)
			+ " keeps his full private family and renders nothing while the human's panel is open ("
			+ str(main._players[i].family_size()) + " cards, "
			+ str(int(main._players[i].family_root.get_child_count())) + " nodes) - the panel shows ONE"
			+ " seat's family, it is not a public family board")
	await await_frames(200)
	check(sel.is_open() and p0.hand.get_child_count() == 1 and p0.family_size() == 3
		and int(main.family_draws[0]) == 0 and main.effect_log.is_empty(), tag + ": 200 frames with NO"
		+ " tap and nothing happens (" + str(p0.hand.get_child_count()) + " hand, family "
		+ str(p0.family_size()) + ", " + str(main.family_draws[0]) + " draws) - the draw has no timer, no"
		+ " fallback and no auto-pick: the variant never picks a family card for a human seat")
	main.queue_free()
	await await_frames(2)


func _test_modal_tap_index() -> void:
	var tag := "H2"
	var main = _scripted_main_human(4, NOBLE_4P_BARON_HUMAN, NOBLE_4P_BARON_HUMAN_LEFT)
	await main.init_players(SEED)
	var sel = main._family_selector
	var p0 = main._players[0]
	await await_until(func() -> bool: return sel.is_open())
	var row: Array = _fs_cards(sel)
	var fam_before: Array = _rn(row)
	var left_before: int = _left_sum(main)
	_fs_tap(row[1]["node"])
	await await_until(func() -> bool: return not sel.is_open())
	await await_until(func() -> bool: return p0.hand.get_child_count() == 2)
	check(main.family_draw_idx[0] == [1], tag + ": the drawn family index is the TAPPED index (1), not 0 ("
		+ str(main.family_draw_idx[0]) + ") - Main pops `p.family[idx]`, so the panel's index IS the draw")
	check(int(p0.hand.get_child(1).type) == int(Deck.CardType.Guard)
		and int(p0.hand.get_child(0).type) == int(Deck.CardType.Baron), tag + ": the drawn card landed in"
		+ " the SECOND hand slot, on top of his active card (" + Deck.card_names[int(
			p0.hand.get_child(1).type)].strip_edges() + " over " + Deck.card_names[int(
				p0.hand.get_child(0).type)].strip_edges() + ") - the active card never moves, the draw is"
				+ " added, which is what makes `the leftover is the active card` work for a human tap too")
	check(_rn(_stack_nodes(p0)) == ["King", "Guard"], tag + ": the stack is the family MINUS the tapped"
		+ " card (" + str(_rn(_stack_nodes(p0))) + " of " + str(fam_before) + ") - popping index 0 would"
		+ " have left [Guard, Guard] and put the KING in his hand, so the stack names prove the tapped"
		+ " index was honoured, not the first card")
	check(p0.family_size() == 2, tag + ": the family shrank by exactly one (" + str(p0.family_size())
		+ " of 3) - the tap draws ONE card, and the Countess is mandatory in both directions: the seat"
		+ " cannot keep all 3 and cannot draw twice")
	check(int(main._deck._widow_cards.size()) == 0, tag + ": the widow is untouched (4p burns nothing, "
		+ str(int(main._deck._widow_cards.size())) + " cards) - a turn-start draw is a family draw, never"
		+ " a widow draw")
	check(_left_sum(main) == left_before, tag + ": `_left` is UNCHANGED by the family draw ("
		+ str(_left_sum(main)) + " == " + str(left_before) + ") - a family card leaves the supply only"
		+ " when it is played, so the draw cannot decrement the census")
	check(sel.is_open() == false and not sel.visible and main._table.visible, tag
		+ ": the panel closed ITSELF and the Table came back (" + str(bool(sel.visible)) + ", table "
		+ str(main._table.visible) + ") - the modal has no cancel path, so the only way out of it is the"
		+ " draw it asked for, and no board surface stays hidden behind it")
	check(_fs_cards(sel).is_empty() and int(sel.get_child_count()) == 1, tag + ": the closed panel keeps"
		+ " NO row (cards " + str(_fs_cards(sel).size()) + ", children " + str(int(sel.get_child_count()))
		+ ") - a row that outlives its modal is a family a tap can still hit in the next turn")
	check(p0._state == Player.State.SELECT_CARD, tag + ": the play selection resumed right after the draw"
		+ " (state " + str(p0._state) + ") - draw, then play, in that order, on the production turn flow")
	await main._on_card_played(p0.hand.get_child(0))
	await await_until(func() -> bool: return p0._state == Player.State.INPUT_OTHER_P)
	await main._on_target_player_selected(1)
	await await_until(func() -> bool: return main.effect_log.size() > 0)
	var play1: Dictionary = main.effect_log[0]
	check(int(play1["played"]) == int(Deck.CardType.Baron) and int(play1["target"]) == 1, tag
		+ ": the human's play is the Baron on seat 1 (" + Deck.card_names[int(play1["played"])].strip_edges()
		+ " -> seat " + str(play1["target"]) + ") - the play selection is the untouched classic 2-card"
		+ " choice, the modal only prepends the draw")
	check(main.eliminations == 1 and main.eliminated_seats == [0], tag + ": the human HIMSELF is the seat"
		+ " that leaves the round (" + str(main.eliminated_seats) + ") - `Guard` is rank 0, the LOWEST card"
		+ " in the deck, so the Baron he played with the card HE TAPPED LOSES to seat 1's Priest; tapping"
		+ " index 0 (the King, rank 5) would have won it - the choice is not cosmetic, it decides which seat"
		+ " is out, and the modal is what a human turn starts with")
	var settle: int = 0
	while main.round_end_actor.size() == 0 and settle < 400:
		await get_tree().process_frame
		settle += 1
	check(main.reveal_log.size() == 2 and int(main.reveal_log[0]["seat"]) == 0
		and int(main.reveal_log[1]["seat"]) != 0, tag + ": exactly TWO family reveals in the round, the"
		+ " human's FIRST and a Princess kill on another seat (" + str([int(main.reveal_log[0]["seat"]),
			int(main.reveal_log[1]["seat"])]) + ") - the fixture keeps its Princess, and only the LOSER of a"
		+ " comparison publishes his family: the Baron WINNER seat 1 is never revealed")
	var rec: Dictionary = main.reveal_log[0]
	check(int(rec["seat"]) == 0 and _rn(rec["cards"]) == ["King", "Guard"], tag + ": the revealed family is"
		+ " the human's family MINUS the Guard he tapped out of it (" + str(_rn(rec["cards"])) + " of"
		+ " [King, Guard, Guard]) - the card he chose left play, the two he did NOT draw are published, in"
		+ " as-dealt order")
	check(int(main._players[0].family_size()) == 0
		and int(main._players[0].family_root.get_child_count()) == 0, tag + ": the out human's family data"
		+ " AND his stack are both cleared (" + str(int(main._players[0].family_size())) + " cards, "
		+ str(int(main._players[0].family_root.get_child_count())) + " nodes) - an out seat has no family to"
		+ " draw, which is what makes the no-modal rule below testable")
	await await_frames(200)
	check(not main._family_selector.is_open() and int(main.family_draws[0]) == 1, tag + ": an ELIMINATED"
		+ " human seat never opens the modal and never draws again (" + str(main.family_draws[0])
		+ " family draws in 200 more frames) - the modal gate sits BEHIND the family-empty round-end check,"
		+ " so an out seat never faces a panel with no card to tap")
	check(int(main.pile_draws) == 0, tag + ": the round drew nothing from the main pile ("
		+ str(main.pile_draws) + ") - 4p burns 3 and keeps the widow empty, and a human turn never reaches"
		+ " for a pile card")
	_check_left_audit(main, tag)
	main.queue_free()
	await await_frames(2)


func _test_modal_round() -> void:
	var tag := "H3"
	var main = _scripted_main_human(2, NOBLE_2P_STACK, NOBLE_2P_STACK_LEFT)
	var w := _modal_watcher()
	await _settle_deal_human(main, w)
	var p0 = main._players[0]
	# The 2p family is [Guard, Guard, Guard, Guard, COUNTRESS]. The settle tapped index 0 (the first
	# turn start), so plays 2..5 tap 3, 0, 0, 0: play 2 draws the COUNTRESS out of the middle of
	# [Guard, Guard, Guard, Countess] and keeps it, plays 3..5 draw the remaining Guards. A draw of
	# index 3 cannot be produced by any "draw the first card" path, and it changes what the seat KEEPS.
	var taps: Array[int] = [-1, 3, 0, 0, 0]
	for k in taps.size():
		await _human_play(main, 1, Deck.CardType.Priest, taps[k])
	var settle: int = 0
	while main.round_end_actor.size() == 0 and settle < 400:
		await get_tree().process_frame
		settle += 1
	w["stop"] = true
	await await_frames(2)
	check(int(w["openings"]) == 5, tag + ": 5 openings for 5 human turn starts (" + str(w["openings"])
		+ ") - one panel per turn start, and the 6th turn start (family 0) opens NOTHING: a family-out"
		+ " turn ends the round, it never opens a modal with no card to tap")
	check(w["actors"] == [0, 0, 0, 0, 0] and int(w["ai_open"]) == 0, tag + ": every opening is on seat 0,"
		+ " none on the AI seat (" + str(w["actors"]) + ", AI openings " + str(w["ai_open"])
		+ ") - the family is private, so an AI's draw never puts his cards on screen")
	check(int(w["table_open"]) == 0 and int(w["crowded"]) == 0, tag + ": at every opening the Table was"
		+ " hidden and no other selector was visible (table " + str(w["table_open"]) + ", crowded "
		+ str(w["crowded"]) + " of " + str(w["openings"]) + " openings) - the human turn never runs two"
		+ " panels at once")
	check(w["rows"][0] == ["Guard", "Guard", "Guard", "Guard", "Countess"], tag + ": the first opening"
		+ " shows the FULL 5-card family (" + str(w["rows"][0]) + ") - the panel opens BEFORE the draw,"
		+ " so the human always chooses among every card he has left")
	check(w["rows"][2] == ["Guard", "Guard", "Guard"], tag + ": the third opening shows the family MINUS"
		+ " the two cards already drawn (" + str(w["rows"][2]) + ") - the Countess he drew out of the"
		+ " middle is gone from the row, so the row is the LIVE family, not the dealt one")
	check(main.family_draw_idx[0] == [0, 3, 0, 0, 0], tag + ": the drawn indices are the TAPPED indices,"
		+ " in tap order (" + str(main.family_draw_idx[0]) + " for taps " + str([0, 3, 0, 0, 0])
		+ ") - a path that drew index 0 every turn (the step 7 placeholder) cannot produce a 3")
	check(int(main.family_draws[0]) == 5 and int(main.family_draws[1]) == 5, tag + ": both seats drew 5"
		+ " family cards (" + str(main.family_draws[0]) + " / " + str(main.family_draws[1])
		+ ") - the human's 5 draws are 5 turn starts, so the modal never draws twice at one turn start"
		+ " and never skips one")
	check(int(main.pile_draws) == 0, tag + ": 0 main-pile draws in the whole round ("
		+ str(main.pile_draws) + ") - 2p keeps 1 card in the pile and the variant never draws it at a"
		+ " turn start")
	check(main.eliminations == 0 and int(main.round_end_actor[0]) == 0, tag + ": 0 eliminations and the"
		+ " round ended on seat 0's empty family (actor " + str(main.round_end_actor[0]) + ") - the modal"
		+ " gate does not break the family-out round end, it is the same turn-start check")
	check(int(main.round_end_hands[0][0]) == 1, tag + ": the human ends the round with EXACTLY 1 hand card ("
		+ str(main.round_end_hands[0][0]) + ") - the 1-card invariant holds through every modal draw")
	_check_left_audit(main, tag)
	main.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# TEST I (todo step 21): the Prince REDRAW of a HUMAN seat goes through the MODAL
#
# Step 15 put the whole Prince fallback chain in production: family first, then the widow, then the
# elimination. For an AI target the family branch is `deal_from_family(tp, 0)` - no choice to make.
# For a HUMAN target it was the `# TODO(step 21)` call site: the same auto-pick step 20 deleted at
# turn start. Step 21 replaces it with `human_draw_from_family(tp)`, so a family card is NEVER picked
# for a human seat, mid-effect or at a turn start. Two shapes reach that call site:
#   - a SELF-Prince (tp == p, seat 0 Prince-plays himself), and
#   - an AI's Prince aimed at the human (the panel opens on the AI's turn and shows the HUMAN's family).
# The fallbacks stay pile/elimination paths, i.e. NO panel: an empty family is never a page, and
# `open([])` refuses to open.
#
# The watcher here is the human SEAT'S HANDS for a whole round: it taps EVERY panel opening from a
# queue, so a turn-start draw and a mid-effect Prince redraw are served by the same code and the
# recorded taps are the ONLY taps in the fixture (an auto-pick path shows up as a row/hand/index
# mismatch, not as a passing game). Each opening is sampled with: the acting seat, the row, the
# seat's family DATA at that moment, the Table / other-selector visibility, and the seat's hand.
#
# I1  4p self-Prince   : 3 openings on seat 0, the middle one MID-EFFECT with the hand at 0 cards
#                        (the Prince has already taken the card out of play, the draw REPLACES it),
#                        the row = family minus the card tapped 1 frame earlier.
# I2  4p AI Prince     : the middle opening happens on seat 1's TURN (an AI turn that shows a human
#                        family), the tapped index 1 lands in the human's hand, the pile stays closed.
# I3  3p widow fallback: 4 openings drain the 4-card family, then the 5th hit finds family 0 and
#                        draws THE WIDOW with no panel, and the 6th hit finds family 0 AND widow 0 and
#                        eliminates him - 1 pile draw, 1 elimination, 0 panels after the elimination.
# I4  4p no widow      : family 0 and no widow exists at all -> eliminated, no panel, no reveal cards
#                        (his family is empty: an empty family reveals NOTHING, and the modal never
#                        opens on it).
#
# Fixtures: 4p deal order = 4 first-hand cards (idx 0..3) then 3 family columns, seat s column c =
# idx 4 + 4*c + s; 3p = burn idx 0 (the widow), first-hand idx 1..3, seat s column c = idx 4 + 3*c + s.
# ----------------------------------------------------------------------------------------

# I1 + I2 (4p): seat 0 = Prince + [King, Guard, Countess], seats 1..3 = Guard + [Guard x3] (I1);
# seat 0 = Guard, seat 1 = Prince, families as in I1 (I2).
# I1: 1 Prince / 1 King / 1 Countess / 13 Guard. Plays: 8 (s0 Prince + Countess, s1..3 2 Guards each),
# 9 turns, 1 Prince hit (his own), 0 eliminations, 0 pile draws. Out of play: 8 plays + 1 self-Prince
# victim card (the Guard he tapped) = 9 -> `_left` == [6,0,0,0,0,1,0,0] (the King stays in his hand).
const NOBLE_4P_SELF_PRINCE: Array[Deck.CardType] = [
	Deck.CardType.Prince, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.King, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Countess, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_4P_HUMAN_PRINCE_LEFT: Array[int] = [13, 0, 0, 0, 1, 1, 1, 0]
const NOBLE_4P_SELF_PRINCE_END_LEFT: Array[int] = [6, 0, 0, 0, 0, 1, 0, 0]

# I2 (4p): the same supply, the Prince in seat 1's hand instead of seat 0's -> seat 1 Princes seat 0 on
# play 2, which is the panel-opening mid-effect draw. 8 plays, 9 turns, 1 hit, 0 eliminations,
# 0 pile draws, out of play 8 + 1 (the King the hit took) = 9 -> [7,0,0,0,0,0,0,0].
const NOBLE_4P_AI_PRINCE: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.King, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Countess, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_4P_AI_PRINCE_END_LEFT: Array[int] = [7, 0, 0, 0, 0, 0, 0, 0]

# I3 (3p): seat 0 (HUMAN) = Guard + [Guard, Guard, Guard, COUNTESS]; seats 1 and 2 hold two Princes
# each (first-hand + family[0]), so they hit seat 0 on turns 2, 3, 5 and 6 - exactly the TEST D 3p
# shape, with the Countess hidden at family index 3 so a tap can pick it out of the middle.
# T1 own draw (4 -> 3), T2 hit (3 -> 2), T3 hit (2 -> 1), T4 own draw (1 -> 0), T5 hit finds family 0
# and takes THE WIDOW (1 -> 0 cards), T6 hit finds family 0 AND widow 0 -> seat 0 is ELIMINATED.
# 10 plays, 11 turns, 4 hits, 1 elimination, exactly 1 pile draw -> `_left` == [2,0,...] == 16 - 10 - 4.
const NOBLE_3P_PRINCE_HUMAN: Array[Deck.CardType] = [
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Prince,
	Deck.CardType.Guard, Deck.CardType.Prince, Deck.CardType.Prince, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.Guard, Deck.CardType.Countess, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_3P_PRINCE_HUMAN_LEFT: Array[int] = [11, 0, 0, 0, 4, 0, 1, 0]
const NOBLE_3P_PRINCE_HUMAN_END_LEFT: Array[int] = [2, 0, 0, 0, 0, 0, 0, 0]

# I4 (4p): seat 0 = Prince + [King, Guard, Countess], seat 3 = Guard + [PRINCE, PRINCE, Guard].
# T1 own tap + self-Prince (3 -> 1 family), T5 own tap (family 0), T8 seat 3's Prince hits a seat with
# family 0 and NO widow (4p burns nothing) -> seat 0 is ELIMINATED with no panel. Seat 1 follows him at
# play 11 (seat 3's Prince, family 0, no widow). 11 plays, 12 turns, 3 hits, 2 eliminations, 0 pile
# draws, out of play 11 + 3 = 14 -> `_left` == [2,0,0,0,0,0,0,0].
const NOBLE_4P_PRINCE_OUT_HUMAN: Array[Deck.CardType] = [
	Deck.CardType.Prince, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
	Deck.CardType.King, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Prince,
	Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Prince,
	Deck.CardType.Countess, Deck.CardType.Guard, Deck.CardType.Guard, Deck.CardType.Guard,
]
const NOBLE_4P_PRINCE_OUT_HUMAN_LEFT: Array[int] = [11, 0, 0, 0, 3, 1, 1, 0]
const NOBLE_4P_PRINCE_OUT_HUMAN_END_LEFT: Array[int] = [2, 0, 0, 0, 0, 0, 0, 0]


func _test_prince_human_modal() -> void:
	print("--- TEST I1 (4p, a self-Prince: the panel opens MID-EFFECT on an empty hand) ---")
	await _test_self_prince_modal()
	print("--- TEST I2 (4p, an AI's Prince hits the human: an AI turn opens HIS family) ---")
	await _test_ai_prince_human()
	print("--- TEST I3 (3p, family 0 -> the WIDOW, no panel; then family 0 + widow 0 -> out) ---")
	await _test_prince_widow_no_modal()
	print("--- TEST I4 (4p, family 0 and no widow exists -> out, no panel, no reveal) ---")
	await _test_prince_out_no_widow()


func _fam_names(p: Player) -> Array:
	var out: Array = []
	for t in p.family:
		out.append(Deck.card_names[int(t)].strip_edges())
	return out


func _tap_watcher(taps: Array) -> Dictionary:
	return {"frames": 0, "taps": taps, "openings": 0, "actors": [], "rows": [], "snaps": [],
		"tapped": [], "tables": [], "crow_rows": [], "crowded": 0, "hands": [], "fams": [],
		"hand_types": [], "ai_open": 0, "stop": false}


# The seat's hands, for a whole round: tap every opening, in queue order. A RISING EDGE of
# `is_open()` is one draw the production flow asked the human to take, so `openings` counts the
# draws and `tapped` is what he chose - the queue is the only source of taps in these fixtures.
func _tap_modal(main, w) -> void:
	var was := false
	var k := 0
	var taps: Array = w["taps"]
	while int(w["frames"]) < 9000 and not bool(w["stop"]):
		w["frames"] = int(w["frames"]) + 1
		var sel = main._family_selector
		var now: bool = sel.is_open()
		if now and not was:
			var p0 = main._players[0]
			var cards: Array = _fs_cards(sel)
			w["openings"] = int(w["openings"]) + 1
			w["actors"].append(int(main._cur_player))
			if int(main._cur_player) != 0:
				w["ai_open"] = int(w["ai_open"]) + 1
			w["rows"].append(_rn(cards))
			w["snaps"].append(_fam_names(p0))
			w["tables"].append(bool(main._table.visible))
			var crow: bool = main._type_selector.visible or main._select_other_player.visible \
				or main._select_any_player.visible
			w["crow_rows"].append(bool(crow))
			if crow:
				w["crowded"] = int(w["crowded"]) + 1
			w["hands"].append(int(p0.hand.get_child_count()))
			w["fams"].append(int(p0.family_size()))
			w["hand_types"].append(Deck.card_names[int(p0.hand.get_child(0).type)].strip_edges()
				if p0.hand.get_child_count() > 0 else "-")
			var idx: int = int(taps[k]) if k < taps.size() else -1
			if idx >= 0 and idx < cards.size():
				_fs_tap(cards[idx]["node"])
			w["tapped"].append(idx)
			k += 1
		was = now
		await get_tree().process_frame


# Start the hands BEFORE the deal settles (the first turn start opens the panel) and wait for the
# post-draw shape: 1 hand card + a full family in every AI seat, 2 cards + one spent family card in
# the human seat (the queue tapped his first turn start).
func _settle_taps(main, w) -> void:
	_tap_modal(main, w)
	await main.init_players(SEED)
	var fam: int = Deck.NOBLE_FAMILY_SIZE[int(main._player_count)]
	await await_until(func() -> bool:
		var ready := true
		for p in main._players:
			if p.is_active() and p.idx > 0:
				ready = ready and p.hand.get_child_count() == 1 and p.family_size() == fam
		return ready and main._players[0].hand.get_child_count() == 2 \
			and main._players[0].family_size() == fam - 1)


# The human plays a chosen HAND INDEX (0 = the active card, 1 = the card the modal drew), served by
# the tap queue (`draw_idx == -1`: the watcher owns the taps of this turn start). `_human_play` only
# plays index 0, and the Countess rule over a human's 2-card hand FORCES index 1 on a (King, Countess)
# pair - a harness that played index 0 there would be an ILLEGAL tap, which production forbids in
# `Player._on_card_input_event`. `Main._on_card_played()` is called directly (that is what a card tap
# emits), so the legality check the tap handler runs is replicated here as a check of its own.
func _human_play_idx(main, hand_idx: int, target: int, type: Deck.CardType, draw_idx: int,
		tag: String = "human play") -> void:
	var p = main._players[0]
	await _human_draw(main, draw_idx)
	await await_until(func() -> bool:
		return p._state == Player.State.SELECT_CARD and p.hand.get_child_count() == 2)
	if p._state != Player.State.SELECT_CARD or p.hand.get_child_count() != 2:
		# A fixture that diverges from the expected flow (a production path that draws FOR the human
		# instead of asking him shifts every tap of the queue): say it and stop, rather than crash
		# inside `countess_restricted()`, which indexes hand[1] and exists only over a 2-card hand.
		check(false, tag + ": the human seat never reached a 2-card hand in SELECT_CARD (state "
			+ str(p._state) + ", " + str(p.hand.get_child_count())
			+ " cards) - the harness stops here instead of indexing a hand that does not exist")
		return
	var forced: int = p.countess_restricted()
	check(forced == -1 or forced == hand_idx, "the human taps hand index " + str(hand_idx)
		+ ", the Countess rule forces " + str(forced) + " (-1 = free) - a tap on a card the rule forbids"
		+ " is ignored by `Player._on_card_input_event`, so the harness has to tap the forced card")
	await main._on_card_played(p.hand.get_child(hand_idx))
	if p._state == Player.State.INPUT_OTHER_P:
		await await_until(func() -> bool: return p._state == Player.State.INPUT_OTHER_P)
		await main._on_target_player_selected(target)
		if p._state == Player.State.INPUT_T:
			await main._on_target_type_selected(type)
	elif p._state == Player.State.INPUT_ANY_P:
		# Prince: any active non-protected seat, HIMSELF included (`_find_noble_moves` enumerates self)
		await main._on_target_player_selected(target)
	await await_until(func() -> bool: return main._cur_player != 0)


# The panel state a harness can only read from OUTSIDE a play chain: closed, invisible, no row, and
# the Table back - the "no modal leak" gate, run after every fixture.
func _check_no_leak(main, tag: String) -> void:
	var sel = main._family_selector
	check(not sel.is_open() and not bool(sel.visible) and int(sel.get_child_count()) == 1
		and _fs_cards(sel).is_empty(), tag + ": the panel is CLOSED, hidden, with no row left ("
		+ str(int(sel.get_child_count())) + " children) - a mid-effect modal that leaked would sit on"
		+ " the next round's board")
	check(bool(main._table.visible), tag + ": the Table is visible again - every surface the modal hid"
		+ " came back, so the Prince card on the table can be discarded")
	check(not main._type_selector.visible and not main._select_other_player.visible
		and not main._select_any_player.visible, tag + ": no selector panel is left open after the round")


func _test_self_prince_modal() -> void:
	var tag := "I1"
	var main = _scripted_main_human(4, NOBLE_4P_SELF_PRINCE, NOBLE_4P_HUMAN_PRINCE_LEFT)
	var w = _tap_watcher([1, 0, 0])
	await _settle_taps(main, w)
	var p0 = main._players[0]
	var fam: int = Deck.NOBLE_FAMILY_SIZE[4]
	check(w["openings"] == 1 and w["tapped"] == [1], tag + ": ONE opening served the deal - the turn-start"
		+ " draw, tapped at family index 1 (" + str(w["tapped"]) + ")")
	check(w["rows"][0] == w["snaps"][0] and w["rows"][0] == ["King", "Guard", "Countess"], tag
		+ ": the row is the family DATA in as-dealt order (" + str(w["rows"][0]) + ") - the modal is a view of"
		+ " `p.family`, it is not a copy Main has to keep in step")
	check(int(p0.hand.get_child_count()) == 2 and int(p0.family_size()) == fam - 1, tag + ": after the tapped"
		+ " draw the human holds 2 cards and his family is down to " + str(fam - 1) + ", i.e. the tap POPPED the"
		+ " card, it did not copy it")
	# play 1: the Prince on HIMSELF - `_find_noble_moves` enumerates self as a Prince target and
	# `Main._on_target_player_selected` accepts it under INPUT_ANY_P
	await _human_play_idx(main, 0, 0, Deck.CardType.Unknown, -1, tag)
	check(w["openings"] == 2 and w["actors"] == [0, 0], tag + ": the self-Prince opened the panel a SECOND"
		+ " time INSIDE the same play - the draw is a mid-effect draw of his OWN family, the only shape a"
		+ " self-targeted Prince can take")
	check(w["rows"][1] == ["King", "Countess"] and w["rows"][1] == w["snaps"][1], tag + ": the mid-effect row"
		+ " is the family MINUS the card he tapped 1 frame earlier (" + str(w["rows"][1])
		+ "), read as the seat's live data at that moment - the panel opened on what is LEFT, not on the"
		+ " family he was dealt")
	check(w["hands"][0] == 1 and w["hands"][1] == 0, tag + ": the human's hand was " + str(w["hands"][0])
		+ " card at the turn-start opening and " + str(w["hands"][1])
		+ " cards at the mid-effect opening - the Prince has ALREADY taken his card out of play (reveal +"
		+ " discard), so the panel draws on an empty hand: the draw REPLACES the card the Prince took, it"
		+ " never adds to a 2-card hand (the 1-card invariant)")
	check(w["fams"] == [3, 2] and w["fams"][1] == fam - 1, tag + ": the family went " + str(w["fams"])
		+ " - one card per tap, and the effect ran while the family still held a card, which is what picks"
		+ " the panel over the widow / elimination chain")
	check(w["tables"] == [false, false] and int(w["crowded"]) == 0, tag + ": at BOTH openings the Table is"
		+ " hidden and NO other selector panel is visible (" + str(w["crow_rows"])
		+ ") - mid-effect is exactly as clean as a turn start: no TypeSelector, no player picker, and no"
		+ " tap can reach the hand behind the panel")
	check(w["tapped"] == [1, 0], tag + ": the taps are " + str(w["tapped"]) + " - he kept the King out of the"
		+ " mid-effect row [King, Countess]")
	check(main.family_draw_idx[0] == w["tapped"], tag + ": every tap was an INDEX draw ("
		+ str(main.family_draw_idx[0]) + ") - `Main` popped `family[idx]`, the panel reported an index")
	check(int(p0.hand.get_child_count()) == 1 and int(p0.family_size()) == 1, tag + ": after the whole play"
		+ " chain the human holds EXACTLY 1 card and his family is 1 - the 1-card invariant through a"
		+ " mid-effect modal, and the family did not shrink twice (1 draw per tap)")
	check(int(p0.hand.get_child(0).type) == int(Deck.CardType.King), tag + ": the card in his hand is the KING"
		+ " he tapped in the modal - the panel delivers the card he picked, it cannot invent, add, reorder or"
		+ " duplicate one")
	var recs1: Array = main.effect_log
	check(recs1.size() == 1 and int(recs1[0]["played"]) == int(Deck.CardType.Prince)
		and int(recs1[0]["target"]) == 0, tag + ": play 1 is the Prince on seat 0 HIMSELF (target "
		+ str(recs1[0]["target"]) + ") - a self-Prince is a legal Prince target")
	check(int(recs1[0]["before"]["fams"][0]) == 2 and int(recs1[0]["after"]["fams"][0]) == 1, tag
		+ ": around the effect his family went " + str(recs1[0]["before"]["fams"][0]) + " -> "
		+ str(recs1[0]["after"]["fams"][0])
		+ ": the turn-start draw already spent family index 1, and the mid-effect draw spent one more"
		+ " inside the same effect, so the effect's family deltas show BOTH draws and no phantom draw")
	check(int(recs1[0]["before"]["left"][int(Deck.CardType.Prince)]) == 1
		and int(recs1[0]["after"]["left"][int(Deck.CardType.Prince)]) == 0, tag + ": the Prince left the"
		+ " supply by the PLAY (-1), the self-victim's Guard left by the Prince branch's `discard` (-1), and"
		+ " the King he drew out of the modal moved hand <- family, which changes `_left` NOT AT ALL: after"
		+ " play 1 _left == " + str(main._deck._left))
	check(int(recs1[0]["after"]["left"][int(Deck.CardType.Guard)]) == 12
		and int(recs1[0]["after"]["left"][int(Deck.CardType.King)]) == 1
		and int(recs1[0]["after"]["hands"][0]) == 1 and bool(recs1[0]["after"]["active"][0]), tag
		+ ": the 13th Guard left play as the self-Prince victim card, the King is still in his hand (1 card)"
		+ " and seat 0 is still ACTIVE - a self-Prince with a card to draw is a hit, not an elimination")
	check(main.eliminations == 0 and main.pile_draws == 0 and int(main._deck._widow_cards.size()) == 0, tag
		+ ": 0 eliminations, 0 pile draws and a 0-card widow (4p burns nothing) - a human target with a"
		+ " non-empty family is served by the modal ONLY: the pile is never touched, so the modal cannot"
		+ " smuggle a main-pile card into his hand")
	# play 5 (seat 0's next turn): family [Countess] -> hand [King, Countess] -> the Countess rule
	# FORCES the Countess (index 1), which is why this play taps index 1 and not index 0
	await _human_play_idx(main, 1, -1, Deck.CardType.Unknown, -1, tag)
	check(w["openings"] == 3 and w["tapped"] == [1, 0, 0] and w["rows"][2] == ["Countess"], tag
		+ ": the third opening is a plain turn start on the LAST family card (" + str(w["rows"][2])
		+ ") - 3 openings for 3 family cards, i.e. the panel is the only family-draw path a human seat has")
	check(w["hand_types"][2] == "King" and w["hands"][2] == 1, tag + ": at the turn-start opening his hand is"
		+ " 1 card, the King - the card he tapped out of the mid-effect panel is the card he plays with 4"
		+ " turns later, so a Prince redraw feeds his NEXT plays and not his current one")
	var recs5: Array = main.effect_log
	check(recs5.size() == 5 and int(recs5[4]["played"]) == int(Deck.CardType.Countess)
		and int(recs5[4]["target"]) == -1, tag + ": play 5 is the COUNTRESS (target -1 = self, the variant"
		+ " pairing rule) - a (King, Countess) hand cannot keep the King")
	check(int(recs5[4]["before"]["fams"][0]) == 0 and int(recs5[4]["after"]["fams"][0]) == 0, tag
		+ ": play 5's effect sees the family at 0 -> 0: the turn start tapped out the LAST family card BEFORE"
		+ " the play was made, so a family draw is never an effect's family delta - the only family deltas a"
		+ " round produces are mid-effect Prince redraws, which is exactly what the panel draws are")
	check(int(main._deck._left[int(Deck.CardType.Countess)]) == 0
		and int(main._deck._left[int(Deck.CardType.King)]) == 1, tag + ": the Countess left play by the"
		+ " play, the King is in his hand and out of the supply: after play 5 _left == "
		+ str(main._deck._left))
	var recs: Array = await _run_to_first_round_end(main)
	w["stop"] = true
	await await_frames(2)
	check(int(w["openings"]) == 3, tag + ": 3 panel openings in the WHOLE round, all served by a tap - no"
		+ " turn start and no mid-effect draw of this round opened a 4th one")
	check(w["actors"] == [0, 0, 0] and int(w["ai_open"]) == 0, tag + ": every opening happened on the"
		+ " HUMAN's own turn (" + str(w["actors"]) + ") - a self-Prince keeps the acting seat at 0, so"
		+ " `Main` reads `_cur_player` as the human and the modal is his")
	check(main.eliminations == 0 and main.pile_draws == 0, tag + ": the whole round: 0 eliminations, 0 pile"
		+ " draws - 8 plays, 9 turns, the human's 3 family draws (2 mid-effect + turn starts) all went"
		+ " through the panel")
	check(int(main.round_end_actor[0]) == 0, tag + ": the round ended on seat 0's turn start with an empty"
		+ " family (actor " + str(main.round_end_actor) + ") - the family is the round's clock, and the"
		+ " human's clock ran out through TAPPED draws only")
	check(recs.size() == 8, tag + ": 8 plays in the round (" + str(recs.size())
		+ "), the human's 2 (the Prince, the Countess) and 2 per AI seat")
	check(int(main._players[0].score) == 1 and int(main._players[1].score) == 0
		and int(main._players[2].score) == 0 and int(main._players[3].score) == 0, tag + ": the human WON"
		+ " the round with the King he tapped out of the mid-effect panel (scores " + str(main._players[0].score)
		+ " " + str(main._players[1].score) + " " + str(main._players[2].score) + " "
		+ str(main._players[3].score) + ") - the cards a human picks in the modal are the cards that score"
		+ " for him, so a mid-effect modal is a decision, not a cutscene")
	_check_effect_log_basics(recs, main)
	_check_left_end(recs, NOBLE_4P_SELF_PRINCE_END_LEFT, tag)
	_check_left_audit(main, tag)
	_check_pairings(main)
	_check_no_leak(main, tag)
	var settle: int = 0
	while settle < 200:
		await get_tree().process_frame
		settle += 1
	check(int(w["openings"]) == 3 and int(settle) == 200 and not main._family_selector.is_open()
		and main.family_draw_idx[0].size() == 3, tag + ": " + str(settle) + " frames of the round-end state"
		+ " opened NO panel and drew NO family card (" + str(main.family_draw_idx[0])
		+ ") - the Prince redraw reopens the panel inside an effect, it does not reopen it on the round-end"
		+ " state")
	main.queue_free()
	await await_frames(2)


func _test_ai_prince_human() -> void:
	var tag := "I2"
	var main = _scripted_main_human(4, NOBLE_4P_AI_PRINCE, NOBLE_4P_HUMAN_PRINCE_LEFT)
	var w = _tap_watcher([0, 1, 0])
	await _settle_taps(main, w)
	var p0 = main._players[0]
	# play 1: the human's Guard on seat 1, declaring Priest - seat 1 holds the Prince, so it misses
	await _human_play_idx(main, 0, 1, Deck.CardType.Priest, -1, tag)
	check(w["openings"] == 1 and w["actors"] == [0] and w["rows"][0] == w["snaps"][0], tag
		+ ": the only opening so far is his OWN turn start (" + str(w["rows"][0])
		+ "), tapped at family index 0 (the King)")
	# seat 1 is level 1: his first valid Prince move targets the lowest-index live unprotected seat,
	# seat 0 - the panel opens MID-EFFECT ON SEAT 1'S TURN, on the human's family, and seat 1 has no
	# way to pick for him: the tap below is the harness tapping the human's panel.
	await await_until(func() -> bool: return int(w["openings"]) >= 2)
	check(int(w["openings"]) == 2 and int(w["actors"][1]) == 1 and int(w["ai_open"]) == 1, tag
		+ ": the second opening happened on an AI TURN (" + str(w["actors"])
		+ ") - seat 1's Prince aimed at seat 0 opened the human's panel, so a mid-effect family draw is"
		+ " the human's choice even when an AI's play caused it")
	check(w["rows"][1] == ["Guard", "Countess"] and w["rows"][1] == w["snaps"][1], tag + ": the row is the"
		+ " HUMAN's family data as it stands inside seat 1's effect (" + str(w["rows"][1])
		+ ") - the King he tapped at his own turn start is gone from the data, the panel shows what the"
		+ " seat has NOW, and an AI turn never shows the AI's family here (seat 1's family is 3 Guards,"
		+ " none of them in this row)")
	check(w["hands"][1] == 0 and w["fams"] == [3, 2], tag + ": at that opening the human's hand is 0 cards"
		+ " and his family is 2 (" + str(w["fams"]) + ") - the Prince compared his card, took it out of"
		+ " play, and the panel draws the replacement, so the draw is a REDRAW and never a 2-card hand"
		+ " mid-effect")
	await await_until(func() -> bool:
		return main.effect_log.size() >= 2 and p0.hand.get_child_count() == 1)
	check(main.effect_log.size() == 2 and int(main.effect_log[1]["played"]) == int(Deck.CardType.Prince)
		and int(main.effect_log[1]["target"]) == 0, tag + ": play 2 is seat 1's Prince on seat 0 ("
		+ str(main.effect_log[1]["target"]) + ") - a human target with a non-empty family is HIT, not"
		+ " eliminated")
	check(int(main.effect_log[1]["before"]["fams"][0]) == 2 and int(main.effect_log[1]["after"]["fams"][0]) == 1,
		tag + ": the effect's family deltas are 2 -> 1: the draw the human made IN THE PANEL is the"
		+ " effect's redraw, attributed to this play, so an AI Prince never picks a card for a human seat"
		+ " and never skips the redraw")
	check(int(main.effect_log[1]["after"]["hands"][0]) == 1 and int(main.effect_log[1]["before"]["hands"][0]) == 1,
		tag + ": the target's hand is 1 card BEFORE the hit (the King) and 1 card after (the Countess) -"
		+ " a hit discards and replaces, the hand never passes through 2")
	# His NEXT turn start is the 3rd opening, and it comes after seat 2's and seat 3's turns: a fixture
	# that reads the 3rd opening's row before those turns ran reads an array with 2 entries.
	await await_until(func() -> bool: return int(w["openings"]) >= 3)
	var ht: Array = w["hand_types"]
	var third_type: String = str(ht[2]) if ht.size() > 2 else "<no 3rd opening>"
	check(ht.size() == 3 and third_type == "Countess" and w["tapped"] == [0, 1, 0]
		and str(ht[1]) == "-", tag + ": the mid-effect tap was family index 1 -> the COUNTRESS is his"
		+ " active card at his next turn start (" + str(ht) + ", taps " + str(w["tapped"])
		+ ") - the panel delivered the card he picked out of the row [Guard, Countess], i.e. index 1"
		+ " means the 2nd card of the data, not the 2nd card of a sort")
	check(main.pile_draws == 0 and int(main._deck._widow_cards.size()) == 0, tag + ": 0 pile draws and a"
		+ " 0-card widow (4p burns nothing) - the widow is the FALLBACK pile and a family that has cards"
		+ " never lets a pile card near a human hand")
	check(w["tables"] == [false, false, false] and int(w["crowded"]) == 0, tag + ": the Table was hidden at"
		+ " all 3 openings and no other selector panel was ever visible (" + str(w["crow_rows"])
		+ ") - the Prince card sits on the table at the mid-effect opening, so hiding the Table is what"
		+ " keeps the modal a single question")
	# play 5 (seat 0's next turn): family [Guard] -> hand [Countess, Guard] -> the Countess rule forces
	# index 0, i.e. he plays the Countess he tapped out of the mid-effect panel
	await _human_play_idx(main, 0, -1, Deck.CardType.Unknown, -1, tag)
	var recs: Array = await _run_to_first_round_end(main)
	w["stop"] = true
	await await_frames(2)
	check(int(w["openings"]) == 3 and w["rows"][2] == ["Guard"] and w["fams"] == [3, 2, 1], tag
		+ ": 3 openings for 3 family cards, the last one a plain turn start on the 1 card left - every"
		+ " family card of a human seat is spent by a tap, mid-effect draws included")
	check(main.family_draw_idx[0] == w["tapped"], tag + ": every one of his family draws is a TAPPED index"
		+ " (" + str(main.family_draw_idx[0]) + ") - no family card of a human seat is picked by code")
	check(recs.size() == 8 and int(main.round_end_actor[0]) == 0, tag + ": 8 plays, 9 turns, the round ended"
		+ " on seat 0's turn start with an empty family (actor " + str(main.round_end_actor)
		+ ") - 1 hit (seat 1's Prince), 0 eliminations, the family the clock")
	check(main.eliminations == 0 and main.pile_draws == 0, tag + ": the whole round: 0 eliminations and 0"
		+ " pile draws - a human target with a 2-card family took the modal path, not the widow path")
	_check_effect_log_basics(recs, main)
	_check_left_end(recs, NOBLE_4P_AI_PRINCE_END_LEFT, tag)
	_check_left_audit(main, tag)
	_check_pairings(main)
	_check_no_leak(main, tag)
	await await_frames(200)
	check(int(w["openings"]) == 3 and not main._family_selector.is_open(), tag
		+ ": 200 frames of the round-end state opened no 4th panel - an AI turn can OPEN a human's panel"
		+ " (a Prince hit), it cannot keep reopening one")
	main.queue_free()
	await await_frames(2)


func _test_prince_widow_no_modal() -> void:
	var tag := "I3"
	var main = _scripted_main_human(3, NOBLE_3P_PRINCE_HUMAN, NOBLE_3P_PRINCE_HUMAN_LEFT)
	var w = _tap_watcher([0, 1, 1, 0])
	await _settle_taps(main, w)
	check(w["openings"] == 1 and w["rows"][0] == ["Guard", "Guard", "Guard", "Countess"], tag
		+ ": the turn-start row is the FULL 4-card family in as-dealt order, the Countess LAST - the panel"
		+ " never sorts a row, so a tap that picks the 2nd card of the row is the 2nd card of the data")
	# play 1: the human's Guard on seat 1, declaring Priest (seat 1 holds the Prince -> miss)
	await _human_play_idx(main, 0, 1, Deck.CardType.Priest, -1, tag)
	await await_until(func() -> bool: return int(w["openings"]) >= 2)
	check(w["openings"] == 2 and w["tapped"] == [0, 1] and w["rows"][1] == ["Guard", "Guard", "Countess"],
		tag + ": seat 1's Prince hit him mid-effect and the row shrank to the 3 cards LEFT after his"
		+ " turn-start tap (" + str(w["rows"][1]) + "), tapped at index 1 - the MIDDLE Guard, which only"
		+ " an index-reporting panel can pick out of a row of identical cards")
	await _human_play_idx(main, 0, -1, Deck.CardType.Unknown, -1, tag)
	check(int(w["openings"]) == 4 and w["rows"] == w["snaps"], tag + ": 4 openings, each row equal to the"
		+ " seat's live family data at that moment " + str(w["rows"]) + " - 4 cards, 3, 2, 1: the panel"
		+ " drained his family one tap at a time (2 hits, 2 turn starts), and no row ever showed a card"
		+ " the data did not hold")
	check(w["rows"][3] == ["Guard"] and w["tapped"] == [0, 1, 1, 0] and w["fams"] == [4, 3, 2, 1], tag
		+ ": the taps " + str(w["tapped"]) + " drained the family to 0 (" + str(w["fams"])
		+ ") and the last row was the 1 remaining Guard - the Countess left the family at the T3 hit's tap"
		+ " (index 1 of [Guard, Countess])")
	check(main.family_draw_idx[0] == w["tapped"], tag + ": all 4 family draws are index draws ("
		+ str(main.family_draw_idx[0]) + ") - every family card of a human seat leaves the data through a"
		+ " tap, including the 2 mid-effect Prince redraws")
	check(w["hands"] == [1, 0, 0, 1] and w["hand_types"][3] == "Countess", tag + ": his hand at the 4"
		+ " openings was " + str(w["hands"]) + " cards, the 4th opening's active card being the Countess -"
		+ " a hit leaves the hand at 0 cards and the panel draw replaces the compared card (the 1-card"
		+ " invariant through 2 mid-effect modals)")
	var recs: Array = await _run_to_first_round_end(main)
	w["stop"] = true
	await await_frames(2)
	check(recs.size() == 10 and int(main.round_end_actor[0]) == 1, tag + ": 10 plays, 11 turns, the round"
		+ " ended on seat 1's turn start with an empty family (actor " + str(main.round_end_actor)
		+ ") - seat 0 left the board at play 6, so his clock cannot end the round")
	check(int(w["openings"]) == 4, tag + ": 4 openings in the WHOLE round, all of them before the"
		+ " elimination - the family emptied tap by tap, and every path that followed it ran WITHOUT a panel")
	# play 5 (T5): family 0, the widow has its 1 card -> the pile fallback, no panel
	check(int(recs[4]["played"]) == int(Deck.CardType.Prince) and int(recs[4]["target"]) == 0
		and int(recs[4]["before"]["fams"][0]) == 0 and int(recs[4]["before"]["widow"]) == 1
		and int(recs[4]["after"]["widow"]) == 0 and int(recs[4]["after"]["hands"][0]) == 1
		and bool(recs[4]["after"]["active"][0]), tag + ": play 5 hit a seat with family 0 and the 1-card"
		+ " widow, so the widow drew for him (widow 1 -> 0, hand 0 -> 1, seat 0 still ACTIVE) - an empty"
		+ " family is NEVER a page: `open([])` refuses to open and the fallback pile is a pile draw, not a"
		+ " choice the human makes")
	# play 6 (T6): family 0 AND widow 0 -> eliminated
	check(int(recs[5]["played"]) == int(Deck.CardType.Prince) and int(recs[5]["target"]) == 0
		and int(recs[5]["before"]["fams"][0]) == 0 and int(recs[5]["before"]["widow"]) == 0
		and not bool(recs[5]["after"]["active"][0]) and int(recs[5]["after"]["hands"][0]) == 0, tag
		+ ": play 6 hit a seat with family 0 and widow 0 -> seat 0 is ELIMINATED (active false, hand 0) -"
		+ " no panel, no pile card, no card in hand, exactly the step 15 chain")
	check(main.eliminations == 1 and main.eliminated_seats == [0], tag + ": 1 elimination, seat 0, at play 6"
		+ " - the human seat left the board through the fallback chain, not through a modal")
	check(main.pile_draws == 1 and int(main._deck._widow_cards.size()) == 0, tag + ": exactly ONE pile draw"
		+ " in the round (the widow at play 5) and a 0-card widow at the round end - the widow is 1 card"
		+ " in 3p and it is spent by ONE hit, so a second hit finds nothing")
	check(main.reveal_calls == 1 and main.reveal_log.size() == 1
		and int(main.reveal_log[0]["seat"]) == 0 and int(main.reveal_log[0]["family_size"]) == 0
		and _rn(main.reveal_log[0]["cards"]).is_empty(), tag + ": the elimination called the reveal ONCE"
		+ " and materialized 0 cards (container " + str(main.reveal_log[0]["container"])
		+ ", family_size 0) - an eliminated seat whose family is already empty reveals NOTHING and opens"
		+ " NO modal: the panel is not a reveal, and the reveal is not a panel")
	_check_effect_log_basics(recs, main)
	_check_left_end(recs, NOBLE_3P_PRINCE_HUMAN_END_LEFT, tag)
	_check_left_audit(main, tag)
	_check_pairings(main)
	_check_no_leak(main, tag)
	await await_frames(200)
	check(int(w["openings"]) == 4 and main.family_draw_idx[0] == [0, 1, 1, 0]
		and not main._family_selector.is_open(), tag + ": 200 frames after the round end the panel is"
		+ " closed, the human drew NO 5th family card and opened no panel - an out seat has no family, the"
		+ " widow is spent and the round is over")
	main.queue_free()
	await await_frames(2)


func _test_prince_out_no_widow() -> void:
	var tag := "I4"
	var main = _scripted_main_human(4, NOBLE_4P_PRINCE_OUT_HUMAN, NOBLE_4P_PRINCE_OUT_HUMAN_LEFT)
	var w = _tap_watcher([1, 0, 0])
	await _settle_taps(main, w)
	# play 1: the human's Prince on himself, served by the panel (turn start tap 1 = Guard, then the
	# mid-effect row [King, Countess], tap 0 = the King)
	await _human_play_idx(main, 0, 0, Deck.CardType.Unknown, -1, tag)
	check(w["openings"] == 2 and w["actors"] == [0, 0] and w["rows"][1] == ["King", "Countess"], tag
		+ ": the self-Prince opened the panel on his own family mid-effect (" + str(w["rows"][1])
		+ "), tapped 1 frame into the same play - the King he keeps came out of a modal, not out of a"
		+ " pile, a widow or a dealt family")
	# play 5: family [Countess] -> hand [King, Countess] -> the Countess rule FORCES index 1
	await _human_play_idx(main, 1, -1, Deck.CardType.Unknown, -1, tag)
	check(int(w["openings"]) == 3 and w["tapped"] == [1, 0, 0] and main.family_draw_idx[0] == [1, 0, 0],
		tag + ": 3 openings, 3 taps, 3 family cards - his whole 3-card family left the data through the"
		+ " panel, 2 of them inside Prince effects")
	var recs: Array = await _run_to_first_round_end(main)
	w["stop"] = true
	await await_frames(2)
	check(recs.size() == 11 and int(main.round_end_actor[0]) == 2, tag + ": 11 plays, 12 turns, the round"
		+ " ended on seat 2's turn start with an empty family (actor " + str(main.round_end_actor)
		+ ") - seats 0 and 1 are out, so seats 2 and 3 close the round")
	check(int(recs[7]["played"]) == int(Deck.CardType.Prince) and int(recs[7]["target"]) == 0
		and int(recs[7]["before"]["fams"][0]) == 0 and int(recs[7]["before"]["widow"]) == 0
		and not bool(recs[7]["after"]["active"][0]) and int(recs[7]["after"]["hands"][0]) == 0, tag
		+ ": play 8 (seat 3's Prince) hit seat 0 with family 0 and widow 0 - 4p burns NOTHING, so no widow"
		+ " exists and the elimination is the only path: active false, hand 0, no pile draw")
	check(int(recs[10]["played"]) == int(Deck.CardType.Prince) and int(recs[10]["target"]) == 1
		and int(recs[10]["before"]["fams"][1]) == 0
		and not bool(recs[10]["after"]["active"][1]), tag + ": play 11 (seat 3's 2nd Prince) hit seat 1 the"
		+ " same way (family 0, no widow) - the chain is not a human-seat special case: any seat with no"
		+ " family card and no widow card is out")
	check(main.eliminations == 2 and main.eliminated_seats == [0, 1], tag + ": 2 eliminations, seats "
		+ str(main.eliminated_seats) + " - both hits found an empty family and no widow")
	check(int(w["openings"]) == 3 and int(w["ai_open"]) == 0, tag + ": 3 openings in the WHOLE round and 0"
		+ " of them on an AI turn - a 4p elimination opens NO panel for anybody: the modal is a family that"
		+ " has cards, nothing else")
	check(main.pile_draws == 0 and int(main._deck._widow_cards.size()) == 0, tag + ": 0 pile draws and 0"
		+ " widow cards the whole round - 4p has no widow pile, so the fallback chain goes family -> out")
	check(main.reveal_calls == 2 and main.reveal_log.size() == 2
		and _rn(main.reveal_log[0]["cards"]).is_empty() and _rn(main.reveal_log[1]["cards"]).is_empty(), tag
		+ ": 2 reveal calls, 0 cards each (families " + str([main.reveal_log[0]["family_size"],
		main.reveal_log[1]["family_size"]]) + ") - both seats drained their families through the panel"
		+ " before they were hit, so there is no family left to publish: the modal consumed the reveal's"
		+ " material")
	_check_effect_log_basics(recs, main)
	_check_left_end(recs, NOBLE_4P_PRINCE_OUT_HUMAN_END_LEFT, tag)
	_check_left_audit(main, tag)
	_check_pairings(main)
	_check_no_leak(main, tag)
	await await_frames(200)
	check(int(w["openings"]) == 3 and main.family_draw_idx[0].size() == 3
		and not main._family_selector.is_open(), tag + ": 200 frames of the round-end state: no panel, no"
		+ " family draw, no reveal - the family draw modal reopens inside effects only, and an elimination"
		+ " ends its seat's share of them")
	main.queue_free()
	await await_frames(2)



# ----------------------------------------------------------------------------------------
# TEST J (todo step 22): the MODAL / INPUT GUARD RAILS
#
# Steps 20 and 21 made a human family draw a COROUTINE: `human_draw_from_family()` opens the panel
# and suspends the whole play chain on `await draw_selected`. Everything step 22 promises follows
# from that one suspension, and `Main` now exposes its state to prove it (main.gd):
#
#   `_drawing`   - a family draw is PENDING. `is_drawing()` is the single source of truth for "the
#                  human seat is choosing right now", so the exclusivity gate is a per-frame equality
#                  a harness can sample: `is_drawing() == _family_selector.is_open()`.
#   `_draw_idx`  - what the guarded listener latches. A stray emission (a double tap, a tap on a
#                  closing panel) cannot queue a second draw: the listener drops it, and the index
#                  Main pops is the one the seat's own tap carried.
#
# J1 samples EVERY frame of a 2-round human game (not just the openings, as TESTS H and I do):
#  - `mismatch`  - frames where `is_drawing()` and `is_open()` disagree (the todo's exclusivity gate)
#  - `crowded`   - frames with the panel open AND the Table / a type selector / a target label / the
#                  player-selection sprite visible (the todo's "no stuck overlays": one surface)
#  - `leak`      - frames with a closed panel left visible, `row_leak` frames with a closed panel
#                  still holding its row of family cards
#  - the taps, the rows, the seat's hand and family at each opening (the todo's "no double draws")
# The game itself covers four of the five manual surfaces of step 22's Check line in ONE human game:
# a self-Prince (a MID-EFFECT modal, on his own turn), a Guard (target + type selectors), a King
# (the swap) and a Baron (the reveal and the comparison). The fifth, the Countess-forced play, is
# I1's play 5 in this same suite (the (King, Countess) hand that forces index 1).
#
# J2  the rails are INERT: a card play, a target tap, a type tap and a chosen move, fired at the
#     gate by a harness, start no chain, move no card, close no panel - and the pending draw survives.
# J3  re-entrancy: a nested draw request (the same chain asking twice) opens NO second modal, pops
#     nothing and cannot re-build the row the seat is looking at; the pending draw survives.
# J4  the listener's guard: with no draw pending an emission is dropped (`_draw_idx` untouched), and
#     a latched index from an out-of-the-blue emission cannot rename the card his tap drew.
# J5  the anti-deadlock rail: an index Main cannot pop (only a sabotage can produce it: the panel
#     only ever emits an index of its own row, G2) takes family[0] - a turn that never draws never
#     ends, so a stalled mandatory draw is the worse failure.
# J6  closed on every exit path: the turn-start commit, the mid-effect Prince commit, a NEW GAME
#     (`init_players`, the menu/Exit path: a suspended await never resumes, so the panel would sit on
#     the menu) and a NEW ROUND (`_new_round` re-deals the family - a row of the old family is a
#     menu of cards that no longer exist).
# ----------------------------------------------------------------------------------------

# 4p burns NOTHING and keeps no widow, so the deal is: 4 first-hand cards (idx 0..3), then 3 family
# columns, seat s column c = idx 4 + 4*c + s, and the main pile is EMPTY (16 - 4 - 12 == 0).
# Seat 0 (human): King + [Prince, Baron, Guard]. Seats 1..3: Guard + [Guard x3].
# Seat 0's round: tap the Prince (turn start), play it on HIMSELF (the mid-effect modal takes the
# Baron), tap the Guard, play the BARON on seat 1 with the Guard he kept (Guard vs Guard: a TIE, so
# the compare publishes seat 1's family and eliminates nobody).
const NOBLE_4P_RAILS: Array[Deck.CardType] = [
	Deck.CardType.King,     # 0  s0 first hand
	Deck.CardType.Guard,    # 1  s1 first hand
	Deck.CardType.Guard,    # 2  s2 first hand
	Deck.CardType.Guard,    # 3  s3 first hand
	Deck.CardType.Prince,   # 4  s0 family 0
	Deck.CardType.Guard,    # 5  s1 family 0
	Deck.CardType.Guard,    # 6  s2 family 0
	Deck.CardType.Guard,    # 7  s3 family 0
	Deck.CardType.Baron,    # 8  s0 family 1
	Deck.CardType.Guard,    # 9  s1 family 1
	Deck.CardType.Guard,    # 10 s2 family 1
	Deck.CardType.Guard,    # 11 s3 family 1
	Deck.CardType.Guard,    # 12 s0 family 2
	Deck.CardType.Guard,    # 13 s1 family 2
	Deck.CardType.Guard,    # 14 s2 family 2
	Deck.CardType.Guard,    # 15 s3 family 2
]
const NOBLE_4P_RAILS_LEFT: Array[int] = [13, 0, 1, 0, 1, 1, 0, 0]  # 13 Guard, 1 Baron, 1 Prince, 1 King
# The taps, in opening order: round 1 = turn start (Prince), the self-Prince's mid-effect row
# [Baron, Guard] (Baron), the last family card (Guard); round 2 = turn start (Prince), the AI
# Prince's mid-effect row [Baron, Guard] (GUARD, index 1), the last family card (Baron).
const NOBLE_4P_RAILS_TAPS: Array[int] = [0, 0, 0, 0, 1, 0]


func _test_modal_rails() -> void:
	print("--- TEST J1 (4p, 2 rounds: the per-frame exclusivity rails of a whole human game) ---")
	await _test_rails_game()
	print("--- TEST J2 (the rails are inert: taps and handler calls under the panel do nothing) ---")
	await _test_rails_inert()
	print("--- TEST J3 (re-entrancy: a nested draw request opens no second modal) ---")
	await _test_rails_reentrant()
	print("--- TEST J4 (the guarded listener: no pending draw, no latched index) ---")
	await _test_rails_listener_guard()
	print("--- TEST J5 (a sabotage index Main cannot pop takes family[0], the turn never stalls) ---")
	await _test_rails_bad_index()
	print("--- TEST J6 (closed on every exit path: commit, mid-effect, new game, new round) ---")
	await _test_rails_exit_paths()


# The per-frame watcher (a coroutine): it samples EVERY frame, and taps every opening from the queue,
# so it is the only source of taps in this fixture and it sees the frames TESTS H and I sample between.
func _rail_watcher(taps: Array) -> Dictionary:
	return {"frames": 0, "taps": taps, "k": 0, "stop": false,
		"openings": 0, "open_frames": 0, "mismatch": 0, "crowded": 0, "leak": 0, "row_leak": 0,
		"actors": [], "rows": [], "snaps": [], "tapped": [], "hands": [], "fams": [], "tables": [],
		"states": []}


func _watch_rails(main, w) -> void:
	var was := false
	while int(w["frames"]) < 20000 and not bool(w["stop"]):
		w["frames"] = int(w["frames"]) + 1
		var sel = main._family_selector
		var open: bool = sel.is_open()
		if open:
			w["open_frames"] = int(w["open_frames"]) + 1
		if open != main.is_drawing():
			w["mismatch"] = int(w["mismatch"]) + 1
		if open and (main._table.visible or main._type_selector.visible
				or main._select_other_player.visible or main._select_any_player.visible
				or bool(main._player_selection.visible)):
			w["crowded"] = int(w["crowded"]) + 1
		if not open:
			if bool(sel.visible):
				w["leak"] = int(w["leak"]) + 1
			if int(sel.get_child_count()) > 1:
				w["row_leak"] = int(w["row_leak"]) + 1
		if open and not was:
			var p0 = main._players[0]
			var cards: Array = _fs_cards(sel)
			w["openings"] = int(w["openings"]) + 1
			w["actors"].append(int(main._cur_player))
			w["rows"].append(_rn(cards))
			w["snaps"].append(_fam_names(p0))
			w["hands"].append(int(p0.hand.get_child_count()))
			w["fams"].append(int(p0.family_size()))
			w["tables"].append(bool(main._table.visible))
			w["states"].append(int(p0._state))
			var k: int = int(w["k"])
			var idx: int = int(w["taps"][k]) if k < w["taps"].size() else -1
			if idx >= 0 and idx < cards.size():
				_fs_tap(cards[idx]["node"])
			w["tapped"].append(idx)
			w["k"] = k + 1
		was = open
		await get_tree().process_frame


func _rails_settle(main, w) -> void:
	_watch_rails(main, w)
	await main.init_players(SEED)
	var fam: int = Deck.NOBLE_FAMILY_SIZE[int(main._player_count)]
	await await_until(func() -> bool:
		var ready := true
		for p in main._players:
			if p.is_active() and p.idx > 0:
				ready = ready and p.hand.get_child_count() == 1 and p.family_size() == fam
		return ready and main._players[0].hand.get_child_count() == 2 \
			and main._players[0].family_size() == fam - 1)


func _test_rails_game() -> void:
	var tag := "J1"
	var main = _scripted_main_human(4, NOBLE_4P_RAILS, NOBLE_4P_RAILS_LEFT)
	var w = _rail_watcher(NOBLE_4P_RAILS_TAPS)
	await _rails_settle(main, w)
	var p0 = main._players[0]

	# ---- round 1: the self-Prince (a mid-effect modal) and the Baron (the reveal + compare) ----
	await _human_play_idx(main, 1, 0, Deck.CardType.Unknown, -1, tag + " r1 play 1")
	var r1a: Array = main.effect_log
	check(r1a.size() == 1 and int(r1a[0]["played"]) == int(Deck.CardType.Prince)
		and int(r1a[0]["target"]) == 0, tag + ": play 1 is the Prince on seat 0 HIMSELF - a mid-effect"
		+ " modal of his OWN family, on HIS turn, inside the play chain that is suspended on it")
	check(int(r1a[0]["before"]["fams"][0]) == 2 and int(r1a[0]["after"]["fams"][0]) == 1, tag
		+ ": the effect's family deltas are 2 -> 1: the turn-start tap spent family[0] (the Prince) and"
		+ " the mid-effect tap spent one more INSIDE the same effect - one family pop per tap, no phantom"
		+ " draw, and the mid-effect draw is attributed to this play")
	check(int(r1a[0]["after"]["hands"][0]) == 1 and bool(r1a[0]["after"]["active"][0]), tag
		+ ": after the mid-effect modal the human holds EXACTLY 1 card and is still active - the modal"
		+ " REPLACES the card the Prince took, it never adds to a 2-card hand")
	check(not main._family_selector.is_open() and not bool(main._family_selector.visible)
		and _fs_cards(main._family_selector).is_empty() and not main.is_drawing(), tag
		+ ": the mid-effect modal CLOSED on its commit (open " + str(main._family_selector.is_open())
		+ ", visible " + str(bool(main._family_selector.visible)) + ", row "
		+ str(_fs_cards(main._family_selector).size()) + " cards, drawing " + str(main.is_drawing())
		+ ") - a Prince redraw that left its panel on screen is the stuck overlay step 22 is about")
	await _human_play_idx(main, 0, 1, Deck.CardType.Unknown, -1, tag + " r1 play 2")
	var r1b: Array = main.effect_log
	var baron_i: int = -1
	for i in r1b.size():
		if int(r1b[i]["played"]) == int(Deck.CardType.Baron) and int(r1b[i]["target"]) == 1:
			baron_i = i
	var baron_no: int = baron_i + 1
	check(baron_i >= 0, tag + ": a BARON on seat 1 is in the round-1 log (play #" + str(baron_no)
		+ " of " + str(r1b.size()) + "), played with the Guard the mid-effect modal gave him - the draw"
		+ " the modal made is the card his NEXT play is made with, and his next play is his SECOND turn"
		+ " (the 3 AI seats play between: the log's plays #2..#4 are their Guards aimed at the human)")
	if baron_i >= 0:
		var brec: Dictionary = r1b[baron_i]
		check(int(brec["before"]["hands"][0]) == 1 and int(brec["after"]["hands"][0]) == 1
			and int(brec["before"]["fams"][0]) == 0, tag
			+ ": at that play the human's snapshot is 1 hand card with 0 family cards left ("
			+ str(int(brec["before"]["hands"][0])) + ", " + str(int(brec["before"]["fams"][0]))
			+ ") - `_snapshot` is taken with the played card ALREADY on the table, so the card it reports"
			+ " is the one he KEPT: the 2-card hand the modal built (his kept card + the card his turn"
			+ " start tapped out) spent exactly one family card and exactly one play, and a double draw"
			+ " would have left 2 cards in this snapshot")
	check(main.eliminations == 0, tag + ": the Baron compare published seat 1's family and eliminated"
		+ " NOBODY (eliminations " + str(main.eliminations) + ") - Guard (rank 0) vs Guard is a tie, so"
		+ " the reveal+compare surface runs with the modal closed and the round survives to round 2")
	var settle: int = 0
	while main.round_end_actor.size() < 1 and settle < 500:
		await get_tree().process_frame
		settle += 1
	check(main.round_end_actor.size() == 1 and int(main.round_end_actor[0]) == 0, tag + ": round 1 ended"
		+ " on seat 0's turn start with an EMPTY family (actor " + str(main.round_end_actor) + ") - 3"
		+ " taps drained his 3-card family (2 turn starts + 1 mid-effect), the modal gate sits behind the"
		+ " family-empty round-end check and never stalls it")
	_check_no_leak(main, tag + " round 1 end")
	_check_left_audit(main, tag + " round 1")

	# ---- round 2: the King swap, then a Guard (target + type selectors) ----
	await main._on_round_over_pressed()
	var fam: int = Deck.NOBLE_FAMILY_SIZE[4]
	await _rails_redeal(main, w)
	check(int(p0.family_size()) == fam - 1 and int(p0.hand.get_child_count()) == 2, tag
		+ ": round 2 re-dealt seat 0 a FULL family and his first turn start spent one card (family "
		+ str(p0.family_size()) + " of " + str(fam) + ", hand " + str(int(p0.hand.get_child_count()))
		+ ") - the same panel node serves the new round, on the row of the NEW family")
	await _human_play_idx(main, 0, 1, Deck.CardType.Unknown, -1, tag + " r2 play 1")
	var r2a: Array = main.effect_log
	var king_i: int = -1
	for i in r2a.size():
		if int(r2a[i]["played"]) == int(Deck.CardType.King) and int(r2a[i]["target"]) == 1:
			king_i = i
	var king_no: int = king_i + 1
	check(king_i >= 0, tag + ": a KING on seat 1 is in the play log (play #" + str(king_no) + " of "
		+ str(r2a.size()) + ") - the swap is the fourth manual surface of step 22's Check line, played"
		+ " with the Prince he tapped out of this round's turn-start modal")
	if king_i >= 0:
		var krec: Dictionary = r2a[king_i]
		check(int(krec["after"]["hands"][0]) == 1 and int(krec["before"]["hands"][0]) == 1, tag
			+ ": the swap left the human with EXACTLY 1 hand card (1 -> 1) - a King swap exchanges the"
			+ " card he kept with the target's active card, it never leaves 2 cards in a hand")
		var kl: int = int(krec["after"]["left"][int(Deck.CardType.King)])
		var kl0: int = int(krec["before"]["left"][int(Deck.CardType.King)])
		check(kl == kl0 - 1, tag + ": the King left the supply by the PLAY (-1: " + str(kl0) + " -> "
			+ str(kl) + "), the swap itself decrements nothing, and the family draws of this round"
			+ " decremented nothing either")
	# the AI Prince of seat 1 hits the human MID-EFFECT on the AI's turn: the modal opens on HIS family
	var mid: int = int(w["openings"])
	await await_until(func() -> bool: return int(w["openings"]) > mid)
	check(int(w["openings"]) == 5 and int(w["actors"][4]) == 1, tag + ": the 5th opening happened on seat"
		+ " 1's TURN (" + str(w["actors"]) + ") - an AI's Prince aimed at the human opens the HUMAN's"
		+ " panel, mid-effect, while the chain is suspended inside seat 1's effect")
	check(w["rows"][4] == ["Baron", "Guard"] and w["rows"][4] == w["snaps"][4], tag + ": that row is the"
		+ " human's live family data (" + str(w["rows"][4]) + ") - the Prince has already taken his"
		+ " swapped card out of play (hand " + str(w["hands"][4]) + " cards at the opening), and the AI"
		+ " never picks the replacement for him")
	await _human_play_idx(main, 0, 2, Deck.CardType.Priest, -1, tag + " r2 play 2")
	var r2b: Array = main.effect_log
	var guard_i: int = -1
	for i in r2b.size():
		if int(r2b[i]["played"]) == int(Deck.CardType.Guard) and int(r2b[i]["target"]) == 2 \
				and int(r2b[i]["target_type"]) == int(Deck.CardType.Priest):
			guard_i = i
	var guard_no: int = guard_i + 1
	check(guard_i >= 0, tag + ": a GUARD on seat 2 declaring Priest is in the log (play #" + str(guard_no)
		+ " of " + str(r2b.size()) + ") - the target selector and the type selector are the fifth manual"
		+ " surface, played with the Guard the King swap left in his hand, and they run AFTER the modal"
		+ " closed, never under it")
	if guard_i >= 0:
		var gtype: int = int(r2b[guard_i]["target_type"])
		check(gtype == int(Deck.CardType.Priest), tag + ": the Guard's DECLARED type is the one the type"
			+ " selector reported (" + Deck.card_names[gtype].strip_edges() + ") - the declaration is a"
			+ " play-chain choice, not a modal choice, and no Priest exists in this supply, so it misses")
	check(int(w["crowded"]) == 0, tag + ": at every opening of both rounds the Table was hidden and NO"
		+ " type selector, target label or player-selection sprite was visible - the modal is the only"
		+ " interactive surface for its whole length (crowded frames " + str(w["crowded"]) + " of "
		+ str(w["open_frames"]) + " open frames)")
	settle = 0
	while main.round_end_actor.size() < 2 and settle < 500:
		await get_tree().process_frame
		settle += 1
	w["stop"] = true
	await await_frames(2)
	check(main.round_end_actor.size() == 2, tag + ": 2 rounds ran to their family-empty ends ("
		+ str(main.round_end_actor) + ") - the rails survive a round transition, they are not a"
		+ " one-round guard")

	# ---- the per-frame exclusivity gate, over the whole game ----
	check(int(w["mismatch"]) == 0, tag + ": in every frame of the game (" + str(w["frames"])
		+ " frames sampled) `is_drawing() == _family_selector.is_open()` (" + str(w["mismatch"])
		+ " disagreeing frames) - the pending-draw flag IS the panel: no frame has a modal nobody is"
		+ " awaiting (a tap that would land on a stale panel) and no frame has a pending draw with no"
		+ " panel (a turn that is waiting on nothing)")
	check(int(w["open_frames"]) == int(w["openings"]), tag + ": the panel was open for " + str(
		w["open_frames"]) + " frames over " + str(w["openings"]) + " openings - one frame each, so a"
		+ " committed draw closes the panel in the SAME frame it commits, no overlay survives a frame"
		+ " it is no longer asked for")
	check(int(w["leak"]) == 0 and int(w["row_leak"]) == 0, tag + ": 0 frames of a closed panel left"
		+ " visible and 0 frames of a closed panel keeping its row (leak " + str(w["leak"])
		+ ", row leak " + str(w["row_leak"]) + ") - a row that outlives its modal is a family a tap can"
		+ " still hit between turns")
	check(int(w["openings"]) == NOBLE_4P_RAILS_TAPS.size() and w["tapped"] == NOBLE_4P_RAILS_TAPS, tag
		+ ": " + str(w["openings"]) + " openings, all served by a tap (" + str(w["tapped"]) + ") - no"
		+ " opening was left untapped (a stalled turn) and no draw happened without a panel (an auto-pick)"
		+ " in " + str(w["frames"]) + " frames")
	check(main.family_draw_idx[0] == NOBLE_4P_RAILS_TAPS, tag + ": the indices seat 0 drew ARE his taps ("
		+ str(main.family_draw_idx[0]) + ") - 6 family cards, 6 taps, one pop per tap: no double draw (a"
		+ " draw that pops twice leaves the seat with 2 hand cards) and no skipped draw")
	var ai_lo: int = int(main.family_draws[1])
	var ai_min: int = ai_lo
	var ai_max: int = ai_lo
	for s in [1, 2, 3]:
		ai_min = mini(ai_min, int(main.family_draws[s]))
		ai_max = maxi(ai_max, int(main.family_draws[s]))
	check(int(main.family_draws[0]) == 6 and ai_min >= 3 and ai_max <= 2 * fam, tag + ": 6 family draws"
		+ " for the human (2 rounds x 3 cards: 2 turn starts + 1 mid-effect draw a round) and "
		+ str(main.family_draws) + " for the seats - no seat drew more than the 6 family cards the 2"
		+ " rounds dealt him, and every family card a round dealt was drawn through the modal or its"
		+ " turn-start twin (an AI seat answers the same `deal_from_family` with no panel)")
	check(w["rows"] == w["snaps"], tag + ": every row equalled the seat's live family data at that frame ("
		+ str(w["rows"]) + ") - the modal never shows a family the seat does not own, and exclusivity is"
		+ " what keeps the row and the data in step: a draw from a family while its modal is open would"
		+ " make the two disagree")
	check(w["hands"] == [1, 0, 1, 1, 0, 1] and w["fams"] == [3, 2, 1, 3, 2, 1], tag + ": at every opening"
		+ " the human's hand was " + str(w["hands"]) + " cards and his family " + str(w["fams"])
		+ " - a turn start always finds 1 card (the draw has not happened), a mid-effect Prince always"
		+ " finds 0 (the card is already out of play), and each opening spent one family card")
	check(int(main.eliminations) == 0 and int(main.pile_draws) == 0, tag + ": 0 eliminations and 0 pile"
		+ " draws in 2 rounds (" + str(main.eliminations) + ", " + str(main.pile_draws) + ") - 4p burns"
		+ " nothing, so no widow exists and the modal is the only family-draw path a human seat has")
	check(int(main.round_end_hands[0][0]) == 1 and int(main.round_end_hands[1][0]) == 1, tag
		+ ": seat 0 ended BOTH rounds with exactly 1 hand card (" + str(main.round_end_hands[0][0])
		+ ", " + str(main.round_end_hands[1][0]) + ") - the 1-card invariant through 6 modal draws, 2 of"
		+ " them mid-effect")
	var n: int = main.effect_log.size()
	check(n == 19, tag + ": 19 plays in 2 rounds (" + str(n) + ") - 8 in round 1 (the round ended on"
		+ " seat 0's 3rd turn) and 11 in round 2: a 3-card family buys a seat 3 plays a round, and the"
		+ " mid-effect draws spend family cards, so the human's 4th turn start finds an empty family and"
		+ " ends the round before every AI seat has played 4 times")
	var seen: Dictionary = {}
	for i in n:
		var pt: int = int(main.effect_log[i]["played"])
		seen[pt] = int(seen.get(pt, 0)) + 1
	var nprince: int = int(seen.get(int(Deck.CardType.Prince), 0))
	var nking: int = int(seen.get(int(Deck.CardType.King), 0))
	var nbaron: int = int(seen.get(int(Deck.CardType.Baron), 0))
	var nguard: int = int(seen.get(int(Deck.CardType.Guard), 0))
	check(nprince == 2 and nking == 1 and nbaron == 1 and nguard == 15, tag + ": the round logs hold 2"
		+ " Princes (the human's self-Prince and seat 1's hit on him), 1 King swap, 1 Baron compare and 15"
		+ " Guards (" + str(seen) + ") - the four surfaces of step 22's manual pass that this fixture can"
		+ " reach, in ONE human game: Guard (target + type selectors), King (the swap), Baron (the reveal"
		+ " and compare) and Prince (the mid-effect modal); the Countess-forced play of a human seat is I1"
		+ " play 5, the same rule on the same flow")
	# publish the rails counters for an embedding suite (`tests/smoke_games.gd` prints its NOBLE UI
	# line from these, so the number is a measurement of this run, not a restatement of the checks)
	ui_openings = int(w["openings"])
	ui_taps = int(w["tapped"].size())
	ui_mismatch = int(w["mismatch"])
	ui_crowded = int(w["crowded"])
	ui_leaks = int(w["leak"]) + int(w["row_leak"])
	ui_effects = main.effect_log.size()
	ui_plays = n
	ui_surfaces = []
	for k in seen:
		ui_surfaces.append(str(Deck.card_names[k]).strip_edges() + " x" + str(seen[k]))
	ui_frames = int(w["frames"])
	_check_no_leak(main, tag + " game end")
	_check_left_audit(main, tag + " game end")
	_check_pairings(main)
	main.queue_free()
	await await_frames(2)


# Settle a re-deal WITHOUT re-initializing the seats (the watcher keeps tapping the openings, so the
# first turn start of the new round is served by the queue, exactly like a real round transition).
func _rails_redeal(main, w) -> void:
	var openings: int = int(w["openings"])
	await await_until(func() -> bool: return int(w["openings"]) > openings)
	var fam: int = Deck.NOBLE_FAMILY_SIZE[int(main._player_count)]
	await await_until(func() -> bool:
		return main._players[0].hand.get_child_count() == 2 and main._players[0].family_size() == fam - 1)


# The gate: a 4p human game stopped at the FIRST turn start, panel open, nothing drawn (the H1 position).
func _rails_gate(n: int, scripted: Array[Deck.CardType], scripted_left: Array[int]):
	var main = _scripted_main_human(n, scripted, scripted_left)
	await main.init_players(SEED)
	await await_until(func() -> bool: return main._family_selector.is_open())
	return main


func _test_rails_inert() -> void:
	var tag := "J2"
	var main = await _rails_gate(4, NOBLE_4P_RAILS, NOBLE_4P_RAILS_LEFT)
	var sel = main._family_selector
	var p0 = main._players[0]
	var row_before: Array = _rn(_fs_cards(sel))
	var target_before: int = int(main._target_player)
	var type_before: int = int(main._target_type)
	check(main.is_drawing() and sel.is_open(), tag + ": the gate - a family draw is PENDING and the panel"
		+ " is open (drawing " + str(main.is_drawing()) + ", open " + str(sel.is_open()) + ")")
	check(int(p0.hand.get_child_count()) == 1 and int(p0.family_size()) == 3
		and int(main.family_draws[0]) == 0, tag + ": the human holds 1 card and his family is full ("
		+ str(int(p0.hand.get_child_count())) + ", " + str(int(p0.family_size())) + ") - nothing is drawn"
		+ " at the gate, so every probe below has to leave it at 1 card / 3 cards to be INERT")
	check(not main._table.visible and not main._type_selector.visible
		and not main._select_other_player.visible and not main._select_any_player.visible
		and not bool(main._player_selection.visible), tag + ": the whole play surface is put away for the"
		+ " length of the draw (table, type selector, both target labels, the selection sprite) - a tap on"
		+ " any of them has nothing to act on")
	check(p0._state == Player.State.IDLE and not bool(p0.current_mark.visible), tag + ": the seat's tap"
		+ " gate is CLOSED for the length of the modal (state " + str(p0._state) + ", mark "
		+ str(bool(p0.current_mark.visible)) + ") - `Player._on_card_input_event` accepts a card tap in"
		+ " SELECT_CARD only, so his own cards cannot start a play under the panel")

	# 1. a card play (`card_played`, what a card tap emits)
	await main._on_card_played(p0.hand.get_child(0))
	check(main.effect_log.is_empty() and int(p0.hand.get_child_count()) == 1
		and int(main._deck._left[int(Deck.CardType.King)]) == 1, tag + ": a CARD PLAY under the panel"
		+ " started NO chain (" + str(main.effect_log.size()) + " plays, hand "
		+ str(int(p0.hand.get_child_count())) + " cards, King left "
		+ str(int(main._deck._left[int(Deck.CardType.King)])) + ") - no card moved to the table, nothing"
		+ " was discarded, so the modal cannot be raced by a play"
		+ " (Main._on_card_played's `_drawing` rail)")
	# 2. a target-player tap (a seat tap / `target_player_selected`)
	await main._on_target_player_selected(1)
	check(main.effect_log.is_empty() and int(main._target_player) == target_before
		and not bool(main._player_selection.visible), tag + ": a TARGET-PLAYER tap under the panel picked"
		+ " no target (target " + str(main._target_player) + " == the gate value " + str(target_before)
		+ ", sprite " + str(bool(main._player_selection.visible)) + ") - the pick belongs to the play that"
		+ " FOLLOWS the draw")
	# 3. a target-type tap
	await main._on_target_type_selected(Deck.CardType.Priest)
	check(main.effect_log.is_empty() and int(main._target_type) == type_before
		and not main._type_selector.visible and not main._table.visible, tag + ": a TARGET-TYPE tap"
		+ " under the panel declared nothing (type " + str(main._target_type) + " == the gate value "
		+ str(type_before) + ") - it did not open the type selector and did not un-hide the Table,"
		+ " which is what `_on_target_type_selected` does when it is LEGAL to resolve an effect")
	# 4. a chosen move (the AI signal a stale chain would drive)
	var m := Move.new(null, 0, -1, Deck.CardType.Unknown, -1)
	await main._on_move_chosen(m)
	check(main.effect_log.is_empty() and int(p0.hand.get_child_count()) == 1
		and int(p0.family_size()) == 3, tag + ": a CHOSEN MOVE under the panel drew nothing and played"
		+ " nothing (" + str(int(p0.family_size())) + " family, " + str(int(p0.hand.get_child_count()))
		+ " hand) - no chain runs under the panel, so no family card can be popped from under the seat"
		+ " that is choosing (Main._on_move_chosen's `_drawing` rail)")
	# 5. the seat's own state, which is his tap gate
	check(int(p0._state) == int(Player.State.IDLE), tag + ": after all four probes the seat's state is"
		+ " UNCHANGED (" + str(p0._state) + ") - no probe queued a play, so nothing is waiting to be"
		+ " played when the draw lands")
	check(main.is_drawing() and sel.is_open() and _rn(_fs_cards(sel)) == row_before
		and int(p0.family_size()) == 3, tag + ": the PENDING DRAW SURVIVES every probe (panel open, row "
		+ str(_rn(_fs_cards(sel))) + " == " + str(row_before) + ", family " + str(int(p0.family_size()))
		+ ") - the rails drop the taps, they do not cancel the mandatory draw: a rail that closed the"
		+ " modal on a stray tap would leave the seat with no way to draw")
	# and the draw the modal asked for still lands, exactly once, on the card he taps
	await _human_draw(main, 2)
	await await_until(func() -> bool:
		return p0.hand.get_child_count() == 2 and p0._state == Player.State.SELECT_CARD)
	check(main.family_draw_idx[0] == [2] and int(p0.family_size()) == 2
		and int(p0.hand.get_child_count()) == 2, tag + ": the tap on family index 2 STILL drew exactly"
		+ " one card (" + str(main.family_draw_idx[0]) + ", family " + str(int(p0.family_size()))
		+ ", hand " + str(int(p0.hand.get_child_count())) + ") - the gates are inert, not destructive: 4"
		+ " ignored taps cost no draw and no card")
	check(int(main.family_draw_idx[0].size()) == 1 and int(main.family_draws[0]) == 1, tag + ": ONE family"
		+ " draw after 1 tap (" + str(main.family_draws[0]) + ") - the pending draw is one draw, not two"
		+ " (no double draw through the rails)")
	check(not sel.is_open() and not bool(sel.visible) and bool(main._table.visible)
		and p0._state == Player.State.SELECT_CARD, tag + ": the modal closed, the Table came back and the"
		+ " play selection opened (state " + str(p0._state) + ") - the gate restored what the caller left"
		+ " behind, so the turn continues normally after 4 refused taps"
		+ " (the todo's 'no stuck overlays')")
	main.queue_free()
	await await_frames(2)


# A per-frame watcher that keeps the play surfaces ON STAGE while no modal is open, and samples them
# on the frame the panel opens. The crowding counter of J1 cannot pin the hiding lines: the production
# flow has those surfaces hidden at the moments a modal opens anyway, so deleting all the `hide()`
# calls of `human_draw_from_family` changes 0 checks (measured: 878 PASS, exit 0). This is the shape a
# real stuck overlay arrives in - a board that is dirty when the modal opens - and the hiding lines are
# the only thing standing between that board and the human's one question.
func _rails_dirty(main, w) -> void:
	var was := false
	while int(w["frames"]) < 6000 and not bool(w["stop"]):
		w["frames"] = int(w["frames"]) + 1
		var sel = main._family_selector
		var now: bool = sel.is_open()
		if not now:
			main._type_selector.visible = true
			main._select_other_player.visible = true
			main._select_any_player.visible = true
			main._player_selection.visible = true
			main._table.visible = true
			# the seat's OWN tap gate, held OPEN: a card tap in SELECT_CARD emits `card_played` and
			# starts a play chain on the hand the modal is about to grow. The turn-start flow reaches the
			# modal with the state already IDLE (the previous play left it there), so a fixture that
			# takes the state as it finds it cannot tell "the modal closed the tap gate" from "the seat
			# happened to be idle" - measured: deleting `p._state = Player.State.IDLE` changes 0 checks.
			main._players[0]._state = Player.State.SELECT_CARD
		elif not was:
			w["openings"] = int(w["openings"]) + 1
			var t: bool = main._table.visible
			var crow: bool = main._type_selector.visible or main._select_other_player.visible \
				or main._select_any_player.visible or bool(main._player_selection.visible)
			var st: int = int(main._players[0]._state)
			var mark: bool = bool(main._players[0].current_mark.visible)
			w["tables"].append(bool(t))
			w["states"].append(st)
			w["snaps"].append(mark)
			if t:
				w["crowded"] = int(w["crowded"]) + 1
			if crow:
				w["crowded"] = int(w["crowded"]) + 1
			if st != int(Player.State.IDLE) or mark:
				w["crowded"] = int(w["crowded"]) + 1
			w["stop"] = true  # the rails had their one fair shot at the surfaces
		was = now
		await get_tree().process_frame


func _test_rails_reentrant() -> void:
	var tag := "J3"
	var main = _scripted_main_human(4, NOBLE_4P_RAILS, NOBLE_4P_RAILS_LEFT)
	var dirty = _rail_watcher([])
	_rails_dirty(main, dirty)  # keeps the surfaces on stage until the panel opens
	main.init_players(SEED)
	await await_until(func() -> bool: return int(dirty["openings"]) > 0)
	var sel = main._family_selector
	var p0 = main._players[0]
	check(dirty["openings"] == 1 and dirty["tables"] == [false] and int(dirty["crowded"]) == 0
		and dirty["states"] == [int(Player.State.IDLE)] and dirty["snaps"] == [false], tag
		+ ": the modal opened ALONE, and the seat was UNtappable, on a board that was NOT clean - the"
		+ " type selector, both target labels, the player-selection sprite and the Table were held"
		+ " visible, and his own state was held at SELECT_CARD, on every frame before the opening; on the"
		+ " frame the panel opened every surface was off and his state was IDLE with no current-mark"
		+ " (state " + str(dirty["states"]) + ", mark " + str(dirty["snaps"]) + ", table"
		+ " " + str(dirty["tables"]) + ", crowded frames " + str(int(dirty["crowded"]))
		+ ") - the hiding lines and the state write of `human_draw_from_family` are what keep a stuck"
		+ " overlay from becoming a second question the seat can answer with a tap")
	# A tiny watcher of the openings, so a second modal is COUNTED, not eyeballed. It taps NOTHING: the
	# gate's modal is the pending draw the fixture is probing, and a watcher that tapped it would settle
	# the turn and turn the "nested" request into an ordinary second turn.
	var w = _rail_watcher([])
	_watch_rails(main, w)
	await await_frames(1)
	check(int(w["openings"]) == 1, tag + ": ONE opening so far - the turn-start modal the gate stopped at ("
		+ str(w["openings"]) + ")")
	var row: Array = _rn(_fs_cards(sel))
	# The chain asks TWICE: the turn-start draw is suspended, and a nested request (the Prince chain, a
	# replayed `new_turn`, anything) reaches the only place a modal is ever opened.
	await main.human_draw_from_family(p0)
	await await_frames(2)
	check(int(w["openings"]) == 1, tag + ": the nested request opened NO second modal (" + str(w["openings"])
		+ " openings in " + str(w["frames"]) + " frames) - one interactive surface, and the row the seat is"
		+ " looking at is never re-built from under him")
	check(main.is_drawing() and sel.is_open() and _rn(_fs_cards(sel)) == row, tag + ": the FIRST modal is"
		+ " intact (drawing " + str(main.is_drawing()) + ", row " + str(_rn(_fs_cards(sel))) + " == "
		+ str(row) + ") - the nested request did not close it, did not re-open it on the CURRENT family"
		+ " (which would drop the card it is asking about) and did not move the seat's state")
	check(int(main.family_draws[0]) == 0 and int(p0.family_size()) == 3
		and int(p0.hand.get_child_count()) == 1, tag + ": the nested request drew NOTHING ("
		+ str(main.family_draws[0]) + " draws, family " + str(int(p0.family_size())) + ", hand "
		+ str(int(p0.hand.get_child_count())) + ") - it popped no card, so it cannot make the seat's"
		+ " pending choice point at a card that is gone")
	# a THIRD request, from the same seat, while the modal is open
	await main.human_draw_from_family(p0)
	check(int(w["openings"]) == 1 and int(main.family_draws[0]) == 0 and main.is_drawing(), tag
		+ ": a THIRD request is dropped the same way (" + str(w["openings"]) + " openings, "
		+ str(main.family_draws[0]) + " draws) - the re-entrancy rail is a property of the moment, not of"
		+ " the caller")
	# the pending draw survives and commits ONCE
	w["stop"] = true
	await _human_draw(main, 0)
	await await_until(func() -> bool:
		return p0.hand.get_child_count() == 2 and p0._state == Player.State.SELECT_CARD)
	check(main.family_draw_idx[0] == [0] and int(main.family_draws[0]) == 1
		and int(p0.family_size()) == 2 and int(p0.hand.get_child_count()) == 2, tag + ": after 2 dropped"
		+ " requests the tap drew EXACTLY 1 card (" + str(main.family_draw_idx[0]) + ", family "
		+ str(int(p0.family_size())) + ", hand " + str(int(p0.hand.get_child_count()))
		+ ") - a nested request cannot steal the draw, delay it into a second draw, or draw for the seat")
	main.queue_free()
	await await_frames(2)


func _test_rails_listener_guard() -> void:
	var tag := "J4"
	var main = await _rails_gate(4, NOBLE_4P_RAILS, NOBLE_4P_RAILS_LEFT)
	var sel = main._family_selector
	var p0 = main._players[0]
	# 1. no draw pending -> the emission is DROPPED, the latch untouched
	main._close_family_modal()
	check(not main.is_drawing() and int(main._draw_idx) == -1, tag + ": the reset drops the pending state"
		+ " (drawing " + str(main.is_drawing()) + ", latched " + str(main._draw_idx) + ")")
	main._on_family_draw_selected(3)
	check(int(main._draw_idx) == -1 and not main.is_drawing(), tag + ": an emission with NO draw pending"
		+ " is dropped by the RECEIVER (latched " + str(main._draw_idx) + ", drawing "
		+ str(main.is_drawing()) + ") - the panel is a permanently allocated node with ONE listener for"
		+ " the whole game, so a stray emission (a double tap, a tap on a closing panel) has to be"
		+ " dropped by the listener: a listener that queued it would draw a family card nobody asked for")
	check(int(main.family_draws[0]) == 0 and int(p0.family_size()) == 3
		and int(p0.hand.get_child_count()) == 1, tag + ": and it drew NOTHING ("
		+ str(main.family_draws[0]) + " draws, family " + str(int(p0.family_size())) + ", hand "
		+ str(int(p0.hand.get_child_count())) + ") - dropping is not queueing")
	# 2. the pending draw is open, a latched index from out of the blue cannot rename the card he taps
	main._family_selector.open(p0.family)
	main._drawing = true
	main._draw_idx = -1
	await await_frames(1)
	check(main.is_drawing() and sel.is_open(), tag + ": a pending draw of the full 3-card family ("
		+ str(_rn(_fs_cards(sel))) + ")")
	main._on_family_draw_selected(2)
	check(int(main._draw_idx) == 2 and main.is_drawing(), tag + ": while a draw IS pending the listener"
		+ " latches what the panel reports (latched " + str(main._draw_idx) + ") - the latch is the"
		+ " listener's, and the commit reads its index off its own `await`")
	await _human_draw(main, 0)
	await await_until(func() -> bool:
		return p0.hand.get_child_count() == 2 and p0._state == Player.State.SELECT_CARD)
	check(main.family_draw_idx[0] == [0] and int(main.family_draws[0]) == 1, tag + ": the draw that"
		+ " landed is the TAP's index 0, not the latched 2 (" + str(main.family_draw_idx[0])
		+ ") - two emissions in flight are reported by the mismatch rail and the tap wins, so a stray"
		+ " emission can never rename the card the seat picked")
	check(int(p0.hand.get_child_count()) == 2 and int(p0.family_size()) == 2, tag + ": 1 tap = 1 pop (hand"
		+ " " + str(int(p0.hand.get_child_count())) + ", family " + str(int(p0.family_size()))
		+ ") - the latched index drew no second card, so the 1-hand-card shape of the turn survives a"
		+ " double emission (the todo's 'no double draws')")
	check(not sel.is_open() and not bool(sel.visible) and _fs_cards(sel).is_empty()
		and not main.is_drawing() and int(main._draw_idx) == -1, tag + ": the commit cleared BOTH the"
		+ " panel and the latch (open " + str(sel.is_open()) + ", latched " + str(main._draw_idx)
		+ ") - nothing is left to fire the next turn's draw twice")
	main.queue_free()
	await await_frames(2)


func _test_rails_bad_index() -> void:
	var tag := "J5"
	var main = await _rails_gate(4, NOBLE_4P_RAILS, NOBLE_4P_RAILS_LEFT)
	var sel = main._family_selector
	var p0 = main._players[0]
	# The panel's own guards (G2) make a tap report an index of its own row ONLY, so the only way Main
	# is handed an index it cannot pop is a panel emitting out of the blue: a harness sabotage.
	sel.draw_selected.emit(99)
	await await_until(func() -> bool:
		return int(main.family_draws[0]) > 0 and p0.hand.get_child_count() == 2 \
			and p0._state == Player.State.SELECT_CARD)
	check(main.family_draw_idx[0] == [0] and int(main.family_draws[0]) == 1, tag + ": an emitted index"
		+ " the seat cannot pop (99 of a 3-card family) took FAMILY[0] (" + str(main.family_draw_idx[0])
		+ ", 1 draw) - the draw is MANDATORY (step 7): a turn that never draws never ends, so a stalled"
		+ " turn is the worse failure and the fallback is the price of never deadlocking")
	check(int(p0.family_size()) == 2 and int(p0.hand.get_child_count()) == 2, tag + ": the fallback drew"
		+ " EXACTLY 1 card (family " + str(int(p0.family_size())) + ", hand "
		+ str(int(p0.hand.get_child_count())) + ") - it is one draw, not a re-deal, not 2 cards, and the"
		+ " seat is not handed a card that does not exist")
	check(not sel.is_open() and not bool(sel.visible) and not main.is_drawing()
		and bool(main._table.visible), tag + ": the modal closed on the fallback path too (open "
		+ str(sel.is_open()) + ", drawing " + str(main.is_drawing()) + ", table "
		+ str(main._table.visible) + ") - the out-of-range branch is an exit path of the modal like any"
		+ " other, it does not leave a panel on screen")
	await await_until(func() -> bool:
		return p0._state == Player.State.SELECT_CARD and p0.hand.get_child_count() == 2)
	check(p0._state == Player.State.SELECT_CARD, tag + ": and the turn CONTINUES (state " + str(p0._state)
		+ ") - the seat gets his play selection on the card the fallback drew, so a bad report costs a"
		+ " choice, not the round")
	main.queue_free()
	await await_frames(2)


func _test_rails_exit_paths() -> void:
	var tag := "J6"
	# path 1: the turn-start commit (the tap)
	var main = await _rails_gate(4, NOBLE_4P_RAILS, NOBLE_4P_RAILS_LEFT)
	var sel = main._family_selector
	var p0 = main._players[0]
	await _human_draw(main, 1)
	check(not sel.is_open() and not bool(sel.visible) and _fs_cards(sel).is_empty()
		and not main.is_drawing() and main.family_draw_idx[0] == [1], tag + ": path 1, the TURN-START"
		+ " COMMIT - the tap closed the panel, dropped the row and cleared the pending state (draws "
		+ str(main.family_draw_idx[0]) + ") - the modal closes BEFORE the card flies, so the draw"
		+ " animation runs with no overlay on screen")
	# path 2: the mid-effect Prince commit (a modal opened by an effect, closed by its own draw)
	await _human_play_idx(main, 1, 0, Deck.CardType.Unknown, -1, tag + " self-Prince")
	check(not sel.is_open() and not bool(sel.visible) and _fs_cards(sel).is_empty()
		and not main.is_drawing(), tag + ": path 2, the MID-EFFECT Prince commit - the modal an effect"
		+ " opened closed inside that same effect (" + str(sel.is_open()) + ", drawing "
		+ str(main.is_drawing()) + ") - a Prince redraw that left its panel open would sit on the NEXT"
		+ " seat's turn, on a board that no longer has that family")
	# path 3: a NEW GAME (the Main-Menu / Exit path): the game is abandoned mid-modal, and a suspended
	# `await draw_selected` never resumes, so the panel would be sitting on the menu
	await main.init_players(SEED)
	await await_until(func() -> bool: return sel.is_open())
	check(int(p0.family_size()) == 3 and int(main.family_draws[0]) == 1
		and _rn(_fs_cards(sel)) == ["Prince", "Baron", "Guard"], tag + ": path 3, a NEW GAME from a"
		+ " modal that is still open - `init_players` closed the old panel and the new round's first turn"
		+ " start opened a FRESH one on the re-dealt family (" + str(_rn(_fs_cards(sel)))
		+ ", draws " + str(main.family_draws[0]) + ") - no row of the interrupted family survived into"
		+ " the new game, and the interrupted draw was not resumed into a second pop")
	check(main.is_drawing() and int(main.family_draw_idx[0].size()) == 1, tag + ": exactly ONE family"
		+ " draw across the reset (" + str(main.family_draw_idx[0]) + ") - the interrupted modal drew"
		+ " nothing, and the new modal is the ONLY thing the new turn is waiting on")
	# path 4: a NEW ROUND with a LIVE modal. `_new_round()` re-deals every family, so a row of the old
	# family is a menu of cards that no longer exist, and a suspended `await draw_selected` points at a
	# family index the re-deal has already forgotten. This is the strictest exit path.
	var fam: int = Deck.NOBLE_FAMILY_SIZE[4]
	await _human_draw(main, 2)
	await await_until(func() -> bool:
		return p0.hand.get_child_count() == 2 and p0._state == Player.State.SELECT_CARD)
	await _human_play_idx(main, 0, 1, Deck.CardType.Unknown, -1, tag + " play after the reset")
	await await_until(func() -> bool: return sel.is_open())
	check(sel.is_open() and main.is_drawing() and int(p0.family_size()) < fam, tag
		+ ": path 4 fixture: a LIVE modal at the round transition (open " + str(sel.is_open())
		+ ", drawing " + str(main.is_drawing()) + ", family " + str(int(p0.family_size())) + " of "
		+ str(fam) + ") - the seat is mid-round with a draw pending on family cards the next round"
		+ " re-deals")
	await main._on_round_over_pressed()
	await await_until(func() -> bool: return sel.is_open())
	var row4: Array = _rn(_fs_cards(sel))
	check(sel.is_open() and main.is_drawing() and row4.size() == fam, tag + ": path 4, a NEW ROUND -"
		+ " `_new_round` calls `_close_family_modal`, so the re-deal dropped the live panel (with its"
		+ " suspended await) and the new round's first turn start opened a row of the FULL re-dealt"
		+ " family (" + str(row4) + " of " + str(fam) + ") - a stale menu of the old family's leftovers"
		+ " would pop a family index the seat does not own")
	check(row4 == ["Prince", "Baron", "Guard"], tag + ": the new round's row is the NEW family in"
		+ " as-dealt order (" + str(row4) + ") - the panel re-opens on the re-dealt family, not the"
		+ " leftovers, so every card the seat can tap is a card the round actually dealt him")
	check(int(p0.family_size()) == fam and int(p0.hand.get_child_count()) == 1, tag
		+ ": the seat's family is FULL again (family " + str(int(p0.family_size())) + ", hand "
		+ str(int(p0.hand.get_child_count())) + ") - the interrupted draw of the old round drew nothing"
		+ " after the re-deal, and the modal is his only way to draw")
	check(not main._table.visible and not main._type_selector.visible
		and not main._select_other_player.visible and not main._select_any_player.visible
		and not bool(main._player_selection.visible), tag + ": the new round's modal opens ALONE (table,"
		+ " type selector, target labels and the selection sprite all hidden) - the round transition"
		+ " resets the play surface as well as the panel, so the modal is one question and nothing else")
	_check_left_audit(main, tag + " new round")
	main.queue_free()
	await await_frames(2)


# ----------------------------------------------------------------------------------------
# TEST K (todo step 23): the family DEAL presentation
#
# Step 23's Do line is four promises, and every one of them is a property of the DEAL, so every one
# is measured from inside it, on the production deal path - the `CountingMain` deal record
# (`deal_states`, `round_deal_stats`, `setup_ms`, `inflight_max`, `deal_audio`):
#
#   1. the first-hand card stays ANIMATED, exactly one animated card per live seat, and the deal's
#      peak of simultaneous flights is 1 - a family batch in flight would make it 5/4/3 (K1);
#   2. the families are dealt INSTANTLY - data + a face-up stack, no card flies - so the variant's
#      deal costs the CLASSIC deal's wall-clock time, at the speeds the menu offers (K4);
#   3. ONE slide sound for the family BATCH, not one per family card - the audio identity
#      `audio == first_hand + pile_draws + family_draws + 1` per round (K1);
#   4. `render_family()` after EVERY family change - turn-start draw, mid-effect draw, elimination
#      reveal + clear, round re-deal - pinned PER FRAME (K3), because a missed re-render is invisible
#      to a per-round snapshot: the next change re-renders and repairs the nodes. Only a frame-by-frame
#      comparison of the stack against the family data can see it.
# ----------------------------------------------------------------------------------------
const NOBLE_MAIN_LEFT: Array[int] = [0, 0, 1, 0, 0]  # index = player count: 16 - burn - count*(1+family)


# A real-deck fixture: all seats AI, `noble_family` set, CountingMain installed.
func _deal_main(count: int, noble: bool):
	var main = MainScene.instantiate()
	var card_scene: PackedScene = main.card_scene  # `set_script` resets exported vars: save/restore
	main.set_script(load(CountingMainScript))
	main.card_scene = card_scene
	add_child(main)
	main.noble_family = noble
	for i in 4:
		main._players[i].ai_level = Player.AI_Level.Level_1 if i < count else Player.AI_Level.Disabled
	return main


func _test_deal_presentation() -> void:
	print("\n########## TEST K: the family DEAL presentation (todo step 23) ##########")
	for count: int in [4, 3, 2]:
		print("--- TEST K1 (real deck, " + str(count)
			+ "p: the deal animates the HAND, the family batch is ONE sound, the flight peak is 1) ---")
		await _test_deal_batch(count)
	print("--- TEST K2 (2p human seat: the burn is applied AT THE DEAL, the whole 5-card stack at once) ---")
	await _test_deal_burn_stack()
	print("--- TEST K3 (the stack mirrors the family data EVERY frame: draw, reveal, clear, re-deal) ---")
	await _test_family_view_ai()
	await _test_family_view_human()
	print("--- TEST K4 (the deal is timed on the wall clock at _speed 2 and 5, classic as the control) ---")
	await _test_deal_timing()
	for count: int in [4, 3, 2]:
		await _test_deal_batch(count)
	await _test_deal_burn_stack()
	await _test_family_view_ai()
	await _test_family_view_human()
	await _test_deal_timing()


# ---- K1: the real deck at every seat count - the deal table, the piles, the batch sound, the peak ----
func _test_deal_batch(count: int) -> void:
	var tag := "K1 " + str(count) + "p"
	var fam: int = Deck.NOBLE_FAMILY_SIZE[count]
	var burn: int = Deck.NOBLE_BURN[count]
	var main = _deal_main(count, true)
	await main.init_players(SEED)
	await await_until(func() -> bool: return main.round_deal_stats.size() >= 2, 40000)
	check(main.round_deal_stats.size() >= 2 and main.deal_states.size() >= 1, tag + ": 2 full rounds of"
		+ " the REAL deck reached on real timers (" + str(main.round_deal_stats.size()) + " round ends,"
		+ " " + str(main.deal_states.size()) + " deals recorded, " + str(main.effect_log.size())
		+ " plays, " + str(main.eliminations) + " eliminations) - the batch sound, the deal table and"
		+ " the flight peak are measured on the production deal, not on a scripted supply")
	if main.deal_states.is_empty():
		check(false, tag + ": the deal was recorded at the round's first turn")
		main.queue_free()
		await await_frames(2)
		return
	var d: Dictionary = main.deal_states[0]
	var fams: Array = d["fams"]
	var stacks: Array = d["stacks"]
	var hands: Array = d["hands"]
	var want_fams := true
	var want_hands := true
	var want_stacks := true
	for i in 4:
		want_fams = want_fams and int(fams[i]) == (fam if i < count else 0)
		want_hands = want_hands and int(hands[i]) == (1 if i < count else 0)
		want_stacks = want_stacks and int(stacks[i]) == 0
	check(want_fams, tag + ": the deal put exactly " + str(fam) + " family cards in every live seat ("
		+ str(fams) + ") - NOBLE_FAMILY_SIZE[" + str(count) + "] = " + str(fam) + ", dealt round-robin")
	check(want_hands, tag + ": every live seat holds EXACTLY 1 hand card at the deal (" + str(hands)
		+ ") - the first-hand card, dealt by the ANIMATED `deal_card`, and it is not part of the family")
	check(want_stacks, tag + ": at the deal NO seat renders a family stack (" + str(stacks) + ") - every"
		+ " seat of this fixture is an AI seat: the deal makes pixels for the human's own family and for"
		+ " nobody else's, because the family is PRIVATE (step 15)")
	check(int(d["widow"]) == burn and bool(d["widow_visible"]) == (burn > 0), tag + ": the burn is"
		+ " applied AT THE DEAL - widow " + str(d["widow"]) + " cards for the " + str(burn)
		+ " the " + str(count) + "p deal burns, and the widow node is visible "
		+ str(bool(d["widow_visible"])) + " exactly when it holds cards (4p burns nothing, so 4p has no"
		+ " widow to see)")
	check(int(d["main_pile"]) == NOBLE_MAIN_LEFT[count], tag + ": the main pile keeps "
		+ str(d["main_pile"]) + " cards, expected " + str(NOBLE_MAIN_LEFT[count])
		+ " = 16 - " + str(burn) + " burned - " + str(count) + " x (1 first-hand + " + str(fam)
		+ " family) - the burn, the first-hand cards and the family batch all leave the MAIN PILE (step 3)")
	check(int(d["left_sum"]) == TOTAL_CARDS, tag + ": sum(_left) == " + str(d["left_sum"])
		+ " at the deal - the deal takes nothing out of PLAY: 16 cards are dealt and none is out of play"
		+ " yet (step 4, step 19)")
	var audio: int = int(d["audio"])
	var fh: int = int(d["first_hand"])
	check(fh == count, tag + ": " + str(fh) + " animated card flights at the deal = the " + str(count)
		+ " first-hand cards - the deal animates THE HAND, not the family")
	check(audio == count + 1, tag + ": the deal made " + str(audio) + " slide sounds = " + str(count)
		+ " first-hand flights + 1 for the WHOLE " + str(count * fam)
		+ "-card family batch - ONE `deal_sound()` per round, not one per family card. A per-card deal"
		+ " would call it " + str(count * fam) + " times in ONE frame: AudioStreamPlayer.play() RESTARTS"
		+ " its stream, so the batch would stutter and cut itself off, which is exactly why the family"
		+ " batch is not animated card by card")
	var rows_ok := true
	var rows := ""
	for r in main.round_deal_stats:
		var st: Dictionary = r
		var cards: int = int(st["first_hand"]) + int(st["pile_draws"]) + int(st["family_draws"])
		rows_ok = rows_ok and int(st["audio"]) == cards + 1 and int(st["batch"]) == 1 \
			and int(st["first_hand"]) == count
		rows += " [audio " + str(st["audio"]) + " = " + str(st["first_hand"]) + " first-hand +"
		rows += str(st["pile_draws"]) + " pile + " + str(st["family_draws"]) + " family +"
		rows += str(st["batch"]) + " batch]"
	check(rows_ok, tag + ": in BOTH rounds the round's sound count IS its animation count + 1:" + rows
		+ " - every family DRAW (a turn start, a Prince redraw) flies its own card and makes its own"
		+ " sound, the batch the deal materialized in one instant makes one, and nothing else is audible."
		+ " Counted through the seam production asks for the sound (`Main.deal_sound()`), so a 12-card"
		+ " per-card batch would read 13 sounds, not 5")
	check(int(main.inflight_max) == 1, tag + ": the most card flights that ever ran at the same time is"
		+ " " + str(main.inflight_max) + ", measured with a counter around every `deal_card`/"
		+ "`deal_from_family` and NEVER sampled per frame (at `_speed = 0` a whole round resolves inside"
		+ " one frame, so a frame sampler reads 0): the family batch never flies a card, and an animated"
		+ " family deal would put " + str(count * fam) + " flights in this peak")
	var fam_sum: int = 0
	for r in main.round_deal_stats:
		fam_sum += int((r as Dictionary)["family_draws"])
	check(fam_sum > 0, tag + ": " + str(fam_sum) + " family draws in the 2 rounds - the batch sound is"
		+ " NOT the family's only sound: the family cards the batch made invisible-for-free are drawn one"
		+ " card at a time, each with its own flight and its own slide")
	main.queue_free()
	await await_frames(2)


# ---- K2 (2p, human seat): the burn, the piles and the WHOLE 5-card stack at the deal ----
func _test_deal_burn_stack() -> void:
	var tag := "K2"
	var main = _scripted_main_human(2, NOBLE_2P_STACK, NOBLE_2P_STACK_LEFT)
	await main.init_players(SEED)
	await await_until(func() -> bool: return main.deal_states.size() >= 1, 40000)
	if main.deal_states.is_empty():
		check(false, tag + ": the 2p deal was recorded")
		main.queue_free()
		await await_frames(2)
		return
	var d: Dictionary = main.deal_states[0]
	var p0 = main._players[0]
	var p1 = main._players[1]
	check(int(d["fams"][0]) == 5 and int(d["fams"][1]) == 5, tag + ": 2p dealt a FULL 5-card family to"
		+ " each seat WITH THE BURN APPLIED - 16 = 3 burned + 2 first-hand + 10 family + 1 left in the"
		+ " pile, so the family batch is dealt AFTER the burn, not from the undealt tail")
	check(int(d["widow"]) == 3 and bool(d["widow_visible"]) and int(d["main_pile"]) == 1, tag
		+ ": at the deal the widow holds the 3 burned cards and is VISIBLE (widow " + str(d["widow"])
		+ ", main pile " + str(d["main_pile"]) + ") - 2p burns 3 into the widow pile (the Prince fallback)"
		+ " and keeps 1 card in the main pile")
	var widow_names: Array = []
	for t in main._deck._widow_cards:
		widow_names.append(Deck.card_names[int(t)].strip_edges())
	check(widow_names == ["Guard", "Guard", "Guard"], tag + ": the widow IS the supply's FIRST 3 cards ("
		+ str(widow_names) + ") - burn = pop_front() x 3, taken before any seat is dealt, and the seats'"
		+ " families start at slot 5")
	check(int(d["stacks"][0]) == 5, tag + ": the human's stack materialized ALL 5 family cards AT THE"
		+ " DEAL (" + str(d["stacks"][0]) + " nodes, family " + str(int(d["fams"][0]))
		+ ") - the family is dealt in ONE instant: no card flies, and the stack is what makes the batch"
		+ " visible the moment the round opens, before the seat draws a single card")
	check(int(d["stacks"][1]) == 0 and int(d["fams"][1]) == 5, tag + ": the AI seat's full 5-card family"
		+ " makes 0 nodes - `render_family()` is called for the human only at the deal")
	_check_stack_p(tag + " at the deal", p0, ["Guard", "Guard", "Guard", "Guard", "Countess"],
		[0, 9, 18, 27, 36])
	check(int(d["left_sum"]) == TOTAL_CARDS, tag + ": sum(_left) == " + str(d["left_sum"])
		+ " at the deal - the burn, the first-hand cards and the 10-card family batch decremented nothing")
	check(int(d["audio"]) == 3, tag + ": the 2p deal made 3 slide sounds = 2 animated first-hand cards +"
		+ " 1 for the 10-card family batch - one sound for the batch at 2p too, where the batch is the"
		+ " biggest of the game (5 + 5 cards)")
	# the first turn-start draw: the row shrinks in the SAME frame the family card is popped
	await _human_draw(main, 2)
	# the tap commits the draw; the drawn card lands in the hand when its flight ends
	var landed: int = 0
	while landed < 300 and not (int(p0.family_size()) == 4 and int(p0.hand.get_child_count()) == 2):
		await get_tree().process_frame
		landed += 1
	check(int(p0.family_size()) == 4 and int(p0.hand.get_child_count()) == 2, tag + ": the turn-start"
		+ " draw popped family[2] and built the 2-card hand (family " + str(p0.family_size())
		+ ", hand " + str(int(p0.hand.get_child_count())) + ", settled in " + str(landed)
		+ " frames) - step 12's pop, asked for by step 21's modal")
	_check_stack_p(tag + " after the turn-start draw", p0, ["Guard", "Guard", "Guard", "Countess"],
		[0, 9, 18, 27])
	check(int(main._deck._left[int(Deck.CardType.Countess)]) == 1, tag + ": the drawn Countess is NOT out"
		+ " of play (_left Countess = " + str(main._deck._left[int(Deck.CardType.Countess)])
		+ " of 1) - `deal_from_family` decrements nothing (step 19): a family draw is a private hand, not"
		+ " a play, and no `play`/`discard` path runs on it")
	main.queue_free()
	await await_frames(2)


# ---- K3: the stack is a MIRROR of the family data in every frame ----
func _view_watcher() -> Dictionary:
	return {"frames": 0, "skips": 0, "changes": 0, "private": 0, "human": 0, "reveal": 0,
		"violations": [], "prev": -1, "stop": false}


# `render_family()` after EVERY family change, pinned frame by frame. A missed call is INVISIBLE to a
# per-round snapshot - the NEXT change re-renders and repairs the nodes - so the only way to see it is
# to compare, on every frame, the nodes a seat shows with the family data it owns:
#
#   want = family size   for the human seat (his stack IS his family, step 15)
#   want = family size   for an OUT seat (the elimination reveal, step 16)
#   want = 0            for a live AI seat (the family is private, step 15)
#
# Frames with a `discard()` in flight are SKIPPED, not counted: `discard()` materializes nodes next to
# the data for a few frames (the progress-notes rule: hand/family cards at `discard()` time), and step
# 16/19 pin that window - step 23 must not fight it. A whole elimination window (`set_inactive`: the
# seat's face is cleared, THEN hand and family are revealed, THEN discarded, THEN the data is cleared)
# is skipped for the same reason - an out seat with 3 family cards and no nodes is a legitimate frame
# inside it. Frames with the family modal OPEN are SAMPLED: the panel's row cards live in the
# FamilySelector node, so an open panel must not touch the stack.
func _watch_family_view(main, w) -> void:
	while int(w["frames"]) < 40000 and not bool(w["stop"]):
		w["frames"] = int(w["frames"]) + 1
		var window: bool = int(main.discard_depth) > 0 or int(main.reveal_depth) > 0
		if window:
			# a discard/reveal window: `discard()` materializes nodes next to the data and an elimination
			# reveals hand+family, discards them and clears the data. Frames INSIDE a window are SAMPLED
			# (the reveal is exactly what this watcher must see) but they are NOT judged: their transient
			# states are step 16/19's property, not step 23's.
			w["skips"] = int(w["skips"]) + 1
		var total: int = 0
		for i in 4:
			var p: Player = main._players[i]
			var data: int = p.family_size()
			var nodes: int = p.family_root.get_child_count()
			total += data
			var want: int = data if (p.is_human() or not p.is_active()) else 0
			if nodes != want and not window:
				w["violations"].append("frame " + str(w["frames"]) + " seat " + str(i) + ": " + str(nodes)
					+ " nodes vs " + str(data) + " family cards, want " + str(want) + " (active "
					+ str(p.is_active()) + ", human " + str(p.is_human()) + ", family " + family_str(p)
					+ ")")
			if data > 0 and nodes == 0 and p.is_active() and not p.is_human():
				w["private"] = int(w["private"]) + 1
			if data > 0 and nodes == data and p.is_human():
				w["human"] = int(w["human"]) + 1
			if data > 0 and nodes == data and not p.is_active():
				w["reveal"] = int(w["reveal"]) + 1
		if int(w["prev"]) >= 0 and total != int(w["prev"]):
			w["changes"] = int(w["changes"]) + 1
		w["prev"] = total
		await get_tree().process_frame
	w["stop"] = true


# K3a: an all-AI game with ONE elimination - the reveal, the clear, the round end and the re-deal,
# every one of them a `render_family()` call site, all sampled frame by frame.
func _test_family_view_ai() -> void:
	var tag := "K3a"
	var main = _scripted_main(4, NOBLE_4P_GUARD_KILL, NOBLE_4P_GUARD_KILL_LEFT)
	var wv = _view_watcher()
	_watch_family_view(main, wv)
	await _settle_deal(main)
	var settle: int = 0
	while main.effect_log.size() < 1 and settle < 400:
		await get_tree().process_frame
		settle += 1
	var kill: int = int(main.eliminations)
	settle = 0
	while main.round_end_actor.size() < 1 and settle < 2000:
		await get_tree().process_frame
		settle += 1
	var ends: int = int(main.round_end_actor.size())
	settle = 0
	while main.deal_states.size() < 2 and settle < 2000:
		await get_tree().process_frame
		settle += 1
	var redeals: int = int(main.deal_states.size())
	wv["stop"] = true
	await await_frames(2)
	check(int(main.eliminations) == kill and kill == 1 and main.round_end_actor.size() >= 1
		and main.deal_states.size() >= 2, tag + ": the fixture ran play 1 (the Guard that kills seat 1),"
		+ " the round end and the re-deal (" + str(main.effect_log.size()) + " plays, " + str(kill)
		+ " elimination, " + str(ends) + " round end(s), " + str(redeals) + " deals recorded) - the"
		+ " watcher sampled the elimination reveal and the round transition, not a settled board")
	check(int(wv["frames"]) >= 40, tag + ": " + str(wv["frames"]) + " frames sampled in one real game"
		+ " (skipped " + str(wv["skips"]) + " frames with a discard/reveal in flight) - the mirror"
		+ " contract is checked EVERY frame, the only sampling that can see a missed `render_family()`")
	check((wv["violations"] as Array).is_empty(), tag + ": in EVERY sampled frame each seat's family"
		+ " stack equalled what it should (" + str(wv["violations"]) + ") - the human shows his"
		+ " family, an out seat shows what he left, a live AI seat shows nothing, and every family change"
		+ " (draw, reveal, clear, re-deal) left the stack matching in the SAME frame it changed the data:"
		+ " `render_family()` runs at all four call sites, never one frame late")
	check(int(wv["reveal"]) >= 1, tag + ": " + str(wv["reveal"]) + " frames show an OUT seat's stack"
		+ " equal to the family he left with (seat 1: 3 cards, revealed face-up by `reveal_family`) -"
		+ " step 23's render runs on the elimination path too: the reveal is SAMPLED (it happens inside"
		+ " the elimination window, which is not judged) and its nodes leave with the data")
	check(int(wv["private"]) >= 1, tag + ": " + str(wv["private"]) + " frames show a live AI seat with a"
		+ " non-empty family and 0 nodes - the mirror is selective: it renders families, never leaks them")
	check(int(wv["changes"]) >= 5, tag + ": the total family count changed on " + str(wv["changes"])
		+ " frames (family draws, the elimination clear, the +12-card re-deal) and on EVERY one of them"
		+ " the stacks matched: each change is a `render_family()` call site - step 12's turn-start draw,"
		+ " step 21's modal draw, step 16's reveal, step 15's re-deal - and step 23 is the render that"
		+ " must follow each one")
	check(int(wv["skips"]) >= 1, tag + ": " + str(wv["skips"]) + " frames were skipped for a discard/reveal"
		+ " in flight - the harness does not pretend the elimination's own window (reveal, discard, clear)"
		+ " is a mirror violation (step 16/19 own it); skipping is what keeps this gate honest")
	main.queue_free()
	await await_frames(2)


# K3b: the human seat, with the modal rails open - the stack under a panel, under mid-effect draws and
# under a round transition. The taps come from `_watch_rails`, the same rails step 22 runs.
func _test_family_view_human() -> void:
	var tag := "K3b"
	var main = _scripted_main_human(4, NOBLE_4P_RAILS, NOBLE_4P_RAILS_LEFT)
	var w = _rail_watcher(NOBLE_4P_RAILS_TAPS)
	var wv = _view_watcher()
	await _rails_settle(main, w)
	_watch_family_view(main, wv)
	await _human_play_idx(main, 1, 0, Deck.CardType.Unknown, -1, tag + " r1 play 1")
	await _human_play_idx(main, 0, 1, Deck.CardType.Unknown, -1, tag + " r1 play 2")
	var settle: int = 0
	while main.round_end_actor.size() < 1 and settle < 500:
		await get_tree().process_frame
		settle += 1
	var ends: int = main.round_end_actor.size()
	await main._on_round_over_pressed()
	await _rails_redeal(main, w)
	await _human_play_idx(main, 0, 1, Deck.CardType.Unknown, -1, tag + " r2 play 1")
	var taps: int = int(w["tapped"].size())
	var opens: int = int(w["openings"])
	w["stop"] = true
	wv["stop"] = true
	await await_frames(2)
	check(main.round_end_actor.size() >= 1 and int(w["openings"]) >= 3 and taps >= 3, tag + ": the"
		+ " fixture ran 2 rounds with the modal rails live (" + str(ends) + " round end(s), " + str(opens)
		+ " openings, " + str(taps) + " taps, " + str(main.effect_log.size()) + " plays) - the mirror is"
		+ " sampled on the human seat DURING the panel's life, not after it closes")
	check((wv["violations"] as Array).is_empty(), tag + ": in EVERY frame of a live human game -"
		+ " including every frame a family modal is OPEN (" + str(opens) + " openings),"
		+ " every turn-start tap, the mid-effect Prince draw inside a play chain, the round end and the"
		+ " re-deal - seat 0's stack equalled his family data and the 3 AI seats showed nothing ("
		+ str(wv["violations"]) + " of " + str(wv["frames"]) + " frames): the panel's row cards live in"
		+ " the FamilySelector node, so an open modal never touches the stack, and a draw that pops a"
		+ " family card re-renders the stack in the same frame")
	check(int(wv["human"]) >= 15, tag + ": " + str(wv["human"]) + " frames show the human's stack"
		+ " matching his family data with a NON-EMPTY family - the cascade the player reads is not a"
		+ " snapshot of the deal, it is kept in step with every draw for the whole round")
	check(int(wv["private"]) >= 1, tag + ": " + str(wv["private"]) + " frames show the 3 AI seats with"
		+ " families and no pixels - a human game with the modal open stays a private game")
	check(int(wv["changes"]) >= 5, tag + ": " + str(wv["changes"]) + " frames changed the family totals"
		+ " (2 rounds of draws + the +12 re-deal) and every one of them matched - the row the modal shows"
		+ " and the stack the seat shows are the SAME data, re-rendered at every change, which is what"
		+ " step 22's `row == live family data` check relies on")
	check(int(main.family_draws[0]) >= 3, tag + ": seat 0 drew " + str(main.family_draws[0])
		+ " family cards through the modal in 2 rounds - each one re-rendered his stack, and the stack"
		+ " matched in the frame it shrank (step 12's pop, step 21's tap, step 23's render)")
	_check_no_leak(main, tag + " end")
	main.queue_free()
	await await_frames(2)


# ---- K4: the deal is timed on the wall clock, at the speeds the menu offers, classic as the control --
func _time_first_deal(count: int, noble: bool, speed: float) -> int:
	var main = _deal_main(count, noble)
	Animator._speed = speed
	await main.init_players(SEED)
	await await_until(func() -> bool: return main.setup_ms.size() >= 1, 60000)
	var ms: int = int(main.setup_ms[0]) if main.setup_ms.size() > 0 else -1
	Animator._speed = 0.0
	main.queue_free()
	await await_frames(2)
	return ms


func _test_deal_timing() -> void:
	var tag := "K4"
	var n4: int = 0
	var c4: int = 0
	var n2: int = 0
	var c2: int = 0
	var n3: int = 0
	var n4f: int = 0
	n4 = await _time_first_deal(4, true, 2.0)
	c4 = await _time_first_deal(4, false, 2.0)
	n2 = await _time_first_deal(2, true, 2.0)
	c2 = await _time_first_deal(2, false, 2.0)
	n3 = await _time_first_deal(3, true, 2.0)
	n4f = await _time_first_deal(4, true, 5.0)
	# The flight of ONE first-hand card is `Animator._move_duration(0.5)` = 0.5 / speed seconds, and the
	# deal awaits them one after another, so the deal of `count` seats costs count x that at speed 2.
	var want4: int = int(round(count_ms(4, 2.0)))
	var want2: int = int(round(count_ms(2, 2.0)))
	var want3: int = int(round(count_ms(3, 2.0)))
	var want4f: int = int(round(count_ms(4, 5.0)))
	check(n4 >= want4 - 100 and n4 <= want4 + 500, tag + ": the 4p variant deal took " + str(n4)
		+ " ms at Animator._speed 2 (the menu speed labelled 3), expected ~" + str(want4) + " ms = 4"
		+ " animated first-hand cards x 0.5/2 s - the deal IS the first-hand animation, on REAL timers,"
		+ " measured `_new_round()` entry -> the round's FIRST turn")
	check(n3 >= want3 - 100 and n3 <= want3 + 500, tag + ": the 3p deal took " + str(n3) + " ms at speed"
		+ " 2, expected ~" + str(want3) + " ms = 3 first-hand flights (12 family cards, 0 extra flights)")
	check(n2 >= want2 - 100 and n2 <= want2 + 500, tag + ": the 2p deal took " + str(n2)
		+ " ms at speed 2, expected ~" + str(want2) + " ms = 2 first-hand flights (10 family cards, the"
		+ " biggest batch of the game, 0 extra flights)")
	check(n4f >= want4f - 100 and n4f <= want4f + 400, tag + ": the 4p deal took " + str(n4f)
		+ " ms at speed 5, expected ~" + str(want4f) + " ms - under a second at 4p on the fastest speed"
		+ " the menu offers, exactly the todo's `under ~1s at 4p`")
	check(abs(n4 - c4) <= 200 and abs(n2 - c2) <= 200, tag + ": the variant deal costs the CLASSIC deal"
		+ " the same wall-clock time - 4p " + str(n4) + " ms vs " + str(c4)
		+ " ms, 2p " + str(n2) + " ms vs " + str(c2) + " ms at speed 2 - the family batch adds 0 ms of"
		+ " animation: the 12/10/8 family cards are DATA + one stack render, materialized in the instant"
		+ " the round opens, so the player waits for exactly the " + str(4) + " first-hand cards he"
		+ " already waits for in classic")
	check(n4f < n4, tag + ": the same 4p deal runs " + str(n4f) + " ms at _speed 5 vs " + str(n4)
		+ " ms at _speed 2 - the timing follows the speed setting, so the family deal is measured on the"
		+ " speed the game is played at, not on `_speed = 0` where a whole round collapses into frames")


func count_ms(count: int, speed: float) -> float:
	return count * (0.5 / speed) * 1000.0

# ----------------------------------------------------------------------------------------
# TEST L (todo step 24): the mode picker `game_mode/game_mode.tscn` - the scene PLAY opens before a
# game starts. Three rows in the `start.tscn` shape (a Label row + ONE flat, full-area Button),
# closed until `application.gd` opens it, ONE signal per press, the panel hidden BEFORE the choice is
# reported, nothing tappable while it is closed, and NO state stored: the todo's fixed rule is that
# the mode is chosen per game and never persisted, so the picker must have nowhere to keep a mode.
# ----------------------------------------------------------------------------------------
const GM_ROWS: Array = ["CLASSIC", "NOBLE FAMILY", "BACK"]
const USAGE_SCRIPT: int = 4096  # Godot 4 exposes PropertyUsageFlags as ints; 4096 = a script variable

var gm_notes: Array[String] = []


func _test_game_mode() -> void:
	print("\n########## TEST L: the mode picker (step 24) - 3 rows, closed until opened, ONE ##########")
	print("########## signal per press, hide BEFORE emit, no marks, no state, taps inside 84x48 ##########")
	await _test_gm_shape()
	await _test_gm_open()
	await _test_gm_press()
	await _test_gm_stateless()
	await _test_gm_geometry()


func _gm_panel():
	var panel = GameModeScene.instantiate()
	add_child(panel)
	await await_frames(1)
	return panel


func _gm_free(panel) -> void:
	panel.queue_free()
	await await_frames(2)


# The 3 menu rows = the Labels that own exactly one child (the Button); the Title has no child
func _gm_rows(panel) -> Array:
	var out: Array = []
	for ch in panel.get_children():
		if ch is Label and (ch as Control).get_child_count() == 1:
			out.append(ch)
	out.sort_custom(_gm_cmp_y)
	return out


func _gm_cmp_y(a, b) -> bool:
	return (a as Control).position.y < (b as Control).position.y


func _gm_texts(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append((r as Label).text)
	return out


func _gm_button(row) -> BaseButton:
	for ch in (row as Node).get_children():
		if ch is BaseButton:
			return ch as BaseButton
	return null


func _gm_mods(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append(int(int((r as CanvasItem).modulate.a * 100)))
	return out


func _gm_classes(node: Node) -> Array:
	var out: Array = []
	for ch in node.get_children():
		out.append(str(ch.get_class()))
		out.append_array(_gm_classes(ch))
	return out


func _gm_count_class(classes: Array, wanted: String) -> int:
	var n: int = 0
	for c in classes:
		if str(c) == wanted:
			n += 1
	return n


# The rows are Buttons, so a real tap IS the `pressed` signal (this scene has no Area2D, unlike the
# cards): emitting the signal drives the SAME connection the engine's GUI input drives.
func _gm_press(btn: BaseButton) -> void:
	btn.emit_signal("pressed")


# Records the panel's OWN visibility at the instant the choice is reported - the hide-then-emit order
# of the todo's handlers is only visible from inside the emit
func _gm_note(tag: String, panel) -> void:
	gm_notes.append(tag + ":" + str((panel as CanvasItem).visible))


# The rendered width of a row's text: the LabelSettings resource is what the game's labels draw with
# (a LabelSettings is NOT a theme item, so get_theme_font_size would report the 16 px default)
func _gm_text_w(lbl) -> int:
	var fs: int = 7
	var f: Font = null
	if (lbl as Label).label_settings != null:
		fs = (lbl as Label).label_settings.font_size
		f = (lbl as Label).label_settings.font
	if f == null:
		f = (lbl as Control).get_theme_font("font")
	return int(ceil(f.get_string_size((lbl as Label).text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x))


# L1: the shape - 3 rows, 1 flat full-area Button each, 7 nodes, nothing else
func _test_gm_shape() -> void:
	var tag := "L1"
	var panel = await _gm_panel()
	var rows: Array = _gm_rows(panel)
	check(rows.size() == 3, tag + ": the picker has EXACTLY 3 rows (measured " + str(rows.size())
		+ ") - 4 rows would be a mode the todo does not define, 2 rows would make a mode unreachable")
	check(_gm_texts(rows) == GM_ROWS, tag + ": the rows read CLASSIC, NOBLE FAMILY, BACK top-to-bottom "
		+ "(measured " + str(_gm_texts(rows)) + ") - the player reads the mode he is about to play, "
		+ "not an icon")
	var classes: Array = _gm_classes(panel)
	check(_gm_count_class(classes, "Label") == 4 and _gm_count_class(classes, "Button") == 3
		and classes.size() == 7, tag + ": the whole scene is 4 Labels + 3 Buttons and NOTHING else - "
		+ "no Panel, LineEdit, TextureButton, Sprite, Timer, ColorRect (measured " + str(classes)
		+ "): the start page shape, 7 nodes on an 84 x 48 board")
	var flat_all: bool = true
	var full_area: bool = true
	for r in rows:
		var btn: BaseButton = _gm_button(r)
		if btn == null:
			flat_all = false
			full_area = false
			continue
		if !btn.flat:
			flat_all = false
		var rr: Rect2 = (r as Control).get_global_rect()
		var br: Rect2 = btn.get_global_rect()
		if !(br.position.x <= rr.position.x and br.position.y <= rr.position.y and br.end.x >= rr.end.x
			and br.end.y >= rr.end.y):
			full_area = false
	check(flat_all, tag + ": every row's Button is `flat` - the picker has NO chrome, exactly like "
		+ "PLAY/SETTINGS/STATS/HELP; a framed button does not fit an 8 px row")
	check(full_area, tag + ": every row's Button covers its FULL row rect - the whole word is the tap "
		+ "target, not the ink of the text, so a tap beside a centered label still presses the row")
	check(_gm_button(rows[0]) != null and _gm_button(rows[1]) != null and _gm_button(rows[2]) != null,
		tag + ": every row owns EXACTLY ONE Button - a Label with 0 children is a caption the player "
		+ "cannot press, and 2 Buttons in a row is two ways to press the same mode")
	var centered: bool = true
	for r in rows:
		if int((r as Label).horizontal_alignment) != 1:
			centered = false
	check(centered, tag + ": every row is centered (the game's menus are) - a left-aligned row on an "
		+ "84 px board puts the tap target where the player is not looking")
	await _gm_free(panel)


# L2: closed until opened - and the engine's own visibility gate is what keeps it inert
func _test_gm_open() -> void:
	var tag := "L2"
	var panel = await _gm_panel()
	var rows: Array = _gm_rows(panel)
	check(!panel.visible, tag + ": the picker is CLOSED at _ready() - a picker that is visible at scene"
		+ " setup is a picker the player can press while the start page owns the screen")
	var rows_hidden: bool = true
	for r in rows:
		rows_hidden = rows_hidden and !(r as Control).visible
	check(rows_hidden, tag + ": every ROW is hidden at _ready(), not only the panel - the todo's "
		+ "`_ready() hides all rows until show()`")
	var tappable: bool = false
	for r in rows:
		tappable = tappable or _gm_button(r).is_visible_in_tree()
	check(!tappable, tag + ": with the rows hidden NO Button is visible in the tree, so the engine "
		+ "gives all 3 zero mouse input - the closed picker is inert by the engine's visibility gate, "
		+ "not by a flag we have to remember to check")
	check(panel.has_method("show_rows"), tag + ": the picker exposes show_rows() as its opening path")
	panel.call("show_rows")
	await await_frames(1)
	var rows_shown: bool = true
	var tappable2: bool = true
	for r in rows:
		rows_shown = rows_shown and (r as Control).visible
		tappable2 = tappable2 and _gm_button(r).is_visible_in_tree()
	check(panel.visible, tag + ": show_rows() opens the panel")
	check(rows_shown, tag + ": show_rows() opens all 3 rows together - a half-shown picker (2 rows of "
		+ "3) hides a mode")
	check(tappable2, tag + ": all 3 Buttons are visible in the tree in the SAME open, so CLASSIC, "
		+ "NOBLE FAMILY and BACK are all pressable in one visit - the todo's Check (all three rows "
		+ "tappable in 84 x 48), measured through the engine's own input gate")
	panel.call("show_rows")
	await await_frames(1)
	check(panel.visible and _gm_rows(panel).size() == 3, tag + ": show_rows() is IDEMPOTENT - PLAY, "
		+ "BACK, PLAY again shows the same 3 rows: no duplicated rows, no stacked panel, no extra node")
	var shown_rows: int = 0
	for r in _gm_rows(panel):
		if (r as Control).visible:
			shown_rows += 1
	check(shown_rows == 3, tag + ": the idempotent re-open shows 3 rows, not 4, 5 or 6 (measured "
		+ str(shown_rows) + ") - the picker rebuilds nothing, it just shows what the scene has")
	panel.call("_hide_rows")
	panel.hide()
	await await_frames(1)
	var native_opens_rows: bool = false
	for r in rows:
		if (r as Control).visible:
			native_opens_rows = true
	panel.show()
	await await_frames(1)
	check(panel.visible and !native_opens_rows, tag + ": the NATIVE CanvasItem.show() opens the root "
		+ "only and leaves every row hidden - DEVIATION from the todo wording, measured: `func show()`"
		+ " is a PARSE ERROR in Godot 4.7 (overrides a method from native class CanvasItem, a warning "
		+ "treated as error), so show_rows() is the only opening path and rows are the gate")
	await _gm_free(panel)


# L3: one press = one signal = one closed panel, and the panel is gone BEFORE the choice is reported
func _test_gm_press() -> void:
	var tag := "L3"
	var panel = await _gm_panel()
	panel.connect("classic_pressed", _gm_note.bind("classic", panel))
	panel.connect("noble_family_pressed", _gm_note.bind("noble", panel))
	panel.connect("back_pressed", _gm_note.bind("back", panel))
	var rows: Array = _gm_rows(panel)
	panel.call("show_rows")
	await await_frames(1)
	gm_notes.clear()
	_gm_press(_gm_button(rows[0]))
	check(gm_notes.size() == 1, tag + ": pressing the CLASSIC row emits EXACTLY ONE signal (measured "
		+ str(gm_notes) + ") - a double emit would ask application.gd to start two games")
	check(gm_notes.size() == 1 and gm_notes[0] == "classic:false", tag + ": and the panel is ALREADY "
		+ "HIDDEN at the instant the choice is reported (hide() first, emit second, the todo's handler "
		+ "shape) - a menu that stays open while a game deals cards is a stuck overlay")
	check(!panel.visible, tag + ": the press closed the panel by itself - application.gd only wires "
		+ "handlers, so a panel that relied on its listener to hide it would sit on the board")
	gm_notes.clear()
	panel.call("show_rows")
	await await_frames(1)
	_gm_press(_gm_button(rows[1]))
	check(gm_notes.size() == 1 and gm_notes[0] == "noble:false", tag + ": pressing NOBLE FAMILY emits "
		+ "noble_family_pressed ONLY - no classic, no back (measured " + str(gm_notes) + ")")
	gm_notes.clear()
	panel.call("show_rows")
	await await_frames(1)
	_gm_press(_gm_button(rows[2]))
	check(gm_notes.size() == 1 and gm_notes[0] == "back:false", tag + ": pressing BACK emits "
		+ "back_pressed ONLY - BACK is NOT a mode: it reports no choice and application.gd shows the "
		+ "start page; a BACK that also emitted a mode would start the game the player just refused")
	var inert: bool = true
	for r in rows:
		if _gm_button(r).is_visible_in_tree():
			inert = false
	check(inert, tag + ": after a press every row is out of the tree's input again, so a second real "
		+ "tap has NO target - one visit reports one mode, and the panel cannot be pressed twice")
	var found: Array = []
	var arity_ok: bool = true
	for s in panel.get_signal_list():
		var nm: String = str(s.name)
		if nm == "classic_pressed" or nm == "noble_family_pressed" or nm == "back_pressed":
			found.append(nm)
			if int((s.args as Array).size()) != 0:
				arity_ok = false
	found.sort()
	check(found.size() == 3 and arity_ok, tag + ": the picker's API is 3 parameterless signals named "
		+ "classic_pressed / noble_family_pressed / back_pressed (measured " + str(found) + ") - the "
		+ "names the todo fixes for application.gd to wire, and NO payload: the picker reports WHICH "
		+ "row, it does not report a mode value, a player count or a level")
	await _gm_free(panel)


# L4: the picker stores nothing - no last mode, no mark, no node added by a press
func _test_gm_stateless() -> void:
	var tag := "L4"
	var panel = await _gm_panel()
	var rows: Array = _gm_rows(panel)
	var texts_before: Array = _gm_texts(rows)
	var mods_before: Array = _gm_mods(rows)
	var classes_before: Array = _gm_classes(panel)
	panel.connect("classic_pressed", _gm_note.bind("classic", panel))
	panel.connect("noble_family_pressed", _gm_note.bind("noble", panel))
	panel.connect("back_pressed", _gm_note.bind("back", panel))
	gm_notes.clear()
	for i in 3:
		panel.call("show_rows")
		await await_frames(1)
		_gm_press(_gm_button(_gm_rows(panel)[i]))
		await await_frames(1)
	var joined: String = ""
	for n in gm_notes:
		joined = joined + str(n) + " "
	check(joined == "classic:false noble:false back:false ", tag + ": 3 visits, 3 presses, 3 signals, "
		+ "each in its OWN signal and each after its own hide (measured '" + joined + "') - the picker "
		+ "is reusable across games: PLAY -> NOBLE FAMILY -> exit -> PLAY -> CLASSIC is the todo's "
		+ "Check, and it needs a panel that resets, not a panel that remembers")
	check(_gm_texts(_gm_rows(panel)) == texts_before, tag + ": no row's text changed after 3 presses -"
		+ " no LAST MODE line, no tick, no moved selection sprite (measured " + str(_gm_texts(rows))
		+ "): the mode is NOT remembered, per the fixed rule `mode is not persisted`")
	check(_gm_mods(_gm_rows(panel)) == mods_before, tag + ": no row is dimmed, lit, greyed or "
		+ "highlighted by a press (measured " + str(_gm_mods(_gm_rows(panel))) + " vs "
		+ str(mods_before) + "): a highlighted last mode IS a persisted mode, on screen")
	check(_gm_classes(panel) == classes_before, tag + ": 3 presses added NO nodes - no banner, "
		+ "checkmark, Timer, Label, tooltip (measured " + str(_gm_classes(panel)) + ")")
	var script_vars: Array = []
	for p in panel.get_property_list():
		if (int(p.usage) & USAGE_SCRIPT) != 0:
			script_vars.append(str(p.name))
	check(script_vars.is_empty(), tag + ": the scene declares NO script variables at all (measured "
		+ str(script_vars) + ") - there is nowhere to keep a mode, so `not persisted` is STRUCTURAL: "
		+ "no `_last_mode`, no exported default, no ConfigFile write in a menu scene")
	await _gm_free(panel)


# L5: the geometry a thumb has to hit - 3 rows inside 84 x 48, non-overlapping, ordered, readable
func _test_gm_geometry() -> void:
	var tag := "L5"
	var panel = await _gm_panel()
	var rows: Array = _gm_rows(panel)
	panel.call("show_rows")
	await await_frames(1)
	var inside_rows: bool = true
	var inside_btns: bool = true
	var rects: Array = []
	var row_report: Array = []
	for r in rows:
		var rr: Rect2 = (r as Control).get_global_rect()
		var br: Rect2 = _gm_button(r).get_global_rect()
		rects.append(br)
		row_report.append(str((r as Label).text) + " row[" + str(int(rr.position.x)) + ","
			+ str(int(rr.position.y)) + "]-[" + str(int(rr.end.x)) + "," + str(int(rr.end.y))
			+ "] tap[" + str(int(br.position.x)) + "," + str(int(br.position.y)) + "]-["
			+ str(int(br.end.x)) + "," + str(int(br.end.y)) + "]")
		if !(rr.position.x >= 0 and rr.end.x <= 84 and rr.position.y >= 0 and rr.end.y <= 48):
			inside_rows = false
		if !(br.position.x >= 0 and br.end.x <= 84 and br.position.y >= 0 and br.end.y <= 48):
			inside_btns = false
	print("      " + str(row_report))
	check(inside_rows, tag + ": every row label lies INSIDE the 84 x 48 viewport - a clipped row is a "
		+ "word a player cannot finish reading on a phone")
	check(inside_btns, tag + ": every tap target lies INSIDE the 84 x 48 viewport - the todo's Check "
		+ "(all three rows tappable in 84 x 48), measured as the Buttons' global rects")
	var big: bool = true
	for br in rects:
		if !((br as Rect2).size.x >= 48 and (br as Rect2).size.y >= 8):
			big = false
	check(big, tag + ": every tap target is at least 48 x 8 board px = 384 x 64 REAL px at the 8x "
		+ "viewport scale - the same target size the start page rows give PLAY/STATS/HELP")
	var no_overlap: bool = true
	for i in rects.size():
		for j in rects.size():
			if i != j and (rects[i] as Rect2).intersects(rects[j] as Rect2):
				no_overlap = false
	check(no_overlap, tag + ": the 3 tap rects do NOT overlap - overlapping rows make BACK steal a "
		+ "CLASSIC press (and a mis-press starts a whole game)")
	var ordered: bool = true
	for i in rects.size() - 1:
		if (rects[i] as Rect2).end.y > (rects[i + 1] as Rect2).position.y:
			ordered = false
	check(ordered, tag + ": the rows are stacked in reading order with a gap between the tap targets "
		+ "(CLASSIC above NOBLE FAMILY above BACK) - the last row's target ends inside the board, so "
		+ "no row is under the screen edge")
	var fits: bool = true
	var width_report: Array = []
	for r in rows:
		var w: int = _gm_text_w(r)
		var room: int = int((r as Control).get_rect().size.x)
		width_report.append(str((r as Label).text) + "=" + str(w) + "/" + str(room))
		if w > room:
			fits = false
	check(fits, tag + ": every row's text FITS its label rect at the game's 7 px font (measured "
		+ str(width_report) + ") - NOBLE FAMILY is the longest word the picker prints and it needs "
		+ "48 of the 76 px available, so the menu needs no second line, no smaller font and no"
		+ " landscape-only layout")
	var title: Control = panel.get_node("Title") as Control
	var title_rect: Rect2 = title.get_global_rect()
	check(title_rect.end.x <= 84 and title_rect.position.y >= 0, tag + ": the title label is inside "
		+ "the board too")
	check(title_rect.end.y <= (rects[0] as Rect2).position.y, tag + ": the title sits ABOVE the first "
		+ "mode row - the picker reads title, then the two modes, then BACK; a title between the rows "
		+ "is a row a player reads as a mode")
	check((rects[2] as Rect2).end.y <= 48, tag + ": the BACK row is the LAST thing on the panel and "
		+ "it clears the bottom edge - the player always has a way out, on screen, at the bottom")
	await _gm_free(panel)



# ----------------------------------------------------------------------------------------
# TEST M (todo step 25): the mode menu is WIRED into the application.
#
# TEST L pinned the picker SCENE. This pins the WIRING - the two things a scene cannot pin by itself:
# (1) the ORDER of the mode decision, and (2) that a menu press is the ONLY thing that starts a game.
#
#  1. `Main.noble_family` must be set BEFORE `init_players()` runs, because `init_players()` ->
#     `_new_game()` -> `_new_round()` READS the flag once, at the deal, to choose the deal table.
#     Sampling the flag after a row press cannot tell "set then start" from "start then set", so
#     `tests/counting_application.gd` records the flag at the ENTRY of `start_game()` and of
#     `init_players()`.
#  2. PLAY opens the picker and starts NOTHING (0 `start_game()` calls, 0 deals); BACK starts nothing
#     and sets no mode; a ROW press is the only path that deals; Exit-to-menu CLEARS the mode (the
#     picker stores nothing - TEST L, zero script variables - so the application is the only place a
#     mode can be cleared); `speed_run` bypasses the menu and stays classic-only.
#
# Five fixtures, the four gates plus the speed-run boot path:
#   M1 PLAY -> the picker, and nothing else.
#   M2 NOBLE row -> a VARIANT game: family 3 per seat in 4p, every turn-start draw from a family,
#      zero pile draws, the move/draw pairing and the `_left` audit clean.
#   M3 BACK -> the start page, no game.
#   M4 variant game -> in-game menu -> Exit -> PLAY -> CLASSIC: the mode is cleared, the deal is the
#      CLASSIC one (no families anywhere, main pile 9 + widow 3 in 4p, draws from the pile, zero
#      family draws), and the counters are measured as DELTAS of the classic game only.
#   M5 `speed_run` boots straight into a classic game, menu untouched.
#
# Fixture technique: the REAL `application.tscn`, instrumented by `set_script` with
# `tests/counting_application.gd` (the seams) and `tests/counting_main.gd` (the event recorders). The
# scene's own PLAY / row / Exit buttons are pressed by emitting their `pressed` signal - the same
# connection the engine's GUI input drives (a headless window is 64x64, so a real tap is never
# delivered; see TEST L).
# ----------------------------------------------------------------------------------------
const AppScene := preload("res://application/application.tscn")
const CountingAppScript := "res://tests/counting_application.gd"  # load()ed at runtime: preload()
# of a script that extends Application is a cyclic dependency with the preload of application.tscn
const GM_BUTTONS: Dictionary = {"CLASSIC": "ClassicRow/ClassicButton",
	"NOBLE": "NobleRow/NobleButton", "BACK": "BackRow/BackButton"}
const NOBLE_FAMILY_4P: int = 3  # Deck.NOBLE_FAMILY_SIZE[4]
const CLASSIC_4P_MAIN: int = 11  # classic 4p: 16 - burn 1 - 4 first-hand cards
const CLASSIC_4P_WIDOW: int = 1  # classic burns 1 in 3p/4p (the variant burns NOTHING in 4p)


# Build and settle are SEPARATE functions: a Player's `ai_level` setter writes `@onready` sprites, so
# levels can only be applied once the node is in the tree, which makes the settle half a coroutine;
# and Godot 4 rejects a call to a coroutine without `await`. The levels travel in `_menu_levels`.
var _menu_levels: Array = []


func _test_mode_menu() -> void:
	print("\n########## TEST M: the mode menu wiring (step 25) - PLAY opens the picker and starts ##########")
	print("########## NOTHING, a row press sets the mode BEFORE the deal, BACK starts no game, ##########")
	print("########## Exit-to-menu CLEARS the mode, `speed_run` bypasses the menu, classic-only ##########")
	await _test_menu_play()
	await _test_menu_noble_game()
	await _test_menu_back()
	await _test_menu_exit_classic()
	await _test_menu_speed_run()


func _make_menu_app(speed_run: bool = false):
	var app = AppScene.instantiate()
	var main: Node = app.get_node("Main")
	var card_scene: PackedScene = main.card_scene  # `set_script` resets exported vars: save/restore
	main.set_script(load(CountingMainScript))
	main.card_scene = card_scene
	var exports: Dictionary = {}  # ... and so do the Application's own exports
	for k: String in ["random_seed", "speed_run", "print_memory", "print_valid_moves"]:
		exports[k] = app.get(k)
	app.set_script(load(CountingAppScript))
	for k: String in exports:
		app.set(k, exports[k])
	app.speed_run = speed_run
	add_child(app)
	return app


func _menu_ready(app) -> void:
	await await_frames(1)
	# `Application._ready()` -> `load_config()` restores the SAVED speed (2.0 = speed level 1) and the
	# SAVED levels (the saved file has a HUMAN seat 0, which parks a headless game at a tap), and it
	# runs AFTER this suite set `_speed = 0`, so the fixture pins both once the node is in the tree.
	Animator._speed = 0
	for i in 4:
		app._main._players[i].ai_level = _menu_levels[i]


func _free_menu_app(app) -> void:
	if app.get_tree().paused:
		app.get_tree().paused = false  # a tree left paused stops every later fixture's frames
	app.queue_free()
	await await_frames(2)


# ---- the presses: the scene's own buttons, the way TEST L presses them ----------------------
func _tap_start_play(app) -> void:
	(app._start.get_node("PlayLabel/PlayButton") as BaseButton).emit_signal("pressed")
	await await_frames(1)


func _tap_row(app, row: String) -> void:
	var gm: Node = app.get_node("GameMode") as Node
	(gm.get_node(GM_BUTTONS[row]) as BaseButton).emit_signal("pressed")
	await await_frames(1)


func _tap_pause_exit(app) -> void:
	(app._pause.get_node("ExitLabel/ExitButton") as BaseButton).emit_signal("pressed")
	await await_frames(1)


func _picker_targets(app) -> int:
	var gm: Node = app.get_node("GameMode") as Node
	var n := 0
	for row: String in ["ClassicRow", "NobleRow", "BackRow"]:
		if (gm.get_node(row) as Control).is_visible_in_tree():
			n += 1
	return n


# ---- measured quantities ---------------------------------------------------------------------
func _fam_sizes(main: Node) -> Array:
	var out: Array = []
	for p in main._players:
		out.append(p.family_size())
	return out


func _hand_sizes(main: Node) -> Array:
	var out: Array = []
	for p in main._players:
		out.append(p.hand.get_child_count())
	return out


func _sum_ints(vals: Array) -> int:
	var s := 0
	for v in vals:
		s += int(v)
	return s


# Cumulative counters of a Main node. A fixture that switches modes inside ONE application instance
# (which is exactly what M4 must do, because the mode-reset gate only exists in that sequence) has
# counters that mix two games, so every variant-only claim is measured as a DELTA.
func _counters(main: Node) -> Dictionary:
	return {
		"plays": main.effect_log.size(),
		"fam_draws": _sum_ints(main.family_draws),
		"pile_draws": main.pile_draws,
		"audits": main.left_audits,
		"viols": main.left_violations.size(),
		"pairings": main.draws_checked,
		"mismatches": main.draw_mismatches.size(),
	}


func _delta(now: Dictionary, base: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: String in now:
		out[k] = int(now[k]) - int(base[k])
	return out


func _settle_menu_deal(app, fam: int, main_cards: int) -> void:
	var main: Node = app._main
	# The settle is defined by the DEAL TABLE the fixture expects, not by "some frames": `init_players()`
	# does not await the deal, and at `_speed = 0` the whole deal + the first turn can settle inside a
	# few frames, so the poll waits for the exact state the mode is supposed to produce.
	var dealt := func() -> bool:
		# The main pile is a CEILING, not an equality: after the deal every turn draws from it, so a
		# poll that demands the exact deal-time count can race past it and time out. The family size and
		# the 1-card hand are the exact part of a deal table; the pile only ever shrinks from its
		# deal-time size.
		var ready: bool = main._deck._cards.size() <= main_cards
		for p in main._players:
			if p.is_active():
				ready = ready and p.hand.get_child_count() == 1
				ready = ready and p.family_size() == fam
		return ready
	await await_until(dealt, 6000)


func _run_menu_plays(app, wanted: int) -> void:
	var main: Node = app._main
	for _f in 12000:
		if main.effect_log.size() >= wanted:
			return
		await get_tree().process_frame


# ---- M1: PLAY opens the picker and starts NOTHING ------------------------------------------
func _test_menu_play() -> void:
	var tag := "M1 PLAY"
	var app = _make_menu_app()
	_menu_levels = [Player.AI_Level.Level_4, Player.AI_Level.Level_4,
		Player.AI_Level.Level_3, Player.AI_Level.Level_2]
	await _menu_ready(app)
	var main: Node = app._main
	check(app._start.visible and !app._main.visible, tag + ": at boot the start page is on screen "
		+ "and no game is shown")
	check(!app._game_mode.visible and _picker_targets(app) == 0, tag + ": the picker is CLOSED at boot "
		+ "and nothing on it is tappable (0 rows visible in the tree = the engine's own input gate)")
	check(app.play_presses == 0 and app.start_game_calls == 0 and main.init_calls == 0, tag
		+ ": nothing pressed, no game started, no deal run")
	check(!app._main.noble_family, tag + ": no mode is set at boot")

	await _tap_start_play(app)
	check(app.play_presses == 1, tag + ": PLAY reached the application exactly ONCE")
	check(app.start_game_calls == 0 and main.init_calls == 0, tag + ": PLAY started NO game and dealt "
		+ "NO cards - neither `start_game()` nor `init_players()` ran, which is the whole point of "
		+ "step 25: PLAY no longer starts a game, it opens a menu")
	check(!app._start.visible, tag + ": PLAY hid the start page")
	check(app._game_mode.visible and _picker_targets(app) == 3, tag + ": PLAY opened the picker with "
		+ "all 3 rows tappable (CLASSIC / NOBLE FAMILY / BACK)")
	check(!app._main.visible, tag + ": the game stays hidden while the menu is open")
	check(!app._main.noble_family, tag + ": PLAY set NO mode - the flag is set by a ROW, never by PLAY")
	await _free_menu_app(app)


# ---- M2: the NOBLE FAMILY row starts a VARIANT game, mode set BEFORE the deal ---------------
func _test_menu_noble_game() -> void:
	var tag := "M2 NOBLE row"
	var app = _make_menu_app()
	_menu_levels = [Player.AI_Level.Level_4, Player.AI_Level.Level_4,
		Player.AI_Level.Level_3, Player.AI_Level.Level_2]
	await _menu_ready(app)
	await _tap_start_play(app)
	await _tap_row(app, "NOBLE")
	var main: Node = app._main
	check(app.start_game_calls == 1 and main.init_calls == 1, tag + ": a row press is what starts a "
		+ "game - ONE `start_game()`, ONE deal")
	check(app.start_seams.size() == 1 and main.init_seams.size() == 1, tag + ": both seams recorded "
		+ "exactly one entry")
	var sh: Dictionary = app.start_seams[0]
	var seam: Dictionary = main.init_seams[0]
	check(bool(sh["noble"]), tag + ": `Main.noble_family` is TRUE ON ENTRY to `start_game()` - the "
		+ "handler handed the mode over BEFORE asking for the game")
	check(bool(seam["noble"]), tag + ": and it is STILL true on entry to `init_players()`, i.e. at the "
		+ "moment the deal is decided: `_new_round()` reads the flag exactly once, there. A flag set "
		+ "after this call would deal a CLASSIC round inside the game the player chose as Noble Family")
	check(bool(seam["main_visible"]), tag + ": the game is shown at the deal")
	check(!bool(seam["picker_visible"]) and int(seam["rows_in_tree"]) == 0, tag + ": the picker is "
		+ "CLOSED at the deal and zero rows are tappable - a menu still open while cards are dealing "
		+ "is a stuck overlay, and a row a player can press mid-deal starts a second game")
	check(!bool(seam["start_visible"]), tag + ": the start page is gone at the deal")
	check(!bool(seam["interrupted"]), tag + ": the new game cleared the interrupted flag of the "
		+ "previous one (`init_players()` resets it), so the suspended chain of an exited game cannot "
		+ "resume inside the new game")
	check(main.noble_family, tag + ": the game that is running is the variant")

	await _settle_menu_deal(app, NOBLE_FAMILY_4P, 0)
	check(_fam_sizes(main) == [3, 3, 3, 3], tag + ": the deal table the picker chose is the VARIANT "
		+ "one - family 3 per seat in 4p (5 / 4 / 3 for 2 / 3 / 4 players), not the classic empty one")
	check(_hand_sizes(main) == [1, 1, 1, 1], tag + ": 1 first-hand card per seat")
	check(_sum_ints(main._deck._left) == TOTAL_CARDS, tag + ": `sum(_left) == 16` at the deal (the "
		+ "family and the first-hand cards are out of the main pile, not out of play)")
	check(main._deck._widow_cards.size() == 0 and !main._deck._widow.visible, tag + ": 4p burns "
		+ "nothing, so there is NO widow pile")
	check(!main._deck._main.visible and main._deck._cards.size() == 0, tag + ": 4p leaves 0 cards in "
		+ "the main pile, so the pile is hidden")

	await _run_menu_plays(app, 6)
	var c: Dictionary = _counters(main)
	check(int(c["plays"]) >= 6, tag + ": the variant game PLAYS on its own (" + str(c["plays"])
		+ " plays)")
	check(int(c["fam_draws"]) >= 6, tag + ": every turn start drew from a FAMILY " + str(main.family_draws)
		+ " - the mandatory draw is the family, not a pile")
	check(int(c["pile_draws"]) == 0, tag + ": NO pile draw in a 4p variant game (no main pile, no widow)")
	check(int(c["pairings"]) >= 6 and int(c["mismatches"]) == 0, tag + ": every move's named family "
		+ "card is the card the same chain drew (" + str(c["pairings"]) + " pairings, 0 mismatches)")
	check(int(c["audits"]) > 0 and int(c["viols"]) == 0, tag + ": the `_left` audit ran "
		+ str(c["audits"]) + " times with 0 violations through the picker-started game")
	check(_sum_ints(main._deck._left) < TOTAL_CARDS, tag + ": cards have left play, so the supply has "
		+ "shrunk from 16 to " + str(_sum_ints(main._deck._left)))
	await _free_menu_app(app)


# ---- M3: BACK returns to the start page and starts nothing ----------------------------------
func _test_menu_back() -> void:
	var tag := "M3 BACK"
	var app = _make_menu_app()
	_menu_levels = [Player.AI_Level.Level_4, Player.AI_Level.Level_4,
		Player.AI_Level.Level_3, Player.AI_Level.Level_2]
	await _menu_ready(app)
	var main: Node = app._main
	await _tap_start_play(app)
	await _tap_row(app, "BACK")
	check(app.start_game_calls == 0 and main.init_calls == 0, tag + ": BACK started NO game and dealt "
		+ "NO cards")
	check(app.start_seams.is_empty() and main.init_seams.is_empty(), tag + ": BACK reached NEITHER seam")
	check(!app._main.noble_family, tag + ": BACK set NO mode - a refusal is not a mode choice")
	check(app._start.visible, tag + ": BACK brought the start page back")
	check(!app._game_mode.visible and _picker_targets(app) == 0, tag + ": the picker closed and "
		+ "nothing on it is tappable")
	check(!app._main.visible, tag + ": no game is shown")
	await _tap_start_play(app)
	check(app.play_presses == 2 and _picker_targets(app) == 3, tag + ": PLAY opens the picker AGAIN "
		+ "after a BACK, with all 3 rows - a menu that refuses to re-open is a dead end")
	await _free_menu_app(app)


# ---- M4: Exit-to-menu CLEARS the mode, then PLAY -> CLASSIC plays CLASSIC -------------------
func _test_menu_exit_classic() -> void:
	var tag := "M4 Exit -> CLASSIC"
	var app = _make_menu_app()
	_menu_levels = [Player.AI_Level.Level_4, Player.AI_Level.Level_4,
		Player.AI_Level.Level_3, Player.AI_Level.Level_2]
	await _menu_ready(app)
	var main: Node = app._main
	await _tap_start_play(app)
	await _tap_row(app, "NOBLE")
	await _settle_menu_deal(app, NOBLE_FAMILY_4P, 0)
	await _run_menu_plays(app, 4)
	check(main.noble_family and _sum_ints(_fam_sizes(main)) > 0, tag + ": the game in progress IS the "
		+ "variant (families exist: " + str(_fam_sizes(main)) + "), so the reset below is measurable")
	check(app.start_game_calls == 1, tag + ": exactly one game has started so far")

	main.emit_signal("menu_pressed")  # the in-game menu button's own signal
	await await_frames(1)
	check(app.get_tree().paused and !main.visible and app._pause.visible, tag + ": the in-game menu "
		+ "paused the tree, hid the game and showed the pause page")
	await _tap_pause_exit(app)
	check(!app.get_tree().paused, tag + ": Exit un-paused the tree - a tree left paused stops every "
		+ "later game, the player's and the next fixture's")
	check(app._start.visible, tag + ": Exit brought the start page back")
	check(!main.noble_family, tag + ": Exit-to-menu CLEARED the mode. The picker stores nothing (TEST "
		+ "L: zero script variables), so the application is the ONLY place a mode can be cleared, and "
		+ "the fixed rule is that a mode is chosen per game and never persists - a variant flag left "
		+ "on the Main node would make the NEXT game a variant game the player never chose")

	await _tap_start_play(app)
	check(main.init_calls == 1 and app.start_game_calls == 1, tag + ": PLAY opened the picker and "
		+ "still started nothing")
	await _tap_row(app, "CLASSIC")
	check(main.init_seams.size() == 2, tag + ": the CLASSIC row ran a second deal")
	var seam: Dictionary = main.init_seams[1]
	check(!bool(seam["noble"]), tag + ": `Main.noble_family` is FALSE AT THE DEAL - the flag is set "
		+ "before `init_players()` runs, so the deal reads the cleared value and deals classic")
	check(bool(seam["main_visible"]) and !bool(seam["picker_visible"]) and int(seam["rows_in_tree"])
		== 0, tag + ": at that deal the game is shown and the picker is closed, unpressable")
	await _settle_menu_deal(app, 0, CLASSIC_4P_MAIN)
	# The audit baseline belongs to a ROUND, and this variant game was abandoned MID-ROUND, so the new
	# classic game inherits it: `audit_left()` would compare a FRESH 16-card supply against the discards
	# of a game that no longer exists (it showed up as "Guard: _left == 5, expected 2"). `reset_audit()`
	# closes the inherited round, so the classic game is audited against ITS OWN deal.
	main.reset_audit()
	var base: Dictionary = _counters(main)
	var plays_base: int = main.effect_log.size()
	var d: Dictionary = _delta(_counters(main), base)
	check(_fam_sizes(main) == [0, 0, 0, 0], tag + ": a classic game has NO family DATA anywhere - the "
		+ "variant data model is inert in classic mode (and the human seat's stack renders from that "
		+ "data, so inert data that is never cleared is a visible ghost family)")
	check(_hand_sizes(main) == [1, 1, 1, 1], tag + ": classic deals 1 card per seat")
	check(main._deck._main.visible and main._deck._cards.size() > 0
		and main._deck._cards.size() <= CLASSIC_4P_MAIN, tag + ": classic 4p keeps the main pile "
		+ "VISIBLE and dealt - " + str(main._deck._cards.size()) + " cards in it, at most "
		+ str(CLASSIC_4P_MAIN) + " (16 - burn 1 - 4 first-hand, then one per turn's draw) - the pile "
		+ "a classic turn draws from, where the 4p VARIANT has NOTHING")
	check(main._deck._widow_cards.size() == CLASSIC_4P_WIDOW and main._deck._widow.visible, tag
		+ ": classic 4p burns 1, so the widow is a live pile (the 4p VARIANT has no widow at all) - "
		+ str(main._deck._widow_cards.size()) + " cards, visible " + str(main._deck._widow.visible))
	await _run_menu_plays(app, plays_base + 6)
	d = _delta(_counters(main), base)
	check(int(d["plays"]) >= 6, tag + ": the classic game played " + str(d["plays"]) + " more cards")
	check(int(d["fam_draws"]) == 0, tag + ": and NO family draw in a classic game (delta from the "
		+ "classic deal: " + str(d["fam_draws"]) + ")")
	check(int(d["pile_draws"]) >= 4, tag + ": its draws came from the PILE (" + str(d["pile_draws"])
		+ " pile draws), exactly as before step 25")
	var vlist: Array = main.left_violations
	var first_violation := ""
	if not vlist.is_empty():
		first_violation = "; first: " + str(vlist[0])
	check(int(d["viols"]) == 0, tag + ": 0 `_left` violations in the classic game (" + str(d["audits"])
		+ " audits" + first_violation + ")")
	await _free_menu_app(app)


# ---- M5: `speed_run` bypasses the menu and stays classic-only ------------------------------
func _test_menu_speed_run() -> void:
	var tag := "M5 speed_run"
	var app = _make_menu_app(true)
	_menu_levels = [Player.AI_Level.Level_1, Player.AI_Level.Level_2,
		Player.AI_Level.Level_3, Player.AI_Level.Level_4]
	await _menu_ready(app)
	var main: Node = app._main
	check(app.play_presses == 0 and app.start_game_calls == 0, tag + ": the speed run never pressed "
		+ "PLAY and never called `start_game()` - it boots straight into `init_players(42)`, so the "
		+ "menu cannot be a speed-run dependency")
	check(main.init_calls == 1, tag + ": it dealt exactly one game, from `_ready()`")
	check(!app._game_mode.visible, tag + ": the picker never opened")
	check(!app._main.noble_family, tag + ": the speed run is CLASSIC-only (todo §C: `speed_run` stays "
		+ "classic-only - the classic suites gate on this run)")
	await _settle_menu_deal(app, 0, CLASSIC_4P_MAIN)
	check(_fam_sizes(main) == [0, 0, 0, 0], tag + ": no families in a speed run")
	check(main._deck._main.visible, tag + ": the main pile is in play (the classic supply)")
	await _run_menu_plays(app, 6)
	var c: Dictionary = _counters(main)
	check(int(c["plays"]) >= 6, tag + ": the speed run played " + str(c["plays"]) + " cards")
	check(int(c["fam_draws"]) == 0 and int(c["pile_draws"]) > 0, tag + ": and it drew from piles only ("
		+ str(c["pile_draws"]) + " pile draws, 0 family draws)")
	await _free_menu_app(app)

# ----------------------------------------------------------------------------------------
# TEST N (todo step 26): the STATS tables, ONE PER MODE (index 0 = CLASSIC, 1 = NOBLE FAMILY).
#
# The step 26 gate is "two independent tables exist", and independence is a DATA property, so most
# of this fixture needs no game: a Stats panel is instantiated and its data is written through the
# THREE paths the game writes it (the legacy `_totals_and_wins` alias, the `table()` accessor, and a
# whole-array assignment of a save loaded from `options.cfg`) and read through the two the player
# sees (`update_labels()` and the Reset button). One fixture DOES run the real application, because
# "classic mode is untouched" is a claim about the WRITE path: a classic game's counters must land in
# the CLASSIC table, exactly once per emitted signal, with the NOBLE table staying all zero.
#
# N1  shape: 2 tables of 14 counters (2 per `AI_Level` KEY - the enum has 7 keys, `Disabled` included,
#     `Array[int]` (the outer array is untyped: Godot 4.7 rejects `Array[Array[int]]`), no shared
#     reference between the tables, `table()` a WINDOW on `tables[mode]` and not a copy, 6 label rows x
#     2 counters = 12 of the 14 = every counter a game can write is reachable on screen.
# N2  independence: writing one mode never touches the other table, in either direction, and a mode
#     switch never clears, never overwrites, never re-sorts what each table holds.
# N3  the alias contract, replaying `application.gd`'s statements VERBATIM (that file is UNCHANGED by
#     step 26, so its shapes are the contract): per-level `+1` writes, `= config.get_value(...)`
#     arriving as an UNTYPED Array that must land as `Array[int]` (an untyped element makes `table()`
#     raise "Trying to return a value of type Array ... Array[int]"), the LENGTH preserved (the
#     application drops a stale save BY ITS SIZE, so a setter that padded it would silently accept
#     stale stats), and the empty-array default of a missing key.
# N4  reset: only the VISIBLE table is zeroed - the other mode's history survives it - and the reset
#     does not change the mode, does not close the page and does refresh the labels.
# N5  labels: `update_labels()` reads the CURRENT table; the format, the H12345 letters and the
#     (totals, wins) pair order are unchanged from the pre-variant page.
# N6  the classic write path on the REAL application: the legacy save lands in the classic table, a
#     classic game writes ONLY that table, and the writes are exactly the emitted signals (no double
#     write, no lost write).
# ----------------------------------------------------------------------------------------
const STATS_COUNT: int = 14  # MEASURED == 2 * Player.AI_Level.size(): `AI_Level` has 7 KEYS
const STATS_OPTIONS: String = "user://options.cfg"

var _st_won: Array[int] = []
var _st_fin: Array[int] = []


func _test_stats_tables() -> void:
	print("\n########## TEST N: the per-mode stats tables (step 26) - 2 tables x 14 counters, ##########")
	print("########## classic = index 0 = the default, the legacy alias writes the CURRENT table, ##########")
	print("########## reset clears ONLY the visible table, labels read it, and the APP names the mode ##########")
	await _test_st_shape()
	await _test_st_independence()
	await _test_st_alias()
	await _test_st_reset()
	await _test_st_labels()
	await _test_st_classic_writes()
	await _test_st_app_mode()


func _st_panel():
	# `load()` at runtime, NOT a top-level `preload()`: a preloaded PackedScene is a static reference
	# that is "still in use at exit" (the scene, its script, its LabelSettings, its button scene), and
	# Godot exits 1 for a suite that leaks. This suite's own harness rule, step 11.
	var panel = load("res://stats/stats.tscn").instantiate()
	add_child(panel)  # `update_labels()` reads `@onready` labels, so a panel must be in the tree
	await await_frames(1)
	return panel


func _st_free(panel) -> void:
	panel.queue_free()
	await await_frames(2)


func _st_row(tab) -> Array:
	var out: Array = []
	for v in tab:
		out.append(int(v))
	return out


func _st_tables(panel) -> Array:
	var out: Array = []
	for tab in panel.tables:
		out.append(_st_row(tab))
	return out


func _st_zeros(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(0)
	return out


# A recognizable per-mode pattern (base 100 = classic, 200 = noble), written through the raw table
func _st_fill(panel, mode: int, base: int) -> void:
	var tab = panel.tables[mode]
	for i in tab.size():
		tab[i] = base + i


func _st_zero(tab) -> bool:
	for v in tab:
		if int(v) != 0:
			return false
	return true


func _st_labels(panel) -> Array:
	var out: Array = []
	for lbl in panel._levels:
		out.append((lbl as Label).text)
	return out


# The PRE-variant label format, recomputed here so a silent format change (swapped columns, a
# different label order) shows up as a FAIL instead of a page that just "looks fine"
func _st_expect(t: Array) -> Array:
	var out: Array = []
	for i in Stats.LABELS.length():  # 6 label rows = 12 of the 14 slots (see the N1 note)
		out.append("%5d  %s  %-5d" % [int(t[2 * i]), Stats.LABELS[i], int(t[2 * i + 1])])
	return out


func _st_saved() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(STATS_OPTIONS) != OK:
		return []
	var v = cfg.get_value("Gameplay", "totals_and_wins", [])
	return _st_row(v)


func _st_note_won(level) -> void:
	_st_won.append(int(level))


func _st_note_finished(level) -> void:
	_st_fin.append(int(level))


func _run_menu_rounds(app, wanted: int) -> void:
	for _f in 40000:
		if _st_won.size() >= wanted:
			return
		await get_tree().process_frame


# ---- N1: the shape of the two tables ---------------------------------------------------------
func _test_st_shape() -> void:
	var tag := "N1 shape"
	var panel = await _st_panel()
	check(panel.tables.size() == Stats.MODE_COUNT, tag + ": the page holds EXACTLY "
		+ str(Stats.MODE_COUNT) + " counter tables (measured " + str(panel.tables.size())
		+ ") - 1 table would mix two modes into one history, 3 tables would be a mode the game has")
	check(Stats.MODE_CLASSIC == 0 and Stats.MODE_NOBLE == 1, tag + ": index 0 is CLASSIC and index 1"
		+ " is NOBLE FAMILY - the fixed indexing, so `Main.noble_family` maps onto it as a 0/1")
	check(panel.mode == Stats.MODE_CLASSIC, tag + ": a FRESH page reads the CLASSIC table - the mode is"
		+ " chosen per game and never persisted, so a page must not open on a mode nobody played")
	var snaps: Array = _st_tables(panel)
	var typed: Array = []
	for tab in panel.tables:
		typed.append(tab is Array[int])
	check(2 * Player.AI_Level.size() == STATS_COUNT, tag + ": the counters-per-table formula is"
		+ " `2 * Player.AI_Level.size()` == " + str(2 * Player.AI_Level.size()) + " - the SAME formula"
		+ " `application.gd`'s stale-size drop uses, so the length the game writes and the length the"
		+ " loader accepts are one number (`Player.AI_Level.keys()` has 7 entries: `Disabled` plus"
		+ " Human plus Levels 1-5; a `const` cannot call `.size()`, so the fixture spells the number out")
	check(snaps[0].size() == STATS_COUNT and snaps[1].size() == STATS_COUNT, tag + ": "
		+ str(STATS_COUNT) + " counters per table (measured " + str(snaps[0].size()) + " / "
		+ str(snaps[1].size()) + ") = totals + wins for every `AI_Level` KEY - 7 keys, `Disabled`"
		+ " included, so the last 2 slots belong to a level that can never score; the page shows 12 of"
		+ " them (H12345) and `_on_round_won` writes `2 * ai_level` with `ai_level` in 0..5 = 0..11")
	check(typed == [true, true], tag + ": every table is a REAL `Array[int]` (measured " + str(typed)
		+ ") - the OUTER array is untyped because Godot 4.7 rejects `Array[Array[int]]` (nested typed"
		+ " collections), the same shape `Deck.prepare_noble()` returns")
	check(_st_zero(snaps[0]) and _st_zero(snaps[1]), tag + ": both tables start empty of history "
		+ "(" + str(snaps[0]) + " / " + str(snaps[1]) + ") - a table that inherits numbers is a save "
		+ "leaking into the mode the player is about to choose")
	check(not is_same(panel.tables[0], panel.tables[1]), tag + ": the two tables are DIFFERENT arrays "
		+ "- a shared reference shows one mode's counters in the other (the step-17 reference trap)")
	check(is_same(panel.table(), panel.tables[panel.mode]), tag + ": `table()` is a WINDOW on the "
		+ "current table, not a copy - a writer that mutates `table()` lands in `tables[mode]`")
	check(Stats.LABELS.length() == 6 and STATS_COUNT == 2 * Player.AI_Level.size(), tag + ": 6 label"
		+ " rows (H12345) x 2 counters = 12 of the " + str(STATS_COUNT) + " slots, so every counter a"
		+ " game can WRITE is reachable on screen and the 2 `Disabled` slots are inert padding - a"
		+ " COUNTERS-per-table change must move the label rows and the save format together")
	var labels := 0
	var buttons := 0
	for ch in panel.get_children():
		if ch is Label:
			labels += 1
		if ch is BaseButton:
			buttons += 1
	check(labels == 6 and buttons == 2, tag + ": the page is 6 Labels + Back + Reset = "
		+ str(panel.get_child_count()) + " children - the step-27 mode switch ADDS nodes to this page,"
		+ " so the baseline is written down before it does")
	await _st_free(panel)


# ---- N2: two tables, and writing one cannot touch the other ----------------------------------
func _test_st_independence() -> void:
	var tag := "N2 two tables"
	var panel = await _st_panel()
	_st_fill(panel, Stats.MODE_CLASSIC, 100)
	var classic: Array = _st_row(panel.tables[Stats.MODE_CLASSIC])
	check(_st_row(panel.tables[Stats.MODE_NOBLE]) == _st_zeros(STATS_COUNT), tag + ": a full classic"
		+ " write leaves the NOBLE table at zeros - two histories, not one mixed history")
	panel.mode = Stats.MODE_NOBLE
	check(is_same(panel.table(), panel.tables[Stats.MODE_NOBLE]), tag + ": `mode` switches the WINDOW,"
		+ " so `table()` (and the alias) now name the NOBLE table")
	check(_st_row(panel.table()) == _st_zeros(STATS_COUNT), tag + ": the mode switch revealed an EMPTY"
		+ " noble table - switching modes never copies, pads or seeds a table")
	var t: Array[int] = panel.table()  # the typed accessor is a reference, so this write is a real write
	for i in t.size():
		t[i] = 200 + i
	var noble: Array = _st_row(panel.tables[Stats.MODE_NOBLE])
	check(_st_row(panel.tables[Stats.MODE_CLASSIC]) == classic, tag + ": the noble write left the"
		+ " CLASSIC table byte-identical (" + str(classic) + ")")
	panel.mode = Stats.MODE_CLASSIC
	check(_st_row(panel.table()) == classic, tag + ": back to classic, the classic numbers are intact"
		+ " - a mode switch never clears the table it leaves")
	panel.mode = Stats.MODE_NOBLE
	check(_st_row(panel.table()) == noble, tag + ": and the noble numbers are intact too (" + str(noble)
		+ ") - the two tables hold TWO histories at once, which is the whole point of step 26")
	await _st_free(panel)


# ---- N3: the legacy alias is `application.gd`'s contract, statement for statement -----------
func _test_st_alias() -> void:
	var tag := "N3 the legacy alias"
	var panel = await _st_panel()
	check(is_same(panel._totals_and_wins, panel.tables[panel.mode]), tag + ": `_totals_and_wins` IS the"
		+ " current table (the same array, not a copy) - `application.gd` is unchanged by step 26, so"
		+ " its `alias[i] = clampi(alias[i] + 1, ...)` must mutate the table in place")
	for level in Stats.LABELS.length():  # `_on_round_won` / `_on_round_finished`, verbatim shapes
		panel._totals_and_wins[2 * level] = clampi(panel._totals_and_wins[2 * level] + 1, 0, 99999)
		panel._totals_and_wins[2 * level + 1] = clampi(panel._totals_and_wins[2 * level + 1] + 3,
			0, 99999)
	var want: Array = _st_zeros(STATS_COUNT)  # the 2 `Disabled` slots stay 0: no AI level writes them
	for level in Stats.LABELS.length():
		want[2 * level] = 1
		want[2 * level + 1] = 3
	check(_st_row(panel.tables[panel.mode]) == want, tag + ": the per-level writes landed in the"
		+ " classic table as " + str(_st_row(panel.tables[panel.mode])) + " - totals at the even slots,"
		+ " wins at the odd ones, 12 slots written for 6 levels and the 2 `Disabled` slots untouched")
	check(_st_zero(panel.tables[Stats.MODE_NOBLE]), tag + ": and the NOBLE table is still zeros - the"
		+ " alias reaches the CURRENT mode, never both")
	var save: Array = []  # `config.get_value` hands back a PLAIN Array, so this is the load shape
	for i in STATS_COUNT:
		save.append(i + 1)
	panel._totals_and_wins = save
	var loaded: Array = _st_row(panel.tables[panel.mode])
	check(loaded == save, tag + ": a WHOLE-ARRAY assignment of a loaded 12-counter save lands in the"
		+ " CURRENT table elementwise (" + str(loaded) + ") - `load_config()` assigns the whole array, it"
		+ " never merges it into what the table already holds")
	check(panel.tables[panel.mode] is Array[int], tag + ": the setter NORMALIZES a loaded save to"
		+ " `Array[int]` - an untyped table would make `table()` raise a return-type error on the very"
		+ " next label update, and `--check-only` cannot see a runtime type error")
	var t_now := 0
	t_now = panel.table().size()  # the call itself is the check: a type error here is a SCRIPT ERROR
	check(t_now == STATS_COUNT, tag + ": `table()` reads the loaded save (" + str(t_now) + " counters)")
	check(_st_zero(panel.tables[Stats.MODE_NOBLE]), tag + ": a save assigned at classic mode lands in"
		+ " the CLASSIC table only - the load path cannot write a mode the player is not playing")
	panel._totals_and_wins[0] = 555
	check(int(panel.tables[panel.mode][0]) == 555, tag + ": the array the setter stored is a LIVE"
		+ " reference, not a snapshot - the counters keep accumulating after a save was loaded")
	panel._totals_and_wins = [1, 2, 3, 4, 5, 6]
	check(panel._totals_and_wins.size() == 6 and panel.tables[panel.mode].size() == 6, tag
		+ ": a STALE 6-counter save KEEPS its length (" + str(panel._totals_and_wins.size())
		+ ") - the setter must not pad it, because `application.gd` drops a stale save by EXACTLY that"
		+ " size check; padding would silently accept it")
	panel._totals_and_wins = []
	check(panel._totals_and_wins.size() == 0, tag + ": the missing-key default (`get_value(..., [])`)")
	panel._totals_and_wins = save
	panel.mode = Stats.MODE_NOBLE
	panel._totals_and_wins = [7, 7, 7, 7]
	check(_st_row(panel.tables[Stats.MODE_NOBLE]) == [7, 7, 7, 7], tag + ": at NOBLE mode the same"
		+ " assignment writes the NOBLE table - the alias follows the mode, in both modes")
	check(_st_row(panel.tables[Stats.MODE_CLASSIC]) == save, tag + ": and the classic table is"
		+ " untouched by it (" + str(_st_row(panel.tables[Stats.MODE_CLASSIC])) + ")")
	await _st_free(panel)


# ---- N4: Reset clears ONLY the table the player is looking at --------------------------------
func _test_st_reset() -> void:
	var tag := "N4 reset"
	var panel = await _st_panel()
	_st_fill(panel, Stats.MODE_CLASSIC, 100)
	_st_fill(panel, Stats.MODE_NOBLE, 200)
	var classic: Array = _st_row(panel.tables[Stats.MODE_CLASSIC])
	panel.mode = Stats.MODE_NOBLE
	panel.update_labels()
	var reset: BaseButton = panel.get_node("ResetButton") as BaseButton
	check(reset != null, tag + ": the page has a ResetButton the player can press")
	reset.emit_signal("pressed")  # the scene's OWN connection to `_on_reset_button_pressed`
	await await_frames(1)
	check(_st_row(panel.tables[Stats.MODE_NOBLE]) == _st_zeros(STATS_COUNT), tag + ": pressing Reset"
		+ " zeroed the VISIBLE (noble) table")
	check(_st_row(panel.tables[Stats.MODE_CLASSIC]) == classic, tag + ": and the CLASSIC table kept its"
		+ " whole history (" + str(classic) + ") - a variant reset must not delete a year of classic"
		+ " games, and it is the only way a player can undo a variant reset by accident")
	check(panel.mode == Stats.MODE_NOBLE, tag + ": Reset did not change the mode (the page shows the"
		+ " same mode it showed before, after a reset)")
	check(_st_labels(panel) == _st_expect(_st_zeros(STATS_COUNT)), tag + ": the labels refreshed to the"
		+ " zeros the player reset - the page is a view of the table, not of a snapshot")
	check((panel as CanvasItem).visible, tag + ": Reset keeps the page open (a reset that closes the"
		+ " page hides the result of the player's own action)")
	panel.mode = Stats.MODE_CLASSIC
	panel.update_labels()
	check(_st_labels(panel) == _st_expect(classic), tag + ": switching back shows the classic numbers"
		+ " the reset did not touch")
	await _st_free(panel)


# ---- N5: the labels read the CURRENT table ----------------------------------------------------
func _test_st_labels() -> void:
	var tag := "N5 labels"
	var panel = await _st_panel()
	_st_fill(panel, Stats.MODE_CLASSIC, 100)
	_st_fill(panel, Stats.MODE_NOBLE, 500)
	panel.update_labels()
	check(_st_labels(panel) == _st_expect(_st_row(panel.tables[Stats.MODE_CLASSIC])), tag
		+ ": at classic mode the 6 rows are the CLASSIC table, in the pre-variant format and pair"
		+ " order (measured " + str(_st_labels(panel)[0]) + ")")
	panel.mode = Stats.MODE_NOBLE
	panel.update_labels()
	var noble_texts: Array = _st_labels(panel)
	check(noble_texts == _st_expect(_st_row(panel.tables[Stats.MODE_NOBLE])), tag + ": at noble mode"
		+ " the SAME 6 rows are the NOBLE table (" + str(noble_texts[0]) + ") - `update_labels()` reads"
		+ " `table()`, so the page follows the mode")
	check(noble_texts != _st_expect(_st_row(panel.tables[Stats.MODE_CLASSIC])), tag + ": the two modes"
		+ " are measurably DIFFERENT pages - identical labels would mean one table is being shown twice")
	var letters: Array = []
	for txt in noble_texts:
		letters.append(str(txt).substr(7, 1))
	check(letters == ["H", "1", "2", "3", "4", "5"], tag + ": the rows are H,1,2,3,4,5 top to bottom"
		+ " (" + str(letters) + ") - the level a counter belongs to is readable, not positional")
	await _st_free(panel)


# ---- N6: the classic WRITE path, on the real application --------------------------------------
func _test_st_classic_writes() -> void:
	var tag := "N6 classic writes"
	var app = _make_menu_app()
	_menu_levels = [Player.AI_Level.Level_4, Player.AI_Level.Level_4,
		Player.AI_Level.Level_3, Player.AI_Level.Level_2]
	await _menu_ready(app)
	var stats = app._stats
	var main: Node = app._main
	var saved: Array = _st_saved()
	var live: Array = _st_row(stats.tables[Stats.MODE_CLASSIC])
	if saved.size() == 2 * Player.AI_Level.size():
		check(live == saved, tag + ": a save whose length matches `load_config()`'s OWN size formula"
			+ " is KEPT and lands in the CLASSIC table (" + str(live) + ") - an old-format save is the"
			+ " classic history, never a mystery mode")
	else:
		check(_st_zero(live), tag + ": a " + str(saved.size()) + "-counter save is DROPPED by"
			+ " `load_config()`'s EXISTING size check (`2 * AI_Level.size()` == "
			+ str(2 * Player.AI_Level.size()) + "), so the classic table opens at zeros - PRE-EXISTING"
			+ " behaviour, step 26 changes no save format and no drop rule. The first save the game"
			+ " writes back is " + str(STATS_COUNT) + " long, so the NEXT boot keeps it; step 28's"
			+ " migration Check (an old-format save must migrate to the classic table) is the step that"
			+ " must decide the 12-to-" + str(STATS_COUNT) + " rule, and THIS check is the one that flips"
			+ " when it does")
	check(stats.tables[Stats.MODE_CLASSIC] is Array[int], tag + ": the loaded save is NORMALIZED to"
		+ " `Array[int]` by the alias setter - the file holds a plain array, so the normalization is"
		+ " what keeps `table()` readable on the load path")
	check(stats.tables[Stats.MODE_NOBLE] is Array[int] and _st_zero(stats.tables[Stats.MODE_NOBLE]),
		tag + ": the NOBLE table starts at zeros (no save key for it yet - step 28 adds"
		+ " `Stats/noble_family`)")
	check(stats.mode == Stats.MODE_CLASSIC, tag + ": a classic game opens on the CLASSIC table")

	_st_won = []
	_st_fin = []
	main.round_won.connect(_st_note_won)  # the counters are COUNTED ON SIGNALS, the harness rule
	main.round_finished.connect(_st_note_finished)
	await _tap_start_play(app)
	await _tap_row(app, "CLASSIC")
	var base: Array = _st_row(stats.tables[Stats.MODE_CLASSIC])
	await _settle_menu_deal(app, 0, CLASSIC_4P_MAIN)
	await _run_menu_rounds(app, 2)
	# The save is written by `save_stats.emit()` at the TAIL of `round_over()` (after every
	# `round_won`), and the game keeps playing after the 2nd round, so the file is a LAGGING snapshot of
	# the table. The check is convergence: poll until "what the file says" == "what the page shows".
	var matched := false
	var now: Array = _st_row(stats.tables[Stats.MODE_CLASSIC])
	for _f in 600:
		now = _st_row(stats.tables[Stats.MODE_CLASSIC])
		if _st_saved() == now:
			matched = true
			break
		await get_tree().process_frame
	var d: Array = []
	for i in STATS_COUNT:
		d.append(int(now[i]) - int(base[i]))
	var totals := 0
	var wins := 0
	for i in Stats.LABELS.length():
		totals += int(d[2 * i])
		wins += int(d[2 * i + 1])
	check(_st_won.size() >= 2, tag + ": the classic game finished " + str(_st_won.size())
		+ " rounds, so the counters are measurable")
	check(totals == _st_won.size(), tag + ": the TOTALS grew by exactly the number of `round_won`"
		+ " emissions (" + str(totals) + " counters for " + str(_st_won.size()) + " rounds) - every"
		+ " winner is credited ONCE, and a mode index written twice would double here")
	check(wins == _st_fin.size(), tag + ": the WINS grew by exactly the number of `round_finished`"
		+ " emissions (" + str(wins) + " for " + str(_st_fin.size()) + ")")
	check(_st_zero(stats.tables[Stats.MODE_NOBLE]), tag + ": a CLASSIC game wrote NOTHING to the noble"
		+ " table - the write path is mode-scoped, so a variant table cannot collect classic games")
	check(int(now[0]) >= int(base[0]) and int(now[1]) >= int(base[1]), tag + ": a classic game ADDS to"
		+ " the saved classic history, it never replaces it (" + str(base) + " -> " + str(now[0])
		+ " on the first slot)")
	check(matched, tag + ": the save the game wrote back EQUALS the table the page shows (" + str(now)
		+ ") - `save_config()` writes the CURRENT table under the legacy key; step 28 splits that key"
		+ " per mode. Measured lag: the file is written at the TAIL of `round_over()`, so a snapshot"
		+ " taken right after a `round_won` is one round behind the in-memory table")
	check(_st_saved().size() == STATS_COUNT, tag + ": the save the game wrote back is " + str(STATS_COUNT)
		+ " counters long - the length `load_config()`'s own size check expects, so the format the game"
		+ " writes and the rule that drops a save agree with each other (a 12-counter legacy save does"
		+ " NOT, which is the drop measured above; step 28 owns that gap)")
	main.round_won.disconnect(_st_note_won)
	main.round_finished.disconnect(_st_note_finished)
	await _free_menu_app(app)


# ---- N7: the APP is the only place a mode exists, so the page has to follow it ----------------
# `application.gd` is the file that owns a mode (step 25: the picker writes `Main.noble_family`, the
# stats page stores nothing), and step 26 gives the page one table per mode. This fixture pins the
# THREE places the app names a mode, on a real app - start a game, open the page from the pause menu,
# leave the game and open it from the start page.
func _test_st_app_mode() -> void:
	var tag := "N7 the app follows the mode"
	var app = _make_menu_app()
	_menu_levels = [Player.AI_Level.Level_2, Player.AI_Level.Level_3,
		Player.AI_Level.Level_2, Player.AI_Level.Level_3]
	await _menu_ready(app)
	var stats = app._stats
	var main: Node = app._main
	check(stats.mode == Stats.MODE_CLASSIC, tag + ": a fresh app's page reads the CLASSIC table - the"
		+ " mode is per game, and a game that has not started has none")
	var classic_before: Array = _st_row(stats.tables[Stats.MODE_CLASSIC])
	await _tap_start_play(app)
	await _tap_row(app, "NOBLE")
	# TEST M's settle, NOT a fixed number of frames: freeing an app whose DEAL is still animating leaves
	# the Animator's lambdas pointing at freed cards (`Invalid assignment of property 'faceup' ... on a
	# base object of type 'Nil` at animator.gd:48/51, 6 of them). Measured on the first N7 run.
	await _settle_menu_deal(app, NOBLE_FAMILY_4P, 0)
	check(main.noble_family, tag + ": the NOBLE row started a variant game")
	check(stats.mode == Stats.MODE_NOBLE, tag + ": and the page switched to the NOBLE table -"
		+ " `start_game()` is the ONE line where a mode exists, and `application.gd`'s two write paths"
		+ " (`_on_round_won`, `_on_round_finished`) never name a mode, so a variant game's counters can"
		+ " only land in the noble table")
	check(is_same(stats._totals_and_wins, stats.tables[Stats.MODE_NOBLE]), tag + ": the alias follows"
		+ " the mode - the per-level writes of a running variant game mutate the NOBLE table in place")
	check(_st_row(stats.tables[Stats.MODE_CLASSIC]) == classic_before, tag + ": a variant game IN"
		+ " PROGRESS writes no classic counter at all - the classic table is not its target, which is"
		+ " the requirement in one line (" + str(classic_before) + " -> "
		+ str(_st_row(stats.tables[Stats.MODE_CLASSIC])) + "; a counter moves at a ROUND END, and the"
		+ " noble table a settled variant deal sits on is at zeros too)")
	app._on_pause_stats_pressed()  # the pause page belongs to the game that is running
	check(stats.mode == Stats.MODE_NOBLE, tag + ": opened from the PAUSE menu in a variant game, the page"
		+ " shows the NOBLE table - the counters a player checks mid-game are the game's own")
	app._on_stats_back_pressed()
	await _tap_pause_exit(app)
	check(not main.noble_family, tag + ": EXIT cleared the mode - step 25's rule, the mode is per game"
		+ " and never persisted, so the next PLAY must choose it again")
	app._on_start_stats_pressed()
	check(stats.mode == Stats.MODE_CLASSIC, tag + ": opened from the START page, the page shows the"
		+ " CLASSIC table - no game is running, so what a player opens is the history the classic game"
		+ " wrote, not the mode of the game that just ended")
	check(_st_labels(stats) == _st_expect(stats.table()), tag + ": the page that opens renders the 6 rows"
		+ " OF THE TABLE IT SHOWS (" + str(_st_labels(stats)) + ") - the labels are the table's view, in"
		+ " both modes, in the pre-variant format")
	await _free_menu_app(app)
