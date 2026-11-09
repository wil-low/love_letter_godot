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
reveal + discard accounting, step 17 the continuous `_left` audit on the real deck, step 18 the
seat's own family stack node, step 19 the family draw modal, step 20 the human's turn-start draw
through that modal, step 31 joint move legality and L1 determinism). TEST A needs no
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
(family dealing decrements nothing - the step 17 audit measures the DEAL, so the baseline of a
round is the full 16-card supply, families included); and the
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

### TEST C2 — the continuous `_left` audit on the REAL deck (step 17)

TEST C and every fixture after it run on `FakeDeckScript`: `FakeDeck.deal_card()` decrements
`_left.find(true)` - the type with the most left, not the type it hands out - and `scripted_left` is a
hand-written multiset. The audit's per-type identity

    _left[t] == (supply as dealt for this round) - (cards of type t discarded in it)

is a statement about the REAL deck's accounting, so on those fixtures `CountingMain.audit_applies()` is
false (it tests `_deck.get_script() == load("res://deck/deck.gd")`), the audit skips - **counted as a
skip, never silently** - and the fixture's own end-of-round `_left` checks stay the gate. TEST C2 is the
counterpart: the real `Deck` script stays on (no `set_script` on the deck node), 4 seats on level 1
(deterministic), seed 20260607, 3 rounds. The plays are NOT scripted, so eliminations, Prince hits,
reveals and family-out ends land wherever the cards fall - which is the point: the identity has to hold
at every audit point, continuously, not only at the round-end snapshot the smoke suite reads.

| check | measured |
|---|---|
| audit points | 114 audits, 3 skipped (the round-end `discard` animations), **0 violations** |
| the baseline IS the deal | `_base_left == Deck.card_count == [5,2,2,2,2,1,1,1]` and `_base_kinds == [0,0,0,0]`: taken at the round's first turn, when every card of the supply has exactly one home |
| per round, elementwise | `_left[t] == base[t] - discards[t]` for all 8 types, e.g. round 1 `[0,1,1,1,0,1,0,1]` with 11 discards, round 2 `[1,0,0,0,0,0,0,0]` with 15 |
| per round, total | `sum(_left) == 16 - discards` (5 == 16-11, 1 == 16-15, 5 == 16-11) |
| the deck is reset every round | `sum(_base_left) == 16` in EVERY round - `_build_deck()` restores the full supply at the round start, the family cards included |
| cards that left play, by container | played 7 / 7 / 9, hand cards 2 / 3 / 2, revealed families 2 / 5 / 0, **other 0** (an unknown container is a FAIL) |

Harness sanity (sabotage, then `git checkout -- main/main.gd`): skipping the `_left` decrement for
Priest discards in `Main.discard()` -> the audit fires at every audit point in TEST C2 and in the smoke
suite (see below).

### TEST D — the Prince chain: family draw, main-pile / widow fallback, elimination (step 15)

Four scripted rounds in which the **only** interesting event is a Prince play - one per player
count that can produce a distinct branch (3p and 4p need two rounds each, see the table).
Every seat is level 1, so each round is deterministic; the Prince hits are *forced* by Handmaids:
an acting seat is always unprotected at his turn start (`new_turn()` resets it) and the Prince
target list is scanned in seat-index order, so the target is the lowest-index live unprotected
seat.

| fixture | deal | Prince plays (all derived, all matched) | what the hits find |
|---|---|---|---|
| 4p | families `H,[H,G,G]` `H,[H,G,G]` `G,[G,G,G]` `P,[P,G,G]`; **no widow** (4p burns 0), main pile 0 | 4th, 8th, both on seat 2 | family 2 -> 1; then family **0**, no widow, no main pile -> seat 2 **eliminated** |
| 3p | widow 1 Guard, families `G x4`, `P,[P,G,G,G]`, `P,[P,G,G,G]` | 2nd, 3rd, 5th, 6th, all on seat 0 | family 3 -> 2; 2 -> 1; family **0** + widow 1 -> draws **the widow**; family **0** + widow **0** -> seat 0 **eliminated** |
| 3p #2 | widow 1 Guard; seat 0 plays Handmaids, seat 1 is the victim (family 4 Guards), seat 2 plays Princes on turns 3 and 6 | 3rd, 6th, both on seat 1 | family 3 -> 2; family **1 -> 0** - the target's **last** family card, widow untouched, no elimination |
| 2p | widow 3 Guards + **1 main-pile leftover**; seat 0 (victim) plays Guards, seat 1 plays Princes on turns 2, 4, 6 | 2nd, 4th, 6th, all on seat 0 | family 4 -> 3; 2 -> 1; family **0** -> draws **the main pile**, not the widow |

