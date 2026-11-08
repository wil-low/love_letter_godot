Repro: level 4 AI declares "Princess" while holding the Princess
================================================================

Run:

    godot --headless --path . tests/repro_guard_princess.tscn
    echo $?      # 0 = all checks passed, 1 = a check failed

Files
-----
- `repro_guard_princess.tscn` / `repro_guard_princess.gd` - the test (2 scenarios + a full round)
- `fake_deck.gd` - `extends Deck`, deals a scripted card order; installed at runtime with
  `node.set_script(...)`, so no production file is touched

Result: **all checks pass** with the fix applied - the behaviour is reproducible, and it was
*not* a stale memory.

The fix applied (`player.gd`, Guard branch of `eval_moves`):

    -                if mem != Deck.CardType.Unknown:
    +                # Guard is not a guessable type (find_valid_moves guesses Priest..Princess),
    +                # so a Guard memory can never be matched - fall through to the card-count heuristic
    +                if mem != Deck.CardType.Unknown and mem != Deck.CardType.Guard:

The assertions below describe the post-fix expectations; the buggy behaviour is documented
by the printed score tables ("the last generated move is still the Princess guess").

Test B - the exact sequence reported
------------------------------------
Scripted deck order, 2 players (P0 = our player, P1 = the rival):

| step | event | P0 hand | P1 hand | P0's memory of P1 |
|---|---|---|---|---|
| opening | deal | Priest | Princess | Unknown |
| 2 | P0 draws Guard, plays Priest on P1 | Guard | Princess | **Princess** (true) |
| 3 | P1 draws King, plays it on P0 | **Princess** | **Guard** | **Guard** (true) |
| 4 | P0 draws Guard, level 4 decides | Princess + Guard | Guard | Guard |

The King branch in `main.gd` rewrites the belief
(`tp.update_memory(p.idx, their_card.type)`), so at step 4 the memory is *correct*:
P1 really holds a Guard. And P0's own Princess is the unique one in the deck
(`card_count[Princess] == 1`), so no rival can hold a Princess.

Why the AI then announces "Princess"
------------------------------------
1. `player.gd`, Guard branch: `m._score = EvalScore.GOOD * m._target_type`.
   The correct guess has `_target_type == Guard == 0` -> **score 0**; every other guess
   contradicts the memory -> also 0. Measured in the test: `sum of all move scores = 0`.
   Same defect hits Baron / Prince / King moves: they are built with
   `Move.new(card, idx, target)` -> `_target_type = Unknown = 0` -> `GOOD * 0 = 0`,
   so a winning Baron and a Princess-killing Prince can never score above LOSE.
2. `select_move()` fallback when every score is 0:
   `if sum == 0: sum = 1` -> `rmove = 0` -> the accumulation loop never satisfies
   `sum > rmove` -> `return valid_moves[-1]`.
3. `main.gd find_valid_moves()` generates the Guard guesses in enum order
   `Priest .. Princess`, so the **last** generated move is the Princess guess.

=> zero-score fallback + move ordering = "declare Princess", deterministically.

With the Guard check in place, the same turn scores `Princess = 0`
(`left_cards[Princess]` minus the copy in hand) and `sum = 40`, so the weighted random
picks one of Priest / Baron / Handmaid / Prince / Countess - the Princess declaration is
gone. Measured in Test B: `AI plays: Guard, tgt 1, Prince`, rival survives.

Test A isolates the decision (no deck, no animations):
- memory of rival = Guard -> all 7 guesses score 0 -> the last one (Princess) is picked;
- memory of rival = Princess -> that guess scores `50 * 7 = 350`, the highest score in the
  game, and is picked. So a genuinely *stale* Princess belief is played greedily too - and
  the deck-count branch that would have zeroed it (`left_cards[Princess]` minus the cards
  in hand) is skipped as soon as the memory slot is known.

Outcome of the reproduced turn: P0 plays Guard, declares Princess, the rival (Guard)
survives, and P0 keeps its Princess - a wasted, guaranteed-failed guess.

Measurement: the Guard card-count heuristic (`tests/left_cards_sim.py`)
------------------------------------------------------------------------

Supports section 5 of `ai_memory_open_issues.md`. Pure Python, no Godot: it replicates the
deck of `deck/deck.gd` (counts `[5,2,2,2,2,1,1,1]`, widow 1 card for 3-4 players / 3 for a
2-player game), draws random legal states for a given discard count, and compares the
Guard guess that `EvalScore.BAD * left_cards[t]` (`player.gd:232-237`) produces against
alternative estimators:

    python3 tests/left_cards_sim.py            # 200k deals per row
    python3 tests/left_cards_sim.py 50000      # faster, noisier

