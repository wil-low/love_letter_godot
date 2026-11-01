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
