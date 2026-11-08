extends Main
# Test-only `Main` subclass (same technique as tests/fake_deck.gd: installed with `set_script`,
# no production file is touched). It records the events a harness cannot see by polling:
# eliminations (`set_inactive`), round ends (`round_over`, with the seat that was to act) and
# family draws (`deal_from_family`, per seat).
#
# Why polling fails: at `Animator._speed = 0` the whole chain
# "family draw -> play -> effect -> next turn" - and even "eliminate -> round_over -> label ->
# _new_round -> active = true" - can resolve inside a single frame, so hand sizes, `Player.active`
# and the round-over label all look unchanged between two samples, and events are dropped.

var eliminations: int = 0
var eliminated_seats: Array[int] = []
var round_end_actor: Array[int] = []
var family_draws: Array[int] = [0, 0, 0, 0]  # per seat, cumulative


func set_inactive(p: Player, reveal_hand: bool = true) -> void:
	eliminations += 1
	eliminated_seats.append(p.idx)
	# must await: every caller in main.gd does `await set_inactive(...)`, and calling a coroutine
	# without await would let the game run on past the elimination
	await super(p, reveal_hand)


func round_over() -> void:
	# new_turn() / resolve_effect() call this without awaiting it, so a plain super() call keeps
	# the production flow exactly as it is
	round_end_actor.append(_cur_player)
	super()


func deal_from_family(p: Player, family_idx: int) -> void:
	family_draws[p.idx] += 1
	await super(p, family_idx)