Columns: `hit` = the guess matches the target's real card; `zero` = the guessed type is in
no hand at all (a certain miss); `avg` = mean score of the chosen move (`5 * left`).

Conclusions recorded in section 5:

- `raw` (the shipped heuristic) sits at the exact Bayes posterior in a fresh round: measured
  0.3132 against the theoretical ceiling `(5 - 2*5/16)/14 = 0.3125`, because
  `P(target holds t) = _left[t] / sum(_left)` - the widow belongs in the denominator;
- `widow_sub` (the rejected "decrement `_left` for widow cards" fix) only differs by using
  `_widow_cards`, i.e. hidden information: +0.1% in a fresh round, +4pp at 10 discards in a
  3-4 player game, and 0.401 -> **1.000** for the last guess of a 2-player round at 10
  discards (one card is left unaccounted for, so the rival's hand is solved);
- `pinned_sub` (subtract the copies the AI has pinned with a Priest) is the legitimate gap,
  and it is the guardrail used by the section 1 fix: in the last third of a round the
  current code spends ~40% of its Guard guesses on a type it knows is in a known hand.

## tests/repro_prince_memory.tscn — ai_memory_open_issues.md issue 4 (regression suite)

The rule the fix in `main.gd` implements:

> **a memory slot `[i][j]` names player `j`'s *hand card*, so a belief must be cleared (or
> moved) exactly when that card leaves `j`'s hand - using only what is on the table**

Test D is the boundary of that rule: a play is visible as a *card*, not as a *slot*, so a
type-matching play clears the belief about the playing player even when the player kept the
believed copy (90.5% of such plays really do kill the belief). Keying the clear on the played
card's index would preserve the remaining 9.5% by giving every seat the contents of a
player's hand.

Tests **A-D** assert the fixed behaviour in the production engine; **E** measures what the
two older rules cost. Four seats are driven by hand (levels flipped to Human after
`init_players`) with a scripted deck, so every assertion is deterministic. Nothing is
patched - the suite runs the production scripts, and the two older rules are re-applied by
hand (from a pre-Prince snapshot) only in test E.

- **A** seat 0 learns "seat 1 holds a Handmaid" from a Baron tie, seat 2 then plays a
  Prince on seat 1 (the Handmaid leaves the game, seat 1 draws a fresh card).
  `main.gd:346-348` used to keep that belief, and at seat 0's level 4 decision the deck has
  one Handmaid left and it is in seat 0's own hand, so the call is provably impossible.
  Now: the Prince clears the belief about its target, the memory branch pays nothing, the
  call scores 0 via the card-count branch, and sampling `select_move()` plays it **0%** of
  400 samples (before the fix: `GOOD * HANDMAID = 150`, 63% of picks, against 0..5 for
  every alternative).
- **B** seat 0 reveals seat 2's card (a Handmaid) with its own Priest; seat 2 then uses a
  Prince on seat 3, keeping the Handmaid. Seat 2's hand card never changed, so the belief
  about him is preserved, while seat 1's belief about seat 3 (the target, whose card did
  leave) is cleared.