The last two rows exist because the first two cannot produce those states: in 4p the hits land on
seats' turns 4 and 8 with the victim's own draw on turn 7 in between, so his family is 2 then 0 at
the hits; in the plain 3p round seat 0 is hit on his neighbours' turns 2, 3, 5, 6, i.e. at family
3, 2, 0, 0. A victim's family is only ever at an **even** size at a hit in those arrangements, so
`if tp.family.size() >= 2` in the Prince branch passes them all - fixture 3p #2 (hit at family
exactly 1) and fixture 2p (the main-pile leftover in front of the widow) close that gap.

`CountingMain.resolve_effect()` runs exactly once per play, so it snapshots the whole board
**before** and **after** every effect (`effect_log`): family sizes, hand sizes, `is_active()`,
widow size + sprite, cards on the table, and `_left`. "The target's family size AT THE HIT" is
unreadable by polling (the whole chain resolves in a few frames at `_speed = 0`), which is why the
hook is a `resolve_effect()` override. `before` is taken after the played card reached the table
and before `discard(_table)`, so each record shows exactly the state the Prince acts on.

`_left` is derived, not measured: `Deck.discard()` is the only decrement, so

    sum(_left) == main pile + widow + every family + every hand + cards on the table

which is how the snapshot reports the main-pile size (the Deck has no accessor for it) and how the
suite checks accounting at **every** play: `sum(_left) == 16 - plays - prince_hits` (a play
discards 1 card, a Prince hit discards the target's hand card, family/widow drawing discards
nothing - the formula holds on these fixtures only because every elimination here is
Prince-caused; a Guard/Baron/Princess elimination would add one more decrement).