- **C** seat 2 kills seat 1 with a Guard. `set_inactive` now clears beliefs about the
  eliminated seat everywhere (and the eliminated seat's own array), so nothing is left that
  `main.gd:330-333` (Baron-tie propagation) could clone onto a live player. The score table
  is shown to be identical with and without those slots - `eval_moves` filters targets by
  `is_active()`, so the zombie slots never carried a score.
- **D** seat 1's hand card is a Handmaid and seat 0 believes exactly that; seat 1 then draws
  the second Handmaid and plays it. The engine drops seat 0's true belief - and the test
  shows that is the sound inference, because a seat sees the **card** that was played, never
  the **slot** it came from: the draw pile at seat 1's draw has 11 cards with exactly one
  Handmaid, so "he played the duplicate and still holds the card you believed in" is a 1-in-11
  shot. Measured over 20 000 games, 90.5% of type-matching plays *are* the card the belief
  named. A King play and a Guard play that match no belief clear nothing, and seat 1's next
  play - the Handmaid that is his hand card - finds the slot already empty.
  (An earlier version of the fix keyed the clear on `card.get_index()`, which preserves the
  9% case by letting every seat see which slot a card came from. Tried, measured, reverted:
  that information is not on the table.)
- **E** replays the same two decisions under each policy:

  | policy | impossible call (A) | "seat 2 holds a Handmaid" (B) |
  |---|---|---|
  | shipped | 150, played in 63% of picks | destroyed |
  | doc_fix (the issue 4 draft) | 0, never played | destroyed |
  | what `main.gd` does now | 0, never played | preserved |

```
godot --headless --path . tests/repro_prince_memory.tscn
echo $?   # 0 = all checks passed, 1 = a check failed
```

## tests/smoke_games.tscn — full games with every seat on the AI

Plays whole games in the engine with all four seats on the AI (levels 4/4/3/2, animations
at speed 0), and asserts that the loop keeps producing rounds and eliminations - the
bookkeeping added by the issue 4 fix touches `set_inactive`, the Prince branch and every
card play, so this is the "nothing broke" check. Eliminations are counted by watching seats
flip from active to inactive (`main.gd` calls `Player.set_inactive` directly; the
`defence_failed` / `self_eliminated` signals belong to the human input path).

    rounds played: 300, games: 10, eliminations: 137, no script error

```
godot --headless --path . tests/smoke_games.tscn
echo $?   # 0 = the games kept flowing, 1 = they stalled / no elimination
```

## tests/prince_memory_sim.py — headless model used for the statistics

A Python model of the same rules (deal, play, resolve, memory bookkeeping, `eval_moves`
scoring and level 4's weighted `select_move`) that runs the shipped / draft / applied memory
policies over thousands of games and reports Guard hit rate, plays that are certain misses,
false Baron beliefs, AI self-eliminations, zombie belief slots, valid beliefs destroyed by a
Prince, plays whose type matched a belief and whether the played card was the card the
belief named (90.5% / 9.5%), and round win rates. It is the tool behind the aggregate numbers
in section 4 of
`ai_memory_open_issues.md`; the Godot suites above are the deterministic assertions.

    python3 tests/prince_memory_sim.py 20000   # 4-player games
    python3 tests/prince_memory_sim.py 2000 3  # 3-player games

## tests/issue2_tiebreak_sim.py — ai_memory_open_issues.md issue 2 (the tie-break is not an issue)

Same rules, scoring and memory bookkeeping as `prince_memory_sim.py`; the only thing changed is
the branch of `select_move()` taken when **every** move scores 0:

```
last     -> shipped:  return valid_moves[-1]
uniform -> drafted:   return valid_moves[randi() % len(valid_moves)]
first   -> control:   return valid_moves[0]
```

    python3 tests/issue2_tiebreak_sim.py                  # 10 000 4p rounds x 3 paired seeds
    python3 tests/issue2_tiebreak_sim.py 3000 4 fixed13   # section 1+3 scoring (knock-on)

Three counters matter. `fell_through_loop` counts times the weighted prefix-sum loop ran out on
a *nonzero* sum: **0 in 277 576 decisions**, because `EvalScore.LOSE = 0` is the floor of the
table and no `eval_moves` branch goes negative - so `sum == 0 -> sum = 1` is the only guard
against `randi() % 0`, `valid_moves[-1]` is reachable only from an all-zero list, and the loop
is a *dominance* order (any positive score beats every 0 score), not a weighted sampler over
the list. `len1` counts zero-score turns with a single legal move: **747 of 1 212 (62%)** - no
tie to break, all three policies are one policy. `all_moves_are_guard_probes`: 82 (6.8%).

| | `[-1]` (shipped) | uniform | `[0]` (control) |
|---|---|---|---|
| zero-score decisions | 1 212 (0.437%) | 1 218 | 1 223 |
| last generated move | Prince 648, Priest 409, Guard 82, Baron 73 | 650 / 411 / 84 / 73 | 650 / 412 / 88 / 73 |
| Guard hit rate | 23.98% | 23.96% | 23.96% |
| "Princess" declared while holding the Princess | 74 | 11 | 0 |
| seat 0 win rate (mean of 3 seeds) | 25.84 | 25.67 | 25.55 |

Recorded in section 2 (severity L, not H): the symptom is real and deterministic, it is 0.03%
of decisions, it lives in states where `find_valid_moves` offers nothing but certain-miss Guard
probes (there is no Princess case, so a Princess in hand is never a move), and the tie-breaks
that remove it measure the same win rate. With `fixed13` the same probe measures the knock-on on
issue 1: 1 254 zero-score decisions (+42) and 92 last-is-Guard turns. The load-bearing property
is that the score table is non-negative - an assert, not a fix.

## tests/repro_score_multiplier.tscn — ai_memory_open_issues.md issue 3 (the claim is false)

Issue 3 was written from the premise "`_target_type` is `Deck.CardType.Unknown == 0`", so
`EvalScore.GOOD * m._target_type` zeroes a guaranteed Baron win (`player.gd:244`) and the
Princess-burning Prince (`player.gd:258`), and level 4 "never plays" them. `Deck.CardType`
starts at `Guard = 0` and `Unknown` is the 9th value: **`Unknown == 8`**, so both branches
evaluate to `GOOD * 8 = 400` - the largest number in the scoring table, above the best Guard
guess (`50 * Princess = 350`). The moves are played greedily.

Four seats are not needed here: the suite builds two real `Player` nodes, fills the hands
with real `Card` nodes, sets a memory slot, and runs the production `Player.eval_moves()` /
`Player.select_move()` on a move list generated the way `Main.find_valid_moves()` does it.

| test | position | issue 3 predicts | measured |
|---|---|---|---|
| A | `[Baron, King]`, memory of rival = Priest (the Baron wins: King > Priest) | 0 = LOSE, never played | Baron 400 vs King 5 -> played 390/400 samples |
| B | `[Baron, Guard]`, memory of rival = Priest (the Baron loses) | - | score 0, played 0/400 - the branch is coherent, `my_type` is the leftover card |
| C | `[Prince, Handmaid]`, memory of rival = Princess | 0 = LOSE, never played | Prince 400 vs Handmaid 20, self-Prince 10 -> played 387/400 samples |
| D | "GOOD x rank of the killed card" | rank scaling | Baron win vs a believed Priest / Prince / Countess = 400 / 400 / 400 - the multiplier is the constant `Unknown`, not a rank; the Guard branch does scale (350 for a Princess call) |

    godot --headless --path . tests/repro_score_multiplier.tscn
    echo $?   # 0 = all checks passed, 1 = a check failed

What the suite records for section 3 (severity L, not H): the ordinal `Unknown` sits inside a
scoring expression, so reordering `CardType` rescales every Baron/Prince kill score silently;
kills are not differentiated by rank (a Princess burn = a Baron win on a believed Guard); and
the 400 is paid for false beliefs too. The rank-scaled alternative `GOOD * (1 + mem)` is a
rebalance, not a repair - measured over 30 000 four-player rounds it takes fewer guaranteed
Baron wins (94% -> 82%) at a win-rate difference inside Monte-Carlo noise.

## tests/repro_belief_truth.tscn — ai_memory_open_issues.md section 1 (not an issue)

`godot --headless --path . tests/repro_belief_truth.tscn` (~7 min for the default 500 rounds;
`--rounds=1500` takes ~23 min)

1 500 four-player rounds, all four seats Level 4, the production scene, no production file
touched. It checks the *invariant* the section 1 closure rests on - "every non-Unknown `_memory`
slot naming a live rival names that rival's real hand card" - at the only moment that matters:
inside `ai_move`, in the frame before the AI plays, where hand, `_memory` and `_left` are exactly
what `eval_moves` reads. `Card.type` is the ground truth, `Deck._left` is the public accounting.

Five checks, reported as counts, the test fails on any of them:

- **A** - every belief a deciding seat holds about a live rival, read against the rival's real
  hand. Measured 412 belief observations (500 rounds) / 1 200 (1 500 rounds), **0 false**.
- **B** - every Guard played on a belief and every Guard played on the card count: hit / miss /
  provably-impossible (the single Princess in the guesser's own hand, or two copies of a 2-copy
  type in it). Measured, over 500 rounds: 118 memory-driven guesses - 118 hits, **0 impossible**;
  1 703 count-driven guesses - **1 impossible**. `guard_memory_miss` is 0 by construction - a
  belief-driven guess is a read of the card it guesses - and that one count-driven case is a legal
  probe the shipped count branch already scores 0 (the copy it counts sits in the guesser's own
  hand), i.e. section 5 item 1's accounting, not a play the AI is missing.
- **C** - a "Princess" declaration played by a seat that is itself holding the Princess: section
  2's pathological tail, visible in the engine. Measured 1 in 500 rounds.
- **D** - every Baron played on a belief: does the belief name the target's real card (the section
  3 knock-on, priced in play). Measured 44 (500 rounds) / 101 (1 500 rounds), **0 false**.
- **E** - beliefs about eliminated seats at decision time (`set_inactive`'s clear). Measured 0.

    godot --headless --path . tests/repro_belief_truth.tscn
    echo $?   # 0 = every check passed, 1 = a check failed

Measured (500 rounds): 4 666 Level 4 decisions - 9.3 per round, each one scanning the three
rival rows - 1 703 count-driven guesses, 44 Baron plays on beliefs with 0 false, 0
zombie beliefs, 0 script errors in the log. The 5 000-round run was tried and is not recommended: cost
is superlinear in rounds (500 rounds ≈ 7 min, 1 500 ≈ 23 min) because the test scene accumulates
leaked `Card` nodes - the same leak `tests/smoke_games.tscn` reports - so 5 000 rounds is hours.
The 20 000-round version of the same measurement is `tests/prince_memory_sim.py`: over 2/3/4
players with the applied memory policy, 15 966 / 20 014 / 26 532 belief-driven Guard guesses are
all true (0 false), 0 name a card already out of play, Baron beliefs are 0 false out of 4 090
(4p), 1 183 Princes aimed at a believed Princess waste 0, and 0 decisions see a belief about an
eliminated seat; with the pre-fix policy the same cells read 2 099 / 3 291 / 6 426 false Baron
beliefs and 1 750 self-eliminations - the number that made section 1 read as severity H.

## tests/noble_family_rules.tscn — Noble Family variant, resolved rules (docs/noble-family-todo.md)

Step 4 pins the **deal table** of `Deck.prepare_noble()`; later steps append scripted cases to
the same file (step 14 round end, step 15 Prince family/widow/elimination, step 16 elimination
reveal + discard accounting, step 31 joint move legality and L1 determinism). TEST A needs no
`Main` scene - it drives the real `Deck` scene directly, 200 seeded deals per player count.

| player count | burn / widow | first-hand | family per seat | main pile leftovers |
|---|---|---|---|---|
| 2 | 3 | 1 per seat | 5 | 1 |
| 3 | 1 | 1 per seat | 4 | 0 |
| 4 | 0 (no widow pile exists) | 1 per seat | 3 | 0 |

10 checks per player count, all PASS (30 checks): widow size == burn and the widow sprite is
visible iff burn > 0; 1 first-hand card per seat; `count` families of equal size; every family is
an `Array[Deck.CardType]` (so it is assignable to `Player.family` in step 5); conservation
`burn + first_hand + families + main == 16`; `_left` elementwise equal to `Deck.card_count`
(family dealing decrements nothing - the step 17 invariant is `sum(_left) == 16 - played`); and the
four piles form an exact permutation of the 16-card deck (no duplicate, none lost, no `Unknown`).

Harness sanity: breaking one expectation (`widow == burn + 1`) prints 3 FAIL lines and exits 1.

### TEST B — the joint (draw, play, target) enumeration (step 11 + step 12 policies)

A `Main` scene is instantiated but **never started** (no `init_players()` call, so the game loop
never runs): the harness sets seat 0's 1-card hand, his family array and the four protection flags
by hand, then calls the production `Main.find_valid_moves()` and `Player.select_move()` on that
state. `_other_protected` is recomputed exactly as `new_turn()` does it. Cards are built the way
`Main.deal_card()` builds them (into `AnimationLayer` first, then `Player.add_card()` reparents
them) - setting `Card.type` before the node is in the tree is a SCRIPT ERROR on the sprite.

Move counts are written out by hand, not recomputed from the production code:

| scripted state | expected moves |
|---|---|
| 4p, Guard + family `[Baron, Handmaid, Princess]`, nobody protected | 3 x 21 + 3 + 1 + 1 = **68** |
| 4p, Countess + family `[Prince, King, Princess]` | 1 + 1 + 2 = **4** (Countess forced twice) |
| 3p, Prince + family `[Handmaid, Guard]`, **both opponents protected** | 1 + 1 + 1 + 14 = **17** |
| 2p, Princess + family `[Princess]` | **2** (the forced Princess play) |
| variant seat with a 2-card hand (the human placeholder, step 20) | 3 x 7 + 3 = **24**, no draws |

Every emitted move is then checked individually: `_drawn_family_idx` is a real family index and
`_drawn_type` is that family card; playing one card of the pair `(active, family[f])` forces
`_leftover_type` to be the other card; `_played_card` is the hand node when the active card is
played and `null` when the drawn card is (so a variant move is describable with types alone); a
Countess + man pair never plays the man; the target follows the type rules (self-only for
Handmaid/Countess/Princess, Prince hits an unprotected seat including self, Guard probes name a
Priest..Princess type and may hit a protected seat only when `_other_protected`); and no
(draw, play, target, type) combination is generated twice.

Two rules the enumeration had to settle, both pinned here:

- **a Princess play exists in the variant enumeration only.** Classic never offers a Princess to
  the AI (no `Princess` case in `find_valid_moves`) and cannot reach the state that forces one -
  the deck has 1 copy. The variant deals 2 Princesses into one seat's pair (hand + family), where
  an empty move list would strand the seat with no move at all, so the pair's Princess plays are
  enumerated as self-targeted moves. TEST (2p, Princess + `[Princess]`) asserts the list is
  non-empty, and the 2-card-hand case asserts a Princess is still never enumerated outside the
  joint enumeration (classic behaviour, both modes).
- **level 4 never pays for it.** A Princess has no `eval_moves` branch, so it scores 0, and the
  weighted prefix loop can only pick a positive-scoring move when the sum is positive: 40 samples
  play it 0 times.

The level 1-4 policies over one enumerated list (the todo step 12 gate, asserted in the suite):
level 1 takes `valid_moves[0]` (family index 0, active card, as-dealt order = deterministic); level
2 stays inside the list and spreads over 4 distinct (draw, play) pairs in 60 samples; level 3 draws
the cheapest family card (Guard, 15 candidate moves) and plays the cheaper card of the pair when
such a play exists; level 4 scores the list (sum 140) and never plays a 0-score move.

### TEST C — a whole scripted 4p round that ends on the family (step 14)

TESTS A and B build state by hand. TEST C plays **whole real games** through the unmodified
production flow, on a **scripted supply**: `FakeDeckScript` gains `prepare_noble()` (the classic
`prepare()` stays for the classic suites) and replays its `scripted` list through the real Noble
deal table - 4p burns 0, so first-hand 1 per seat, family 3 per seat, main pile 0, no widow - and
`scripted_left` so `_left` mirrors the scripted supply instead of the full 16-card deck.
`prepare_noble()` pops from the back, so the deal order reads front to back in `scripted`.

The supply is 16 cards of Guard / Handmaid / Countess only, and every seat is level 1, so the whole
round is deterministic: `valid_moves[0]` is (draw family index 0, play the active card), seat *i*
plays his first-hand card, family[0] and family[1] on his 1st/2nd/3rd turn and keeps family[2]. The
supply has no Priest in any hand, so every Guard probe misses by construction: **no seat can be
eliminated**, the scripted deal is re-applied identically every round (the same family-out actor,
so nothing drifts), and 4 rounds are compared round by round.

The rule under test is the todo step 14 rule - *the round ends at **turn start** when the seat to
act has an empty family* - and the invariant it lives with: **a family draw happens exactly on the
play of the move that named it, and an AI seat never draws at turn start.** Counted by
`tests/counting_main.gd`, which now also counts `new_turn()` calls per seat (`round_end_turns`),
the seat that opened each round (`round_start_actor`), real pile draws (`pile_draws`, i.e.
`deal_card()` without an explicit type) and the first-hand deals. Per round:

| check | why it is the rule |
|---|---|
| 12 plays == 4 seats x family size 3 | the round ran to the family-out end; it never stopped earlier |
| 13 turns == 4 x 3 + 1 | the round ended **on the turn that found the empty family**: every playable turn was taken, then exactly one more |
| the ending seat == the seat that opened the round | 4 seats x 3 family cards means the 13th turn belongs to the 1st seat - that is where the families run out |
| the seat to act has family size 0, every family sums to 0 | the round-end condition is "the seat to act is out of family cards", nothing else |
| 0 eliminations, 0 draws from the main pile / widow | the family-out rule is the ONLY way this round could end, and the turn-start draw is never a pile draw |
| 4 first-hand cards dealt | the round was re-dealt (families are re-dealt every round, never carried over) |
| per seat: plays == family draws == 3, every draw index 0 | one family draw per play - a turn-start placeholder draw for an AI seat would push draws past the family size (and crash `pop_family`) - and the as-dealt order is kept |
| 1 card in every live seat at round end | the variant's hand is 1 card, always |
| `_left == [3,0,0,0,0,0,1,0]`, sum == 16 - 12 | 16 - 12 plays, family draws decremented nothing |
| 48 move/draw pairings, 0 mismatches | every move named the family card its own play chain drew, checked from inside the chain |

Harness sanity (sabotage, then `git checkout -- main/main.gd`, which discards nothing tracked):
round-end on `family.size() <= 1` instead of `is_empty()` -> **25 FAILs** (8 plays, 9 turns, actor
with 1 family card left, `_left == [5,0,0,0,0,0,3,0]`); adding the placeholder turn-start draw for
AI seats -> **23 FAILs**, the family empties in half a round and the game degenerates
(`pop_family` past the end), so the invariant is pinned from both sides.

### TEST D — the Prince chain: family draw, widow fallback, elimination (step 15)

Two scripted 4-player / 3-player rounds in which the **only** interesting event is a Prince play.
Every seat is level 1, so each round is deterministic; the Prince hits are *forced* by Handmaids:
an acting seat is always unprotected at his turn start (`new_turn()` resets it) and the Prince
target list is scanned in seat-index order, so the target is the lowest-index live unprotected
seat - protecting seats 0/1 aims seat 3's Prince at seat 2.

| fixture | deal | Prince plays | what they find |
|---|---|---|---|
| 4p | `H,H,G,P` + families `H,[H,G,G]` `H,[H,G,G]` `G,[G,G,G]` `P,[P,G,G]`; **no widow** (4p burns 0), main pile 0 | 4th, 8th, both on seat 2 | family 2 -> 1; then family **0** and no widow -> seat 2 **eliminated** |
| 3p | widow 1 Guard, `G,P,P` + families `G x4`, `P,[P,G,G,G]`, `P,[P,G,G,G]` | 2nd, 3rd, 5th, 6th, all on seat 0 | family 3 -> 2; family 2 -> 1; family **0** + widow 1 -> draws **the widow**; family **0** + widow **0** -> seat 0 **eliminated** |

`CountingMain.resolve_effect()` runs exactly once per play, so it snapshots the whole board
**before** and **after** every effect (`effect_log`): family sizes, hand sizes, `is_active()`,
widow size + sprite, and `_left`. "The target's family size AT THE HIT" is unreadable by polling
(the whole chain resolves in a few frames at `_speed = 0`), which is why the hook is a
`resolve_effect()` override. `before` is taken after the played card reached the table and before
`discard(_table)`, so each record shows exactly the state the Prince acts on.

Asserted per round: the outcome of each hit is decided by the family size and the widow size at
the hit (family first, widow as fallback, elimination only when both are empty) - never by
anything else; the hand is exactly 1 card for every live seat at **every** effect boundary; the
eliminated seat has 0 hand cards and is out; `sum(_left) == 16 - plays - prince_hits` at every
play (each play discards 1 card, each Prince hit discards the target's hand card, family/widow
drawing discards nothing - the formula holds here only because every elimination in these
fixtures is Prince-caused, a Guard/Baron/Princess elimination would add one more decrement);
`pile_draws == 0` in 4p and `== 1` in 3p, and that single pile draw **is** the widow fallback, so
the widow is never touched at a turn start; the widow sprite is hidden in 4p for the whole round
and hidden in 3p once its 1 card is spent; every family draw used index 0; 11 plays / 12 turns /
actor 0 in 4p and 10 plays / 11 turns / actor 1 in 3p (the elimination does **not** end the round -
the family-out rule does); round-end `_left == [3,0,0,0,0,0,0,0]` (4p, 16 - 11 - 2) and
`[2,0,0,0,0,0,0,0]` (3p, 16 - 10 - 4); and 0 move/draw pairing mismatches.

Harness sanity: swapping the family test for the widow test in the Prince branch (widow first) ->
**12 FAILs** in the 3p round (the widow is spent on play 2, so the family draws, the widow
fallback and the elimination all move), 4p unchanged (4p has no widow) - the *order* of the
cascade is what is pinned.

## tests/noble_family_smoke.tscn — Noble Family variant, whole games on the AI (steps 7, 11, 14)

Variant games (`main.noble_family = true`) with every seat on the AI (levels 4/4/3/2), animations
at speed 0, audio muted: the "the variant plays and terminates" check, the twin of
`tests/smoke_games.tscn` for the classic path.

    godot --headless --path . tests/noble_family_smoke.tscn                        # 4 players
    godot --headless --path . tests/noble_family_smoke.tscn -- --players=3 --rounds=40
    godot --headless --path . tests/noble_family_smoke.tscn -- --seed=999         # other deal/RNG
    godot --headless --path . tests/noble_family_smoke.tscn -- --print_moves=1   # move dumps
    echo $?   # 0 = the variant flowed, 1 = a check failed / the loop stalled

`tests/counting_main.gd` (`extends Main`, installed with `set_script`, restoring the `card_scene`
export afterwards) records the events that cannot be polled: `set_inactive()` (eliminations),
`round_over()` (round ends, plus the seat that was to act), `deal_from_family()` (family draws per
seat) and `resolve_effect()` (before/after snapshots of the whole board per play, TEST D of
`tests/noble_family_rules.tscn`). Polling hand sizes / `Player.active` / the round-over label per frame **drops events**:
at `_speed = 0` a whole turn chain, and even "eliminate → round_over → label → `_new_round`",
can resolve inside a single frame. Plays are counted on each seat's own `move_chosen` /
`card_played` signals, and a Prince play is recognized via `Move.played_type()` - in the variant a
move that plays the drawn family card has a **null** `Move._played_card` at decision time.

Measured, 40 rounds per player count (seed 20260607), **with the joint (draw, play) moves of step
11 live** - an AI seat no longer draws family index 0 at turn start, he draws the card his chosen
move names:

| players | games started | family-out ends | eliminations | plays | prince plays | avg plays/round | max plays/round |
|---|---|---|---|---|---|---|---|
| 4 | 5 | 3 | 76 | 329 | 31 | 8.22 | 11 (ceiling 12) |
| 3 | 5 | 4 | 56 | 299 | 29 | 7.47 | 11 (ceiling 12) |
| 2 | 5 | 7 | 33 | 203 | 20 | 5.08 | 10 (ceiling 10) |

(The step-7 baseline, with the placeholder draw at turn start, was 70 / 336 / 8.4 · 61 / 267 /
6.67 · 35 / 156 / 3.9 - the same shape, the same family-out ends, so the joint enumeration did not
break the flow, it only changed which card a seat draws and plays.)

**Determinism (the step 12 gate):** two runs of `--players=4 --rounds=20` on the default seed print
byte-identical play logs (506 `new_turn` / `resolve_effect` / effect lines each); the same suite
with `--seed=999` prints a different log (489 lines) - level 1's `valid_moves[0]` is deterministic,
level 2's uniform pick is not. `--print_moves=1` dumps every enumerated move; in a 4p variant game
every line carries its draw, e.g. `Move score 20: Baron (0), draw King (#2), keep King, tgt 0`, and
a Baron turn on family `[Prince, Guard, King]` prints 37 moves (7 + 24 + 6).

**The (draw, play) pairing (the step 11/12 gate):** `CountingMain._on_move_chosen` wraps the play
chain itself (`Main` calls its own method, so the subclass override is what runs - the same trick
the suite already uses for `set_inactive` / `round_over` / `deal_from_family`). It notes the family
index the chosen move names (`Move._drawn_family_idx`) and how many family draws that seat has
executed so far, and after the chain resumes it asserts that the draw the chain executed - at that
position in the seat's draw history - IS the named card. Pairing from inside the chain is the only
way this can be checked: `move_chosen` fires before the chain animates the draw, so a harness that
samples the game always sees the recorded moves one ahead of the recorded draws (the first version
of this check sampled per round and reported 36 phantom mismatches in 20 rounds for exactly that
reason). A chain abandoned by a round end never resumes, so its move is not counted - and its draw
never happened either, which is the same fact about the same chain. The suite prints how many
pairings it verified (`move/draw pairings verified: 175` in a 4p/20-round run) and fails if that is
0.

**Step 14 added three per-round checks** (`check_round`, with counters `CountingMain` collects now:
`new_turn()` calls per seat, the seat that opened each round, real pile draws, first-hand deals):

- **a round draws from a pile at most once per Prince play** - today the only pile draw is the
  Prince's redraw of its target (`Main.play_card`'s Prince branch, `deal_card(target, true)`); todo
  step 15 moves that redraw to the target's family with the widow as fallback, and then a round
  touches no pile at all. Counted by wrapping `deal_card()`: an explicit `card_type` is the
  first-hand deal, `Unknown` is a pile pop. The scripted round in rules TEST C (no Prince) asserts 0.
- **1 first-hand card per seat per round** - every round is re-dealt, the families are re-dealt and
  never carried over.
- **the length of a *clean* family-out round** (no elimination, no Prince play): `plays == seats x
  family size`, `turns == plays + 1`, and the seat that ends the round is the seat that opened it.
  Those three numbers are what the family-out rule means. They are asserted only for a clean round:
  a Prince play belongs to a chain that resumes after the round end (its play is not a turn of this
  round), and a chain abandoned at a round end lets one family draw land in the next round's bucket -
  which is why the per-seat bound stays `plays[seat] <= family_draws[seat]` here and the exact
  equality is asserted in the scripted suite (rules TEST C, whose supply has no Prince).

And one harness bug this step exposed: `CountingMain.draw_mismatches` is typed (`Array[String]`), so
`main.draw_mismatches = []` from a harness is a runtime SCRIPT ERROR ("Invalid assignment"), and a
script error kills the rest of that frame - the pairing loop after it never ran, so the smoke suite
printed **nothing** about mismatches (3 suites x 40 rounds) while claiming the pairing was clean.
Reset typed arrays through a method (`clear_draw_mismatches()`), never by assigning `[]`. Harness sanity: making the chain draw family index 0 instead of the named card prints 3
`move/draw mismatch` FAIL lines and exits 1 (the desynced hand then crashes the run, the same fact
from the game's side).

Per-round checks: `plays[seat] <= family_draws[seat] <= family size`; `family_size(seat) ==
family size - family_draws[seat]`; a round with no elimination is a **family-out end** (the seat
that was to act has an empty family, `family_draws[actor] == family size`) with `sum(_left) ==
16 - plays - prince_plays`; every live seat holds exactly 1 card at round end.

**A round with no Prince involvement is 12 plays in 3p/4p and 10 in 2p; the measured averages are
far lower because a Prince aimed at a seat consumes one of *his* family cards (`deal_from_family`),
so a seat can run out of family cards with fewer than `family size` plays to his name, and no 4p
round in the sample reached the 12-play ceiling (max 11).** Only rounds with no elimination are
checked against the family-out rule (`family_draws[actor] == family size` + the `_left` sum); the
other rounds are cut short by an elimination and only the per-seat bounds are checked.