Asserted per round: the outcome of each hit is decided by the family size at the hit and nothing
else (family card -> main pile -> widow -> elimination, in that order); the hand is exactly 1 card
for every live seat at **every** effect boundary (a Disabled seat is excluded via `is_active()`);
the eliminated seat has 0 hand cards and is out; no derived pile size is ever negative; the pile
draws are `0` in 4p, `0` in 3p #2, `1` in 3p (the widow) and `1` in 2p (the main pile) and each one
is the fallback of a specific hit, never a turn-start draw; the widow sprite is hidden in 4p, stays
visible in 3p #2, and goes hidden in 3p when its card is spent and in 2p when the main pile empties;
every family draw used index 0; plays/turns/ending seat are the derived ones (4p 11/12/seat 0, 3p
10/11/seat 1, 3p #2 7/8/seat 1, 2p 6/7/seat 0) and in every fixture the round ends on the **seat to
act** having family 0 - the elimination never ends a round; the fixtures with live seats that still
hold family cards (3p #2: `[1, 0, 2, 0]`) assert that the ending condition is about the seat to act,
not about every family being empty; and 0 move/draw pairing mismatches in all four.

2p is the only count with a main-pile leftover (`16 - 3 burn - 2 first-hand - 2 x 5 family = 1`),
and the empty-family window is **one turn** long (between the draw that empties a family and that
seat's own turn-start family check), so that 1 card absorbs the round's only empty-family hit: in 2p
the 3-card widow is inert, and no seat can be eliminated by a Prince.

Harness sanity (sabotage, then `git checkout -- main/main.gd`): drawing from the widow before the
family -> **20 FAILs** across all four fixtures; `if tp.family.size() >= 2` instead of
`not is_empty()` -> **7 FAILs**, all in fixture 3p #2 (the other three are untouched by it, which is
exactly why fixture 3p #2 exists).

### TEST F — the family stack: 1 node per family card, in the seat, private (step 18)

`Player.render_family(faceup, force)` rebuilds the seat's `$Family` node from the `family` data: one
`Card` node per card at `x = family_cascade_step() * i`, a cascade of 2 px slivers on 11 px cards.
The stack is the **seat's own child** (added in `player/player.tscn`, positioned in `Player._ready()`),
so it follows the seat's position, its scale and its fade; `Main` never renders cards for a seat.

| seat | stack origin (seat-local) | cards cascade | global rect (4 cards) |
|---|---|---|---|
| 0 (5, 31), 1 (5, 0) | (26, 0) | right, +9 | x 31..69, y 31..48 (seat 0) |
| 2 (68, 0), 3 (68, 31) — `right_score` | (-11, 0) | left, -9 | x 30..68, y 31..48 (seat 3) |

What the three fixtures pin:

- **F1, a unit probe on bare seats** (no game loop, so every branch of `render_family()` is reachable):
  the origin and the mirrored cascade step; a seat with no family renders an empty stack; the stack is
  the family in **as-dealt order** (a deliberately descending family with two Kings is rendered as
  dealt, never sorted); the cascade always starts at x 0, so after `pop_family(0)` the top-left card is
  the next card the seat would draw; 3 re-renders of one family stay 4 nodes (the render is a
  **rebuild**, a leak would grow one ghost card per draw); the widths (2 hand cards end at seat-local
  x 24, the stack starts at 26 — 2 px apart on one row; a 5-card stack ends at global x 77 of 84);
  **an AI seat renders NOTHING** from a 3-card family (0 nodes, family 3), `force` renders it
  face-DOWN (that is the reveal), and the menu render takes it back to 0 nodes; `clear_family()`
  clears data **and** nodes, and frees the cards, **not** the stack node.
- **F2, a whole scripted 2p round** (family 5 per seat, no Priest anywhere): the stack is sampled after
  each of the human's 5 plays and is his family minus the draws he made — 4, 3, 2, 1, 0 nodes, names
  `Guard Guard Guard Countess → … → []`, `family_root.get_child_count() == family_size()` at every
  sample; the hand's right edge (global 29) and the stack's left edge (31) never overlap; the round is
  11 turns / 10 plays / **0 eliminations / 0 main-pile draws** (turn-starts per seat `[6, 5]`), so it
  ends purely on the family-empty rule; the AI seat renders 0 nodes at family 5 and again in round 2
  (the re-deal refills the human's stack in the same node, the AI's family stays pixels-free). Every
  human turn start of the round, the first one and the round-2 re-deal included, is tapped through the
  family modal (`_human_draw()` / `_settle_deal_human()` / `_settle_redeal()`, TEST H), because
  production has no auto-pick for a human seat.
- **F3, the E3 Baron position**: seat 1 holds a full 3-card family and renders 0 nodes before the human's
  Baron (the human cannot see the cards he is about to publish); the reveal record shows ONE call that
  rendered into **the seat's own stack node** (not a throwaway container) all 3 cards in as-dealt order;
  after the discard his stack is 0 nodes and his family data is 0 cards; the human's stack tracks his
  own draws through plays 2 and 3 (2 → 1 → 0 nodes); at the round end no seat renders a ghost family;
  in round 2 the seat that was out is back with a fresh invisible family and the human's stack is
  refilled in the same node.

Sabotage (then `git checkout -- main/main.gd player/player.gd`; the counts are the `N CHECK(S)
FAILED` line of `tests/noble_family_rules.tscn`, 656 checks on the shipped code, exit 0):

| sabotage | FAILs | where |
|---|---|---|
| render the family **sorted** (`family.sort()` before the cascade) | **15** | F1 5, F3 10, F2 0 — and F3's round ends on seat 1, not seat 0: a sort changes the DRAW order, so it changes the game, not just the pixels. F2 is blind to it (its scripted 2p family is ascending already), which is why F1 uses a descending family with two identical Kings |
| render **every** seat's family (`is_human()` gate removed) | **67** | F1 3, F2 16, F3 13, E1 13, E2 12, E3 9, TEST C2 1 — a public AI family is counted twice by the supply census (family data + rendered nodes), so the step-17 audit catches it |
| connect `input_event` on stack cards | **16** | F1 4, F2 5, F3 4 ("the stack connects NO input_event") + E1/E2/E3 1 each (the reveal record) |
| `set_inactive()` frees the stack node after the reveal | **stall** | `SCRIPT ERROR: Cannot call method 'get_children' on a previously freed instance` in `Player.clear_family_nodes`, then TEST C2 reports accounting violations and the run never settles (killed at 300 s) — the node has to live on: it is the seat's menu, reveal surface and next round's re-deal |


### TEST G — the family draw modal: a tap reports the family INDEX, exactly once (step 19)

`family_selector/family_selector.{gd,tscn}` is the modal a human seat uses for the **mandatory**
family draw. It is the `type_selector` shape — a `Node2D` of `Card` children plus the one selection
sprite — with three differences: the row is **rebuilt from the family data** on every `open()` (a
family is 0..5 cards, not the fixed 11 types), a tap **commits** (there is no confirm step and no
cancel control anywhere, because the draw is not optional), and it reports an **index**: `Main` pops
`p.family[idx]`. That last point is why the panel is a *view* of the seat's data — `open()` takes
the array, `duplicate()`s it, and the panel can never invent, add, remove, reorder, hide, sort or
count a card the seat does not own.

`open()` lays the family out as ONE row per the todo (`x = 12 + i*12`, `y = 22`), capped at
`MAX_CARDS = 5`, which **is** the deal table's biggest family, so a full family is one row:

| players | family size | row x | row spans (of the 84x48 board) |
|---|---|---|---|
| 2 | 5 | 12, 24, 36, 48, 60 | 12..71 |
| 3 | 4 | 12, 24, 36, 48 | 12..59 |
| 4 | 3 | 12, 24, 36 | 12..47 |

The 12 px pitch on 11 px cards leaves a 1 px gap, so five 11x17 tap targets (88x136 px at scale 8)
can never merge into one zone. 49 checks:

- **G1, the row** — starts with exactly the one sprite node (no widgets, no Control node); the row
  is `x = 12 + i*12, y = 22` in **as-dealt order** at 3, 4 and 5 cards; every card is face-up (the
  family is the seat's own face-up half-deal); every card carries exactly **one** `input_event`
  connection (tappability is the whole UI, and a double connection is a double commit);
  `MAX_CARDS == NOBLE_FAMILY_SIZE.max() == 5` with a 5-card family open, the last card lands at
  x 60..71, i.e. the modal fits the board it is centred over — **no paging is needed for the
  biggest family the deal table can produce**; re-`open()`ing with a different size rebuilds the
  row exactly (one panel serves every turn start and every Prince redraw); `open()` on an EMPTY
  family refuses to open **and closes the row it was showing** (an empty family means the round is
  over at turn start, or the target is out for Prince — a modal with no card to tap is a deadlocked
  turn, and a modal left open on its previous row is a family the seat no longer owns); and
  `set_selection(2)` dims the other cards and moves the type-selector's sprite onto the chosen
  card, while `set_selection(-1)` clears both.
- **G2, the tap -> index contract** — a synthetic tap (`Area2D.input_event` with a mouse-press
  event at the card's centre, the event `Card.pressed()` consumes) on the cards at index **2, 0, 4**
  of a 3-card row and a 4-card row emits **exactly that index**, once (`draws == [2]` … `[4]`), and
  closes the panel (hidden, disarmed). The mapping is index -> card, not position -> order: a panel
  that sorted its row, reported the tap's x, or re-read the family at commit time would still show
  a plausible row of face-up cards and hand `Main` the **wrong** card. A second tap on the same
  index is refused (no second emission), an out-of-row index is refused, and a CLOSED panel commits
  nothing — the draw is mandatory, so the panel must be armable only (`open()`), closable only
  (`close()`), and never self-armed. `close()` alone does not re-arm: re-`open()`ing does, so a
  panel that re-armed itself on close would emit twice per turn start.
- **G3, a view, never an owner** — popping a card out of the family array **while the modal is
  open** cannot retype the row (the panel shows a copy: the row keeps its 5 cards, the caller's
  array is 4); `open()` never pops, and `close()` leaves the family array elementwise intact — the
  destructive half is what matters, because an untyped local (`var types = family`) shares the
  seat's array, so the panel's own `close()` would empty the seat's family (the reference-sharing
  trap step 17 hit, with a hand as the victim); a cancel/BACK control is never created at any point
  of the lifecycle, and after `close()` the panel is back to the bare sprite node — a row that
  survives its modal keeps live `Area2D` zones over the board.

`godot --headless --path . family_selector/family_selector.tscn` runs the panel as a persistent
`Node2D` until the timeout kills it, with no `SCRIPT ERROR`; the todo's debug run (open it with a
fake family of 5 types, tap it, watch the index + the row) is scripted as G1/G2, which open a
5-card fake family and tap it.

| sabotage | detected by | measured FAILs |
|---|---|---|
| the panel reports index 0 whatever the tap (`emit(0)`) | G2 (the taps at 2 and 4) | 5 |
| a tap does not close the modal | G2 (hidden, closed-panel commit, re-arm) | 3 |
| cards are not tappable (`input_event` never connected) | G1 (connections) + G2 (taps emit nothing) | 3 |
| the row is sorted before building it | G1 (as-dealt order) + G2 (index->card map) + G3 (names) | 5 |
| `close()` keeps the row on screen | G1 (close drops the row) + G3 (back to the bare sprite) | 3 |
| a `Button "BACK"` node added to the scene | G1 (no control at start / after open+close) + G3 | 6 |
| the family is kept **by reference** (untyped local, so `close()` clears the seat's array) | G3 (the family survives `close()` intact) | 1 |
| close keeps row + data and leaves the panel armed (double commits) | G1 (2) + G2 (4: 2nd tap refused, closed panel commits nothing, exactly one emission) + G3 (1) | 7 |
| `MAX_CARDS = 4` (a 2p family clips) | G1 (cap == deal table) + G1 (the 5-card row fits the board) | 2 |
| the row reuses the CARD column (`x = 30 + i*22`) | G1 (geometry) + G1 (the 5-card row ends past 84 px) | 2 |
| `open([])` warns and returns, leaving the previous row on screen | G1 (an empty family closes the stale row) | 1 |

One sabotage was measured as **not** detectable, and is worth stating: deleting only the
`_armed = false` line in `select()` leaves every check PASS, because `close()` disarms and empties
the panel's copy — the commit gate that G2 pins is the row's contents, and a closed panel cannot
name a card it no longer shows.


### TEST H — the human's turn start DRAWS through the modal (step 20)

Step 19 built the panel; **step 20 puts it in production**: `main.tscn` carries it as a sibling of
`TypeSelector` at `z_index = 10`, `visible = false` (the modal is allocated ONCE, like the other
selectors, and serves every turn start of every round), and `Main.human_draw_from_family()` hides the
Table, `open()`s the panel on **the seat to act's** family, `await`s the tapped index, `close()`s it,
shows the Table and pops `p.family[idx]`. `new_turn()` calls it only for a human seat, AFTER the
family-empty round-end check, and `_begin_play_selection()` comes after the draw. The step 7
placeholder (`await deal_from_family(p, 0)`) is gone: **no path auto-picks a family card for a human
seat.** 52 checks in three tests, on fixtures with seat 0 human (`Player.make_human()`, the shape the
old `tests/smoke_games.tscn` manual build used).

A harness tap is the production click path: `dispatch_event` is swallowed by Godot in headless, so
`_fs_tap()` fires the card's `input_event` signal with a mouse-press `InputMouseButtonEvent` at the
card's centre — the event `Card.pressed()` consumes (TEST G). Reading the panel is geometry plus one
watcher coroutine (`_watch_modal()`) that counts **rising edges** of `is_open()` and records the seat
that was acting, its row, and whether the Table/any other selector was visible at that frame.

- **H1, the gate (4p)** — at the human's turn start the panel IS open, and NOTHING has been drawn: 1
  hand card, the family untouched (3), `family_draws == 0` with an empty index list, `pile_draws == 0`,
  the Table hidden, no other selector surface visible, the play selection not open, the row is his own
  family in as-dealt order on one line (`x [12, 24, 36]`, `y [22, 22, 22]`), one `input_event` per
  card, one card per family card, every other seat at a full private family and 0 rendered nodes; the
  panel is `Main`'s node and sits at z 10 after the type selector in the tree (same z, so tree order
  decides the tap). **200 frames with no tap and nothing happens** — the draw has no timer, no fallback
  and no auto-pick.
- **H2, the tap (4p, E3's fixture)** — a tap on index **1** is honoured: `family_draw_idx == [1]`, the
  SECOND hand slot holds family[1], his stack reads `[King, Guard]` (an index-0 draw would have left
  `[Guard, Guard]` and put the **King** in his hand), the family shrank by exactly one, the widow is
  untouched, `_left` is unchanged by the draw, the panel closed itself and the Table came back, the row
  is gone, and the play selection resumed. Then the choice decides the game: he plays the Baron with
  the Guard he tapped, **Guard is rank 0** so he LOSES it to seat 1's Priest and **he** is the seat
  that leaves the round (tapping index 0, the King, would have won); his published family is
  `[King, Guard]` — the two cards he did *not* draw — and an eliminated seat never opens the modal
  again (200 frames, 1 family draw total).
- **H3, a whole round (2p)** — a frame watcher counts **5 openings for 5 turn starts, every one on
  seat 0, 0 on the AI seat**, 0 openings with the Table visible, 0 with another selector open; the
  first opening shows the FULL 5-card family and the third shows `[Guard, Guard, Guard]` (the Countess
  he drew out of the middle is off the row: the row is the LIVE family); the drawn indices are the
  tapped indices in order (`[0, 3, 0, 0, 0]`); 5 draws per seat (never twice at one turn start), 0
  main-pile draws, 0 eliminations, the round ends on seat 0's empty family with 1 hand card. The 6th
  turn start (family 0) opens NOTHING — an empty family ends the round, it never opens a panel with no
  card to tap.

| sabotage (main.gd) | measured FAILs | where |
|---|---|---|
| the human turn start auto-picks `family[0]` and never opens the panel (the step 7 placeholder back) | **13** + a harness abort | H1 11, H3 2; TEST H2 then dies on `SCRIPT ERROR: Out of bounds get index '1' (on base: 'Array')` — no row to tap |
| a 1 s timeout fallback auto-picks index 0 when nobody taps | **7** | H1 1 (the 200-frame no-tap check), H2 4 (the drawn index, the drawn card, the stack, the elimination), H3 2 (drawn indices, the third row) |
| the modal opens for EVERY seat, with a one-frame auto-pick (no `is_human()` gate) | **32** | H3's AI-actor check (`[0,0,0,0,0,1]`, AI openings 1) + E2's whole round (18) + the draw/play pairing (5) — an AI seat's family published on screen is a privacy break AND a supply break |


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
that was to act has an empty family, `family_draws[actor] == family size`); every live seat holds
exactly 1 card at round end.

### The continuous `_left` accounting audit (step 17)

The invariant is checked **at every boundary, not at round ends only**, by `CountingMain.audit_left()`,
hooked into `new_turn()`, `_begin_play_selection()` (the pre-decision state, which is where the AI
levels are evaluated), `_on_move_chosen()` (the decision) and `resolve_effect()` (both sides of every
effect), plus the round-end record. Two identities must hold at every point:

1. **per type** - `_left[t] == (supply as dealt for this round) - (cards of type t discarded in it)`, the
   baseline taken at the round's first turn (`_base_left`, `_base_discarded`, `_base_kinds`). Per type is
   the point: a double decrement of one type and a missed decrement of another cancel in a sum, so a sum
   check alone cannot see it.
2. **homes** - `sum(_left) == main pile + widow + every family + every hand + table + cards in flight`,
   i.e. `_left` counts exactly the cards that are still in play, once each. `Player.family_size()` is a
   `Deck._left` decrement-free count of the seat's family array; cards in flight are counted with the
   `deck.get_cards_at_pos("InFlight")` accessor the todo's step 17 note 3 added.

The formula the todo quotes - `sum(_left) == 16 - played_cards` - is the **clean-round special case**:
a Prince hit discards the target's hand card, an elimination reveals and discards a whole family, and
the deck is rebuilt at every round start, so in general

    sum(_left) == 16 - (plays + hand-card discards + revealed family cards + other discards)

Every discard is therefore classified at `discard()` entry, before any card is removed, by its container:
table (a play), a seat's hand, the revealed family of an out seat, other. An "other" discard fails the
suite, and the four counters are what bracket each round.

Skips are **counted, never silent** (`left_audits` / `left_skips` / `left_violations`, printed by the
suite, and the suite fails if a run audits nothing). Three states are audited by skipping them:

- a `discard()` / `reveal_out_family()` animation in flight - the frame after the call decrements
  `_left` card by card while the Card nodes are still children of the container, so a homes census there
  counts the same cards twice;
- between rounds - `_new_round()` discards table and hands, re-deals the families and deals the first-hand
  cards, so no settled round supply exists there;
- fixtures on `FakeDeckScript`, whose `_left` is a scripted shape, not counted supply (rules TEST C2 is
  the real-deck counterpart).

A round-end snapshot that catches an animation in flight is recorded as `settled == false` and the
smoke suite reports it as `round end(s) ended with a discard/reveal animation in flight: 0` (it fails if
that is non-zero); a play chain abandoned by a round end, whose play fires after the round-end record,
is reported as `boundary-chain deviation(s) of 1: 0` (same). Both counters are printed so a regression
in either is visible instead of silently tolerated.

Measured (seed 20260607, 40 rounds per player count):

| players | audits ran | skipped | violations | played | hand cards | revealed families | other |
|---|---|---|---|---|---|---|---|
| 4 | 1615 | 40 (1 per round end) | **0** | 326 | 174 | 116 | 0 |
| 3 | 1515 | 40 | **0** | 307 | 151 | 116 | 0 |
| 2 | 982 | 40 | **0** | 203 | 98 | 94 | 0 |

The audit's cost is 1 pass over the card tree per audit point (`deck.get_cards_at_pos("")` on an empty
container, `deck.get_pile_size()`), and it runs on every AI seat's real move, so an accounting break is
reported at the boundary where it happens, with the point's tag, e.g.
`[effect #3 before (the played card is on the table)] Priest  : _left == 2, expected 1 (dealt 2 - 1
discarded)`.

Harness sanity (sabotage, then `git checkout -- main/main.gd`): skipping the `_left` decrement for Priest
discards in `Main.discard()` -> **258 violation lines in a 6-round run** (both identities, at turn start,
pre-decision, decision and effect boundaries) and `FAIL  258 continuous _left accounting violation(s)`,
exit 1.

**A round with no Prince involvement is 12 plays in 3p/4p and 10 in 2p; the measured averages are
far lower because a Prince aimed at a seat consumes one of *his* family cards (`deal_from_family`),
so a seat can run out of family cards with fewer than `family size` plays to his name, and no 4p
round in the sample reached the 12-play ceiling (max 11).** Only rounds with no elimination are
checked against the family-out rule (`family_draws[actor] == family size` + the `_left` sum); the
other rounds are cut short by an elimination and only the per-seat bounds are checked.
