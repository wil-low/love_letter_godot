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
    NOBLE UI: scripted 4p game, seat 0 human, played by tapping the family modal - 6 openings, 6 taps,
            19 plays, 19 effect records, 108 frames sampled one by one; surfaces [Prince x2, Guard x15,
            Baron x1, King x1]; rails: 0 frames where the pending draw and the open panel disagreed,
            0 frames crowded by another selector, 0 closed-panel leaks; the Countess-forced play of a
            human seat is TEST I1 play 5

```
godot --headless --path . tests/smoke_games.tscn
echo $?   # 0 = the games kept flowing AND the embedded noble suite passed, 1 = a stall / a check failed
```

**The NOBLE UI line is a nested run, not a copy.** It instantiates
`tests/noble_family_rules.tscn` inside the classic gate (with `quit_on_fail = false` so the nested suite
cannot quit the classic one), awaits its `suite_done`, and prints the counters TEST J measured — so the
single classic command carries the step 22 exclusivity number: 6 modal openings served by 6 taps, and
zero frames of the game in which the rails disagreed. It frees the classic game first, because an AI seat
consumes the global RNG every turn and left running it steals random numbers from the scripted fixtures
(measured: 16 plays where the standalone suite measures 19).

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
through that modal, step 21 the human's Prince redraw through that modal, step 23 the family DEAL
presentation (one slide sound for the whole family batch, zero flights for it, the stack rendered at
the deal), step 24 the MODE PICKER `game_mode/game_mode.tscn` (CLASSIC / NOBLE FAMILY / BACK, one
signal per press, nothing persisted), step 26 the per-mode STATS tables (two 14-counter tables, the
page's `mode`, the `_totals_and_wins` alias), step 27 the stats page's OWN mode switch (a C/F letter +
Left/Right arrows in the page's left margin), step 28 the SAVE and the WRITE TARGET (2 save keys, a
round's counters filed by the game that played it, the 12-counter migration), step 29 the NOBLE FAMILY HELP pages (4 variant pages in the Help scene, 17 pages reachable in a classic game, the Setup page's numeric rows ARE the deal table, paging that never lands on a hidden page), step 31 joint move
legality and L1 determinism). TEST A
needs no
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


### TEST I — a human seat's Prince REDRAW goes through the modal (step 21)

Step 20 made the human's turn-start draw a modal; **step 21 makes his Prince redraw one too.** The
Prince branch of `resolve_effect()` draws the target's replacement card from the target's own family,
so its family branch is where "an AI picks for a human" was living: `await deal_from_family(tp, 0)`.
Step 21 splits it on `tp.is_human()`: a human target gets `human_draw_from_family(tp)` — the same
panel, the same mandatory rules, the same index-reporting contract — and an AI target keeps the
as-dealt index 0, because an AI has no choice to make. **No path in the game picks a family card for a
human seat.** The fallbacks are untouched and stay panel-free: an empty family draws THE WIDOW, an
empty family with no widow card eliminates the target, and `open([])` refuses to open, so an empty
family is never a page. 78 checks in four fixtures with seat 0 human.

Two shapes reach that call site and both are pinned. A **self-Prince** (`tp == p`: `_find_noble_moves`
enumerates self as a Prince target and `_on_target_player_selected` accepts it under `INPUT_ANY_P`),
and **an AI's Prince aimed at the human**, which opens the panel *on the AI's turn*. The watcher here
is the human seat's hands for a whole round (`_tap_modal()`): it taps **every** opening from one queue,
so a turn start and a mid-effect redraw are served by the same code and the recorded taps are the only
taps in the fixture. Each opening is sampled with the acting seat, the row, the seat's live family
DATA at that moment, Table / other-selector visibility, and the seat's hand.

- **I1, a self-Prince (4p)** — 3 openings, all on seat 0, and the middle one is **mid-effect**: the row
  is `[King, Countess]`, i.e. the family MINUS the Guard he tapped one frame earlier, read as the live
  data, and his hand is **0 cards** at that moment (the Prince has already revealed and discarded his
  card, so the panel draws a REPLACEMENT, never a 2-card hand mid-effect) against 1 card at the other
  two openings. The family goes 3 → 2 → 1, one card per tap, `family_draw_idx == [1, 0, 0] ==` the
  taps; the King that lands in his hand is the card he tapped, and it is the card that **wins him the
  round** (scores `1 0 0 0`). The play-1 snapshot is the accounting gate: `before.fams[0] == 2 →
  after.fams[0] == 1` (both draws inside one effect, no phantom draw), the Prince `-1` by the play, the
  victim's Guard `-1`, and the family → hand move `-0`, so `_left == [12,0,0,0,0,1,1,0]` after play 1
  and `[6,0,0,0,0,1,0,0]` (7 == 16 − 8 plays − 1 hit) at the round end. Play 5 is the **Countess**: a
  `(King, Countess)` hand forces index 1, so the harness taps index 1 and says so. Play 5's snapshot is
  `fams[0] 0 → 0`: the turn start tapped out the LAST family card before the play, so a family draw is
  never an effect's family delta.
- **I2, an AI's Prince hits the human (4p)** — opening 2 has `actors == [0, 1, 0]`: an **AI turn** opens
  the **human's** panel, showing `[Guard, Countess]` (seat 0's data; seat 1's 3 Guards are nowhere in
  that row). The tap is index 1, so the **Countess** is what lands in the human's hand — visible as the
  active card at his next turn start (`hand_types == [Guard, -, Countess]`). The hit's snapshot is
  `fams[0] 2 → 1`, `hands[0] 1 → 1` (discarded and replaced, never 2), seat 0 stays active, and
  `pile_draws == 0` with a 0-card widow: a family that has cards never lets a pile card near a human
  hand. 8 plays, 9 turns, 0 eliminations, `_left == [7,0,0,0,0,0,0,0]`.
- **I3, family 0 → THE WIDOW (3p)** — 4 openings drain the 4-card family (`[G,G,G,Countess]`,
  `[G,G,Countess]`, `[G,Countess]`, `[G]`; taps `[0,1,1,0] == family_draw_idx[0]` — the Countess is
  picked out of the middle at index 1 of `[Guard, Countess]`, which only an index-reporting panel can
  do). Then play 5 hits a seat with family **0**: the widow draws for him (`widow 1 → 0`, `hand 0 → 1`,
  still active), **no panel opens**; play 6 hits family 0 **and** widow 0 → **eliminated** (active
  false, hand 0). Exactly 1 pile draw, 1 elimination, 4 openings in the whole round, and the
  elimination's reveal call materializes **0 cards** (`family_size == 0`): an out seat with an empty
  family publishes nothing and opens nothing. 10 plays, 11 turns, `_left == [2,0,…]` == 16 − 10 − 4.
- **I4, family 0 and no widow exists (4p)** — seat 3's Prince hits seat 0 with family 0 and widow 0 →
  eliminated, **no panel, no pile draw, 0 reveal cards**; seat 1 goes the same way at play 11. 2
  eliminations, 3 openings — **0 of them on an AI turn** — 0 pile draws, 11 plays, 12 turns, `_left ==
  [2,0,…]` == 16 − 11 − 3.

Every fixture re-runs the step 17 audit, the step 15 effect-log gates, the step 14 pairing check and
the leak check (panel closed, hidden, no row, the Table visible again, no selector left open), and each
one ends with 200 frames of the round-end state: no panel, no family draw, no reveal.

| sabotage (main.gd) | measured FAILs | where |
|---|---|---|
| the step 20 TODO back: a human target's family draw is `deal_from_family(tp, 0)` (an AI picks for him) | **16** + a harness stall (the run is killed at 220 s) | I1 1 (the self-Prince opens no 2nd panel), **I2 13** (the AI-turn opening is gone, the row, the 0-card hand, the tapped index, `family_draw_idx == [0, 0]`, the Table, the leak check), I3 1 (the row of the T2 hit), + 1 "the round recorded 0 effect records". Then `_human_play_idx` reports "the human seat never reached a 2-card hand in SELECT_CARD (state 0, 1 cards)" and the round never ends: **every tap of the queue is shifted by one**, which is what a "the game drew for the human" bug looks like from outside |
| only a SELF-Prince opens the modal (`tp.is_human() and p.idx == tp.idx`) — an AI's Prince aimed at the human auto-picks | **15** + the same stall | **I2 13** (exactly the list above), I3 1, + the 0-effect-records check — I1 and I4 pass, so the self-Prince path is not what this row pins; the gate is the target's family on ANOTHER seat's turn |
| the panel opens on the ACTOR's family (`human_draw_from_family(_players[_cur_player])`) | **5** | I2 3 (the row is seat 1's `[Guard, Guard]`, the effect's `fams[0] 2 → 1`, the target's `hands[0] 1 → 1`), I3 2 — the panel is the TARGET's family: an AI Prince cannot put HIS cards into a human's hand (it is also a privacy break: it publishes an AI family on screen) |
| the widow fallback is skipped for a human target (`... and not tp.is_human()`) — family 0 eliminates him | **5** | all in I3: the play-5 snapshot (widow `1 → 0`, hand `0 → 1`, active), the elimination at play 6, `pile_draws == 1`, the 11-turn round end, `_left == [4,0,…]` vs `[2,0,…]` — the widow is a FALLBACK PILE, in front of the elimination, for a human target too |

### TEST J — the modal's exclusivity rails, sampled EVERY frame (step 22)

Steps 20 and 21 put the human's family draws in a modal. **Step 22 guarantees that the modal is the
only thing the human can act on while it is open, that the draw it is waiting for happens exactly once,
and that the panel is closed on every way out of it.** `main.gd` carries the state that makes that
inspectable: `_drawing` (a family draw is pending), `_draw_idx` (the index the guarded listener
latched), `is_drawing()` for the harnesses, one listener connected once in `_ready()` (the panel is a
permanent scene child, so a per-`open()` connect would be a per-draw resource a leaky exit path can
strand), `_drawing` guards in `_on_card_played` / `_on_target_player_selected` / `_on_target_type_selected`
/ `_on_move_chosen` that drop anything the play chain delivers under an open panel, the seat's state
forced to `IDLE` for the length of the modal (`Player._on_card_input_event` gates card taps on `_state`,
so this closes his own cards), the four `hide()`s that put the play surface away, the family-index
validation (an index the seat cannot pop takes `family[0]`: the turn-start draw is mandatory, a draw
that never lands never ends the turn), and `_close_family_modal()` on every commit, on `init_players`
(the interrupted game: a suspended `await` never resumes, so this is the only thing that clears it) and
on `_new_round` (the family is RE-DEALT, so a row of the previous family is a menu of cards that no
longer exist). **91 checks in six fixtures, J1..J6** (the suite went 764 → 879: J's 91 plus 24 checks in
TEST F1 and TEST I2 that were being SKIPPED by script errors — a check whose expression raises is never
reported as a PASS, and it is not a FAIL either, so the old suite counted 764 checks and silently ran
fewer; the fixes are the `add_child`-before-`ai_level` order in `_test_stack_unit` (the setter touches
`@onready` children) and reading a watcher's 3rd opening only after it has happened).

**Why a per-frame watcher.** `Main`'s human family draw is a coroutine suspended on
`await draw_selected`, and the play chain is single-threaded, so with `Animator._speed = 0` in headless
a **single `process_frame` can carry a whole game** — deal, 19 plays, an effect, a round end, the next
round's deal. A panel that closes a frame late, a selector that flickers back for a frame, a draw that
pops two family cards in one frame: all of them are invisible to a check made at one moment.
`_watch_rails()` samples the state on every frame and counts violations: frames where `is_drawing()`
and `is_open()` disagree, frames where the panel is open and a play surface is visible, closed panels
left visible or left with a row of cards in them, family draws taken while a modal is open, plays that
land while a modal is open.

- **J1 — a whole 2-round 4p game, frame by frame** — seat 0 human (King + `[Prince, Baron, Guard]`),
  seats 1-3 level 1 (Guard + `[Guard, Guard, Guard]`), 6 family-modal openings and 6 taps: a
  **self-Prince** (the panel opens MID-EFFECT on his own 0-card hand, and the King he taps is the card
  that later swaps with a rival family on the same play), a **Baron compare** against seat 1, and
  **Guard** plays that need a target seat and a declared type. `openings == taps == 6`,
  `family_draw_idx[0] == [0, 0, 0, 0, 1, 0]` == the taps (one pop per tap: a draw that pops twice
  leaves 2 hand cards, a draw with no panel is the game choosing for him); every row equalled the seat's
  live family data at that frame; `hands == [1, 0, 1, 1, 0, 1]` and `fams == [3, 2, 1, 3, 2, 1]` (a
  turn start finds 1 card, a mid-effect Prince finds 0, each opening spent one family card); 0
  eliminations, 0 pile draws, 19 plays in 2 rounds, 1 hand card at every play boundary. The
  Countess-forced play of a human seat is I1 play 5 — the same rule on the same flow, in the same suite.
- **J2 — the rails are INERT, not in the way** — the gate: a family draw is pending, the panel is open,
  the human holds 1 card and his family is full. Probes, in order: a real tap on his own hand card, a
  card played from the chain behind that tap, a target-player tap, a target-type tap, a `move_chosen`
  from a seat in `IDLE` (the only state that answers it), and a real tap on the type selector's card.
  All inert: 1 card in hand, 3 in family, 0 draws, no target, no type, no chain, and each probe leaves
  the pending draw pending. The fixture ends by TAPPING THE PANEL — the draw the rails were guarding
  lands, once, on the card he chose.
- **J3 — a dirty board, and re-entrancy** — `_rails_dirty()` holds the type selector, both target
  labels, the player-selection sprite, the Table **and the seat's own `_state` (SELECT_CARD)** on stage
  on every frame the panel is closed, so the frame the panel opens is a fair test of the hiding lines
  and of the state write (the production flow reaches `human_draw_from_family` with those surfaces
  hidden and the state already `IDLE`, so a fixture that takes the board as it finds it cannot tell the
  rails from luck — measured: deleting the hides, or the state write, changes **0** checks). Then: two
  nested `human_draw_from_family` requests, from the seat that is already choosing, open **no second
  modal**, close nothing, re-build nothing, draw nothing and cannot cancel the pending draw; the tap
  after them draws exactly 1 card.
- **J4 — the guarded listener: no pending draw, no latched index** — with `_drawing == false` the panel
  reports indexes 3 and 0 and Main latches nothing, queues nothing, draws nothing; then a modal is
  opened with the index pre-latched at 2 (the shape two emissions in flight take) and the seat taps 0:
  the card that lands in his hand is the card HE TAPPED, not the one a stray emission latched.
- **J5 — the modal cannot stall the mandatory draw** — a sabotage index the panel cannot produce (99,
  emitted straight on the signal, bypassing `select()`'s validation, which is what a real out-of-the-blue
  emission looks like) closes the panel, clears the pending state and lets the seat take `family[0]`:
  1 draw, 1 card, 2 in hand, play selection resumed. A stalled mandatory draw ends no turn, so the
  fallback is the lesser bug.
- **J6 — closed on every exit path** — (1) the turn-start commit (closed, hidden, no row, the Table
  back, the target selectors answering, 2-card hand, `family_draw_idx == [1]`); (2) the MID-EFFECT
  Prince commit, inside the same effect; (3) a NEW GAME from a modal that is still open: the old panel
  is gone, the interrupted draw resumed into **no second pop** (0 extra draws) and the new round's
  first turn start opens a fresh row of the re-dealt family; (4) a NEW ROUND with a LIVE modal:
  `_new_round` closes it, the seat's family is FULL again (3, his hand 1, the interrupted draw drew
  nothing) and the new round's first opening shows the whole re-dealt family in as-dealt order, not the
  old family's leftovers, opening ALONE.

| sabotage (main.gd) | measured FAILs | where |
|---|---|---|
| the `_drawing` guard removed from `_on_card_played` (a card play is accepted under the panel) | **4** | J2: the play starts a chain under the panel (a card reaches the table, his hand empties), the chosen-move chain runs, his state is left at the play state, and the tap that follows draws on a hand the chain already touched |
| the `_drawing` guards removed from `_on_target_player_selected` + `_on_target_type_selected` | **2** | J2: the target-type tap declares a type under the panel (and shows the Table back), and the chosen-move chain runs |
| the four `hide()` calls of `human_draw_from_family` removed (the panel opens on a dirty board) | **1** | J3 (the opening samples every surface: the Table is back and the selectors are on stage) — J1's crowding counter sees **0**, because the production flow hides them at those moments anyway: J1 monitors the rails, J3 is what pins them |
| `p._state = Player.State.IDLE` removed | **1** | J3 (the seat is tappable under the panel: `state == SELECT_CARD` at the opening) |
| `_close_family_modal()` removed from `_new_round()` | **3** | J6 path 4 (the live modal survives the re-deal, the seat's family is 2 not 3, the stale row is the old family's leftovers) |
| the `_drawing` nested-request guard removed (a nested request re-opens the panel) | **0 + a hung suite** (849 checks in, killed at 260 s) | J3: the nested request re-opens the panel and the fixture's own `await` never returns. The todo's gate for this step is "the modal cannot deadlock a human turn", and this is what that deadlock looks like from outside: a suite that stops printing |

`tests/noble_family_rules.gd` publishes the counters of J1 (`ui_openings`, `ui_taps`, `ui_mismatch`,
`ui_crowded`, `ui_leaks`, `ui_plays`, `ui_effects`, `ui_frames`, `ui_surfaces`) plus `suite_done` and
`fails()`, and honours `quit_on_fail`: **`tests/smoke_games.tscn` runs this suite nested** (with
`quit_on_fail = false`) and prints its `NOBLE UI:` line from those counters, so the classic gate carries
the step 22 number. The nested run frees the classic game first — its AI seats consume the global RNG
every turn, and left running they steal random numbers from the scripted fixtures (measured: 16 plays
where the standalone suite measures 19).


### TEST K — the family deal presentation: one sound, zero flights, the stack is a view (step 23)

Step 23 is a property of the **deal**: the 5/4/3 private family cards per seat appear **in one instant**
(fill `family` + `render_family()`), only the first-hand cards animate, and the whole family batch makes
**one** slide sound, not one per card. Production's part of it is a seam: `Main.deal_sound()`, which
every deal sound in the game now asks for (`deal_card`, `deal_from_family`, the batch), so the batch rule
has exactly one place to live and a harness can count it. Counting the *sound* is not available: Godot 4.7
rejects an override of `AudioStreamPlayer.play()` ("The method `play()` overrides a method from native
class `AudioStreamPlayer`" is a warning treated as an error), so `CountingMain.deal_sound()` counts the
call and calls `super()` — the real `AudioStreamPlayer` plays, at the real call sites, on the real path.
Counting the calls is not a proxy for the rule, it **is** the rule: `play()` RESTARTS its stream, so a
per-card batch is `family_size × player_count` plays of one stream in one frame, each cutting the
previous off — a stutter. **84 checks in four fixtures, K1..K4, every fixture run TWICE** (168 checks in
the log; the batch rule is measured on the real deck, whose draws differ round to round, so a promise
stated on two decks is not one lucky sample). Suite 879 → **1047 PASS / 0 FAIL / 0 script errors**, exit 0.

**`Animator._speed = 0` is not a stop-the-clock switch** (the suite's convention: durations are
multiplied by `_speed`, so at 0 a whole round collapses into frames). The todo's acceptance test is a wall
clock at `_speed = 2` and `_speed = 5`, so K4 measures `Time.get_ticks_msec()` from `_new_round()` entry
to the round's first turn, at 2p/3p/4p, with the **classic deal of the same seat count and speed as the
control** — the control is what turns "1013 ms" into "the family batch added 0 ms".

Counters added to `tests/counting_main.gd`: `deal_sounds` (seam calls); per round
`(audio, pile_draws, family_draws)`; per deal first-hand flights and the **peak number of simultaneous
card flights** (a counter around `deal_card`/`deal_from_family`, never a frame sample — at `_speed = 0` a
frame can contain an entire deal); per-round setup ms; per deal main pile, `sum(_left)` and each seat's
family size and stack node count. `set_inactive()` now marks the whole elimination window on
`reveal_depth`, so the per-frame stack mirror *and* the `_left` audit skip a window whose transients are
steps 16/19's property (an out seat with 3 family cards and no nodes is a legitimate frame inside an
elimination, before `reveal_family()` runs).

- **K1 — the real deck, 2p/3p/4p, 2 full rounds each** — the burn is applied **at the deal** (widow
  3/1/0 cards and the widow node visible iff burn > 0), the family batch leaves the main pile at
  **1 / 0 / 0** (`16 − burn − count × (1 + family)`), `sum(_left) == 16`, every live seat holds exactly 1
  hand card and exactly `NOBLE_FAMILY_SIZE[count]` family cards. The deal animates **THE HAND**: `count`
  flights = the `count` first-hand cards, and the **peak number of simultaneous flights is 1**. The deal
  makes **`count + 1`** slide sounds = the first-hand flights + **1 for the whole 10/12/12-card batch**,
  and in EVERY round of the game the round's sound count IS its animation count + 1:
  `audio == first_hand + pile_draws + family_draws + 1` (measured 4p `[13 = 4+0+8+1] [12 = 4+0+7+1]`, 3p
  `[10 = 3+0+6+1] [15 = 3+0+11+1]`, 2p `[10 = 2+0+7+1] [8 = 2+0+5+1]`), with 12/17/15 family draws in
  those rounds — the batch sound is not the family's only sound, it is the deal's one extra beat. Every
  seat of this fixture is an AI seat, so at the deal **no** seat renders a stack: the batch is data.
- **K2 — the deal the player SEES (2p, seat 0 human, the Countess in his family)** — 16 = 3 burned + 2
  first-hand + 10 family + 1 in the pile, so the batch is dealt **after** the burn, not from the undealt
  tail; the widow IS the supply's first 3 cards and the families start at slot 5. Seat 0's stack is his
  own `$Family` child and materializes all 5 family cards **at the deal**: 5 nodes == 5 family cards, in
  as-dealt order (never sorted), cascade `x = 0, 9, 18, 27, 36` (9 px steps leave 2 px slivers on 11 px
  cards), every node face-up, fully inside the 84×48 viewport, 0 `input_event` connections, 0 cards in it;
  the AI seat's 5-card family makes **0 nodes** (the batch renders for the human only). Then the modal's
  tap pops `family[2]`: family 4, hand 2, and the stack is 4 nodes **in the same frame** the pop happened;
  the drawn Countess is NOT out of play (`_left` Countess 1 of 1 — `deal_from_family` decrements nothing).
- **K3 — the stack is a VIEW, checked EVERY frame** (`_watch_family_view()`, 4 seats per frame; frames
  inside a `discard()`/reveal window are SAMPLED — the reveal is exactly what the watcher must see — and
  NOT judged). The contract: a human seat renders his family, an out seat renders what he left with, a
  live AI seat renders nothing, **in the frame the data changed**. **K3a** = a real all-AI 4p game with one
  Guard kill: 65 sampled frames, **0 violating frames**, 3 frames of the out seat's revealed 3-card stack,
  150 frames of live AI families with 0 nodes, 18 frames in which the total family count changed (draws,
  the elimination clear, the +12-card re-deal) and every one of them matched, 9 frames skipped.
  **K3b** = a live human game with the modal rails (4 openings, 4 taps, 12 plays, a MID-EFFECT Prince draw,
  the round end, the re-deal): 0 violating frames, 42 frames of the human's stack matching a non-empty
  family, 201 frames of 3 AI seats with families and no pixels, 16 changed-total frames all matching, and
  each of the 4 modal draws re-rendered the stack in the frame it shrank.
- **K4 — the deal is timed on the wall clock, classic as the control** — `_speed = 2`: 4p **1013 ms**
  (second pass 992), 3p **758 ms**, 2p **503 ms** = `first_hand × 0.5 / speed`; `_speed = 5`: 4p
  **407 ms** (the todo's "under ~1 s at 4p"); the CLASSIC control at the same speed and seat count:
  **1013 ms vs 1013 ms** at 4p and **503 ms vs 503 ms** at 2p — the family batch adds 0 ms of animation.
  The timing is measured at 2 speeds so a change in `Animator`'s divisor cannot hide behind one number.

| sabotage (main.gd) | measured FAILs | where |
|---|---|---|
| the batch sound played once per family DEAL (per seat) instead of once per round | **14** | K1 2p/3p/4p deal sound (`count + 1` → `2 × count`), the per-round identity in every round of every fixture, K2 |
| the family batch made NO sound at all | **14** | the same checks, the other direction (`audio == animation count`, the identity's `+1` missing) |
| the family batch ANIMATED (one 0.4 s beat per family card, at `_speed > 1`) | **6** | K4 only: 4p 1820 ms vs 1013, 3p 1365 vs 750, 2p 910 vs 502 + the classic-control identity. **0** checks notice it in any per-round snapshot |
| the deal fills the family data and forgets `render_family()` | **10** | K2 (0 nodes vs 5 family cards, the as-dealt order, the cascade) + K3b (the human's frames; the draw that shrinks a stack that was never built) |

The `_speed > 1` condition in the third sabotage matters for the harness, not for the game: the suite's
normal fixtures run at `_speed = 0`, so an unconditional 0.4 s beat per family card makes the suite take
over 300 s (measured: killed at the 300 s timeout with 63 checks in). The timing fixtures are the only
ones that must pay a real timer — which is exactly why step 23 is gated by K4's wall clock and not by a
frame count.

### TEST L — the mode picker: 3 rows, closed until opened, one signal per press, no state (step 24)

Step 24 is a **scene**, `game_mode/game_mode.tscn`, with no caller yet (step 25 wires it into
`application.gd`), so TEST L pins the scene itself: its shape, its open/close contract, its signal
contract, its **lack of state**, and the rects a thumb has to hit. **38 checks in five fixtures,
L1..L5.** Suite 1047 → **1085 PASS / 0 FAIL / 0 script errors**, exit 0.

The shape is the `start.tscn` pattern: a `Label` row per choice with **one flat, full-area `Button`**
child. The rows read **CLASSIC** (y 16..22), **NOBLE FAMILY** (26..32), **BACK** (36..42); a flat
button adds Godot's 1 px content margin, so the tap rects are **x 4..80** at **y 15..23, 25..33,
35..43** — 76×8 board px = **608×64 real px** at the 8× viewport scale, inside 84×48, with a 2 px gap
between the rows, title above the first row and BACK clear of the bottom edge.

- **L1 — the shape** — exactly 3 rows (the Labels that own exactly one child; the Title owns none),
  the texts in reading order, **4 Labels + 3 Buttons and nothing else** in 7 nodes (no Panel,
  LineEdit, TextureButton, Sprite, Timer, ColorRect), every Button `flat`, every Button's global rect
  covering its row's rect (the whole word is the target, not the ink), one Button per row, all rows
  centered.
- **L2 — closed until opened** — the root is hidden at `_ready()` **and** every row is hidden; **no
  Button is `is_visible_in_tree()`**, which is the engine's own input gate (a Control that is not
  visible in the tree gets no mouse input at all), so "nothing tappable while closed" is measured, not
  asserted. `show_rows()` opens root + all 3 rows, all 3 targets become visible-in-tree in the SAME
  open (the todo's Check: all three rows tappable in 84×48), and re-opening is idempotent — 3 rows, no
  duplicates, no extra node. **Deviation, measured:** `func show()` is a **parse error** in Godot 4.7
  ("The method `show()` overrides a method from native class `CanvasItem`", a warning treated as an
  error, verified with a probe script), so the todo's `show()` is implemented as `show_rows()`; the
  suite proves the consequence by calling the NATIVE `show()` — the root opens, every row stays hidden,
  i.e. the native call is not an opening path and the rows are the gate.
- **L3 — one press, one signal, the panel already gone** — pressing each row emits **exactly one**
  signal, in **its own** signal, and the recorded panel visibility **inside the emit** is `false`:
  `hide()` runs **before** `emit()`, the todo's handler shape, so a menu never stays on top of a dealing
  game. BACK emits `back_pressed` **only** — BACK is not a mode, and a BACK that also emitted a mode
  would start the game the player just refused. After a press no row is visible in the tree, so a
  second real tap has **no target**. The scene's API is 3 **parameterless** signals named
  `classic_pressed` / `noble_family_pressed` / `back_pressed` (`get_signal_list()`): the picker reports
  WHICH row, never a mode value, a player count or a level.
- **L4 — it stores nothing** — 3 visits / 3 presses / 3 signals: the picker is reusable across games,
  which is what the todo's Check (PLAY → NOBLE FAMILY → exit → PLAY → CLASSIC) needs. After that, no
  row's text changed, no row's alpha changed, no node was added, and the scene declares **zero script
  variables** (property list filtered by `PROPERTY_USAGE_SCRIPT`), so "the mode is **not persisted**" is
  structural: there is no `_last_mode` for anything to save.
- **L5 — the geometry** — every label and every tap rect inside 84×48, every rect ≥ 48×8 board px, the
  three rects **non-overlapping** (overlapping rows let BACK steal a CLASSIC press, and a mis-press
  starts a whole game), stacked in reading order, and every row's text measured with the game's own
  `LabelSettings` font: **NOBLE FAMILY = 48 px of the 76 px available** at 7 px, so the menu needs no
  second line and no smaller font than the rest of the UI.

Harness facts this step cost:
- **Headless cannot tap a Control.** `Window.push_input()` delivers nothing here: the headless window is
  **64×64** (measured), so a coordinate mapped through the 8× viewport scale is outside the window and
  the event is dropped. A `Button` row's real tap **is** its `pressed` signal (this scene has no Area2D,
  unlike the cards), so the fixtures drive the scene with `emit_signal("pressed")` — the same connection
  the engine's GUI input drives — and prove the *tappability* with `is_visible_in_tree()`, the engine's
  own gate. The eyes-on tap stays in the manual gate (step 34).
- **A `LabelSettings` is not a theme item**: `get_theme_font_size("font_size")` reports the 16 px theme
  default while the label draws with 7 px. Text-width checks read `label.label_settings.font` /
  `.font_size`.
- **`get_signal_list()` signal dicts key `args`, not `arguments`** — the harness hit that as a
  `SCRIPT ERROR: Invalid access to property or key 'arguments'`, which SKIPPED the check it was in
  (neither PASS nor FAIL, 37 checks printed where 38 are written). The step-23 rule earned its keep:
  a green suite must be `grep -c "SCRIPT ERROR"` **0**, not "0 FAIL".

| sabotage (game_mode.gd / .tscn) | measured FAILs | where |
|---|---|---|
| rows NOT hidden at `_ready()` (the `_hide_rows()` call deleted) | **1** | L2's row-visibility check — the root's own `hide()` is a separate line, so "the panel is closed" alone does NOT prove the rows are |
| `show_rows()` shows the root only | **3** | L2 (rows-shown, all-3-targets-visible-in-tree, the idempotent re-open measured 0 rows) |
| handlers `emit()` BEFORE `hide()` | **4** | L3 ×3 (the emit-time visibility, NOBLE, BACK, all read `…:true`) + L4's 3-visit record |
| the CLASSIC row emits twice per press | **3** | L3 (exactly-one-signal, the emit-time record) + L4's 3-visit record |
| a press REMEMBERS the mode (`var last_mode` + the pressed row dimmed to 0.4) | **2** | L4 (the alpha table `[100, 40, 100]` and the script-variable census `["last_mode", "last_mark"]`) |
| the NOBLE FAMILY row moved onto the CLASSIC row (`.tscn` y 26..32 → 20..26) | **2** | L5 (the overlap check, the reading-order check). **Not** the inside-board check: y 20..26 is inside 84×48 — "on the board" and "not on top of another row" are two different properties |

**Harness trap this step paid for:** the scene was still **untracked** when the `.tscn` sabotage ran, so
`git checkout -- game_mode/game_mode.tscn` restored NOTHING (git does not know the file) and the sabotage
stayed in the tree until it was restored by hand. `git status` prints a scene as ONE path
(`?? game_mode/`), which hides that fact — commit a new scene **before** sabotaging it, the same rule
step 11 learned for test code.

### TEST N — the per-mode STATS tables: two tables, one mode each, and the alias `application.gd` writes through (step 26)

Step 26 (todo §C.26) is the requirement "a variant game never adds to a classic game's counters".
Before it, `stats/stats.gd` held ONE `Array[int]` of counters and the page showed it for every mode.
This fixture is the safety net for the data model: it pins the SHAPE of the per-mode tables, the
ALIAS `application.gd` mutates (its two write paths, `_on_round_won` / `_on_round_finished`, are
unchanged by step 26), which table a Reset clears, and that a real classic game writes exactly one
table. The mode is set on the page in `start_game()`; the page's own picker is step 27.

Measured on the 16-card variant deck's own turf — a page built by `load("res://stats/stats.tscn")`, and in
N6/N7 a real `application.tscn` game (4 seats on levels 4/4/3/2, 2 rounds) driven through its own signals.
TEST N is **60 checks**; the suite prints **1200 PASS** on the recorded seed where it printed **1140**
before step 26, 0 FAIL, 0 script error, exit 0:

- **N1 — shape.** 2 tables; index 0 = CLASSIC, index 1 = NOBLE FAMILY; a FRESH page reads CLASSIC; one
  slot pair per `AI_Level` KEY, and `Player.AI_Level.size()` is **7**, `Disabled` included (the enum is
  `Disabled = -1` … `Level_5 = 5`), so a table is **14 counters** and the page's 6 label rows show
  **12** of them — the `Disabled` pair is inert (no game writes level `-1`) and keeping it is what keeps
  `application.gd`'s size rule and this fixture's formula agreeing. Both tables start at zeros, are
  DIFFERENT arrays, and `table()` is a window, not a copy. The page's children are 6 Labels + Back +
  Reset; the 12 slots the 6 rows show are EXACTLY the counters every AI level can write.
- **N2 — two tables.** A full classic write (12 counters) leaves the noble table at zeros; switching
  modes reveals an empty noble table, filling it leaves the classic byte-identical, and switching BACK
  shows the classic numbers intact. Two histories live at once, which is the whole point.
- **N3 — the alias.** `application.gd` reads `_stats._totals_and_wins`, mutates it by index, and
  assigns a loaded save WHOLE. So the alias must hand out the SAME array (`is_same`), per-level writes
  land in the CURRENT table (`[1,3,1,3,…]`, totals at the even slots, wins at the odd, 2 `Disabled`
  slots untouched), a whole-array assignment writes only the current mode's table, and a 12-counter
  save KEEPS its length 12 — the setter must not pad it, because `application.gd` drops a save whose
  size is not `2 * Player.AI_Level.size()`; padding would silently accept the old format (step 28 owns
  that migration). A fresh `options.cfg` (`get_value(..., [])`) yields size 0, which is what the app's
  drop rule must see. The array the setter stored stays LIVE, so counters keep accumulating after a
  save-load round trip.
- **N4 — Reset.** `_on_reset_button_pressed()` clears ONLY the visible table: at noble mode, Reset
  leaves the classic table's 14 counters (100…113) byte-identical, switching back shows them, and the
  labels refresh to the zeros the player reset (a page is a view of the table, not of a snapshot).
- **N5 — labels.** `update_labels()` at classic mode renders the classic numbers in the pre-variant
  format `%5d  %s  %-5d` with 6 rows pairing totals with wins (the format string's own `%` count is
  checked); at noble mode the SAME 6 rows are the noble table, and the two pages are measurably
  DIFFERENT. `Stats.LABELS` is a **String** (`"H12345"`) — `"H12345".length() == 6` and it has NO
  `size()`.
- **N6 — a real classic game writes ONE table.** An app is built the way TEST M builds its menu app
  (`add_child` first, then `_scene_tree_added` + 2 frames), seeded with 14 saved classic counters
  (4,15 / 3,15 / 9,30 — 22 total, 22 finish) and driven for 2 real rounds. Measured: `round_won` 2,
  `round_finished` 8 (one per seat — 4 seats); the file's classic counters match the seed; the game
  ADDS to them (slot 0: 0 → 1, never replaces); totals grow by exactly the `round_won` count and wins
  by the `round_finished` count (a double-counting mode index would double here); the NOBLE table is
  still zeros after the game; the save the game wrote back equals the table the page shows and is 14
  counters long.

- **N7 — the APP is the only file that names a mode.** A real app: a fresh page reads the CLASSIC table
  (a game that has not started has no mode); tapping PLAY → NOBLE starts a variant game AND switches the
  page to the NOBLE table, the alias follows the mode (`is_same`), and the classic table stays at zeros —
  so a running variant game writes no classic counter, which is the requirement in one line; the page
  opened from the PAUSE menu shows the NOBLE table (mid-game counters are the game's own); EXIT clears
  the mode (step 25's rule) and the page opened from the START page shows the CLASSIC table again; the
  rendered rows equal the rows of the table the page shows, in the pre-variant format. This is the app
  half of step 26 (`application.gd`: `start_game()`, `_on_start_stats_pressed`, `_on_pause_stats_pressed`
  are the three lines that name a mode — the two write paths, `_on_round_won` / `_on_round_finished`,
  never do).

**Harness facts this step paid for (measured, not guessed):**

1. `String` has no `size()`: `Stats.LABELS.size()` is a PARSE error (`Cannot find member "size" in base
   "String"`) that kills the whole suite before a line of output. `Stats.LABELS` is a String → `.length()`.
2. `const STATS_COUNT: int = 2 * Player.AI_Level.size()` is a PARSE error too (`Assigned value for
   constant "STATS_COUNT" isn't a constant expression`) — an enum's `size()` is not a constant expression
   in Godot 4.7. The 7 is MEASURED at runtime and spelled as `14`, with the formula in the comment, so
   a new AI level shows up as a failing length check rather than as a silent compile-time doubling.
3. **Godot's stdout tail is lost when the suite's output is redirected** — the last few kilobytes are
   simply gone from the log (the committed suite's own log ends at M4's last check: its M5 checks and
   its `ALL CHECKS PASSED` line are missing there too). A fixture section appended at the END of
   `_ready()` therefore has NO printed evidence. TEST N sits BEFORE TEST M for that reason; the first
   three step-26 runs read that missing tail as "the suite died at M5" and chased a SceneTree death
   that was not there. Order is functionally irrelevant (every fixture builds and frees its own app).
4. `preload("res://stats/stats.tscn")` at the top of the suite leaks — `ERROR: 2 resources still in use
   at exit`, the harness's own step-11 rule. Instantiate with `load(...).instantiate()` at runtime.
5. `table() -> Array[int]` FORCES a typed array, and a typed array rejects an untyped element: a
   whole-array assignment of a plain `Array` read from `options.cfg` is accepted by the setter and would
   raise at the first `table()` read (`Trying to return a value of type Array from a function whose
   return type is Array[int]`) — so the setter normalizes with `int(v)`, and that is why N3's save fixture
   is built as a plain `Array`, the shape `config.get_value` hands back.
6. The `options.cfg` a game writes LAGS the in-memory table: `_on_round_finished` fires once PER SEAT and
   the app saves on every `save_stats` (the measured 4p numbers are 2 counters vs 8 counters after the
   file's last save). N6 waits for the file to converge on the table (bounded), which is a real fixture
   property, not a sleep: `round_won` (1/round) and `round_finished` (4/round) are not a 1:1 ratio.
7. A variant mode is reachable in ONE way, so N6/N7 tap the REAL row (`_tap_row(app, "NOBLE")`):
   `classic_pressed` / `noble_family_pressed` / `back_pressed` are connected in `application.tscn`
   (lines 54-56, so every app instance has them, nothing in `_ready()` connects them), a row press
   hides the panel and THEN emits (step 24's order), and `_on_game_mode_noble_family()` sets
   `Main.noble_family` and calls `start_game()`. `_stats.mode` is written by `start_game()` and by the
   two page openers only — a fixture that set the mode by hand would test a path the game cannot take.
8. An app fixture frees the app as soon as it has measured its point, and a NOBLE app must be settled
   with `_settle_menu_deal(app, NOBLE_FAMILY_4P, 0)` FIRST: freeing an app whose deal is still animating
   leaves the Animator's lambdas pointing at freed cards — 6 script errors (`Invalid assignment of
   property or key 'faceup' ... on a base object of type 'Nil` at `animator.gd:48` and `'position'` at
   `:51`, each followed by `ERROR: Lambda capture at index 1 was freed`). N7's first run measured that;
   TEST M's fixtures already settle, which is why they are silent.

**The 6 sabotages of `stats/stats.gd` (each one applied alone, suite run, then reverted):**

| Sabotage | FAILs | Caught by |
|---|---|---|
| one array serving both modes (`static var _shared`, `tables = [_shared, _shared]`) | **7** | N1 (length, `is_same`), N2 ×2 (the shared write mixes two histories), N4, N5 ×2 |
| the alias getter hands out a `duplicate()` | **5** | N3 ×3 (not a live reference; per-level writes vanish; a snapshot replaces the live array) + N6 ×2 (**the app's counters stay 0** — the write path dies) |
| Reset clears BOTH tables | **2** | N4 ×2 (the classic history is gone; switching back shows zeros) |
| `update_labels()` reads `tables[MODE_CLASSIC]` | **3** | N4 (labels after a noble reset), N5 ×2 (the noble page shows classic numbers; the two pages identical) |
| the page defaults to `mode = MODE_NOBLE` | **12** | N1 (a fresh page opens on a mode nobody played), N3 ×3, N5, N6 ×7 — **every** classic write lands in the noble table and the classic history stops growing |
| the setter pads a short save to 12 | **3** | N3 ×3 (a stale save keeps the length its drop rule must see) |
| `start_game()` does not name a mode (the wiring line deleted) | **2** | N7 ×2 (the page stays on the CLASSIC table while a variant game runs; the alias aims at the classic table — i.e. the variant game's counters would land in the classic history, exactly what step 26 forbids) |
| `_on_start_stats_pressed()` pins NOBLE | **1** | N7 (the start page opens on a mode the player never chose) |

*The six `stats/stats.gd` rows were measured before N7 existed (51 checks then); the two
`application.gd` rows with N7 in place (60 checks). A clean tree prints 1200 PASS, 0 FAIL, exit 0.*

**Not covered by this step (deliberately):** the SAVE format is still ONE key — `Gameplay/totals_and_wins`
holds the CURRENT table, so a variant game's numbers land under the legacy key and a variant history is
lost on the next launch. That is step 28 (per-mode keys + the 12-counter migration), and its rule is
already implied here: the legacy key is the CLASSIC table. The page's own mode picker (a segmented
Classic / Noble Family control on the stats page) is step 27.

**STEP 28 LANDED** (see TEST P): the save is 2 keys and the write paths ask the GAME, so this step's
N3/N6 checks were re-measured against the new format - N6 is now the migration + per-table-drop fixture,
and its "the noble table is zeros after a classic game" check became a DELTA check, because a file that
HAS a noble key makes "zeros" a fixture assumption and not a fact.

### TEST O — the stats page's own mode switch: 1 letter + 2 arrows in the left margin; a flip browses and writes nothing (step 27)

Step 27 (todo §C.27) gives the page the **picker** for the two tables step 26 built. `stats/stats.tscn`
gains **1 Label + 2 Buttons** in the page's **left margin** - `x 0..15`, the only column of the 84 x 48
board that **no counter row uses** (measured: the counter rows start at `x 16` and the widest of
them, `L_5`, ends at `x 83`). The arrows are
`level_selector/digit_button.tscn` instances - the game's own widget - `LeftButton` with `frame = 12`
(`Frame_Left`) and `RightButton` with `frame = 13` (`Frame_Right`), NOT the Back glyph; the label is
`ModeLabel`, the **C / F** letter. The column reads **Reset / letter / Left / Right / Back** at
`y 0 / 10 / 19 / 29 / 40`. `stats.gd` gains `MODE_LETTERS = "CF"`, `mode_letter()`, the public seam
`show_mode(next)` = `wrapi(next, 0, MODE_COUNT)` + `update_labels()`, and the two `pressed` handlers,
connected **in the scene**. The page is now **11 children** (6 counter Labels + 1 mode Label + 4
Buttons). The switch **names no mode**: step 26's 3 mode lines stay the only place in the project that
names one, so what the arrows change is a VIEW. TEST O is **60 checks**; the suite prints **1260 PASS**
on the recorded seed (1200 before step 27), 0 FAIL, 0 script error, exit 0. The suite's **exit leak
count is not a gate**: the SAME tree printed no leak warning at all, 4, 6 and 8 leaked ObjectDB
instances across the runs recorded below (one run builds and frees fixture apps, pages and panels, many of them
several times), so a
2-instance swing from one fixture is not something this suite can measure - see harness fact 4.

- **O1 — the margin, 14 checks.** All 4 controls are `DigitButton`s (no new widget type, no Label-shaped
fake button); the arrows are `Frame_Left` / `Frame_Right` and each sprite shows the frame its export
asks for; Reset, the letter and both arrows sit fully inside 84 x 48; Back ends at `y 49` -
**pre-existing 1 px over the 48 px guide**, recorded so a later step cannot read it as step 27's; every
target is >= 9 x 9 board px = **>= 72 x 72 real px** at the 8 x scale (the 672 x 384 viewport); the
whole column stays in `x 0..15`; there is no vertical overlap (measured tops `[0, 10, 19, 29, 40]`,
ends `[9, 16, 28, 38, 49]`); **no counter row rect and the letter rect intersect any button** (the
todo's "no label is covered by a button", measured `[]`); the 6 counter rows did not move; every
`pressed` is connected **in the scene** to the page's own handler (measured handler names, in button
order); all 4 targets are `is_visible_in_tree()` - the engine's own input gate - and both arrows are
visible in **both** modes; the letter's rendered width fits its 9 px column at the game's 7 px font.
- **O2 — a flip browses, 11 checks.** `Right, Right, Left, Left` from classic walk modes `[1, 0, 1, 0]`
(it WRAPS, so no table is a dead end); in the press's OWN frame - before any `process_frame`, a Button
signal is synchronous - the 6 rows are the selected table's counters; 4 flips change **zero** counters;
the page stays OPEN; the `invoker` is untouched (the sentinel is the SUITE, see harness fact 4); a Right
press and `show_mode(MODE_NOBLE)` land on the same mode (the arrow IS the seam, not a parallel
implementation); 10 presses walk 10 steps; and `wrapi`'s upper bound is measured as EXCLUSIVE (harness
fact 1). Then the two checks a 2-mode page can only make by arithmetic:
**the ring** - from every mode `show_mode(m + 1)` and `show_mode(m - 1)` land on **the same** mode
(measured `[[0, 1, 1], [1, 0, 0]]`), so a Left/Right **swap in the handlers is behaviourally
invisible** at 2 modes, and the suite ran that sabotage: **1260 PASS, 0 FAIL, exit 0** (row S2 below);
and **the delta contract** - Right lands on `wrapi(m + 1)`, and a Left then returns to the mode the
pair started from (measured from every mode). The contract is pinned NOW because it is the only thing
the swap can break, and it breaks it the day `MODE_COUNT` grows past 2: at 3 modes a swapped pair stops
walking the page in order. Directional honesty at 2 modes therefore rests on the GLYPHS O1 pins.
- **O3 — the letter, 9 checks.** `"C"` / `"F"`, 1 character each, uppercase, `is_visible_in_tree()` in
both modes, equal to `MODE_LETTERS[mode]` (DERIVED, never stored beside the mode, so it cannot drift),
in every mode the 6 rows ARE that mode's table, the two modes print measurably DIFFERENT pages, and C/F
are never letters the counter rows already print (`[H, 1, 2, 3, 4, 5]`) - the margin cannot be read as
a 7th level row.
- **O4 — reset follows the visible table, 8 checks.** Reached through the page's OWN arrows: arrow to
NOBLE -> Reset zeroes the noble table, the classic history survives elementwise (100..113), the player
stays on F with the zeros printed; arrow back to classic -> the classic counters are intact; Reset
there zeroes classic; the noble zeros stay zeroed. Step 26's rule is only usable once a player can stand
in front of the table he means to clear.
- **O5 — the app re-pins, 13 checks.** The start page opens on classic; the page's own arrow reaches the
NOBLE table with NO game running (the step-27 gate) and its rows ARE the noble table; the page's Back
closes it and returns to `invoker`; a closed page KEEPS the browsed mode (a view, not a game state);
re-opening from the start page RE-PINS to classic; `start_game()` pins the running game's mode; the
pause page opens on F; mid-game the player CAN flip to the other history and reads the classic counters;
the pause opener re-pins to the running game's mode, so the only path that writes to the wrong table is
**flip + resume without reopening**; a flip NEVER changes `main.noble_family`; the switch is tappable
inside a running game's pause page.
- **O6 — the write target is the GAME, 6 checks (step 27's Check, FLIPPED by step 28).** Both tables are
zeroed for clean deltas, a variant 4p game runs on levels 2/3/2/3, the page is flipped to CLASSIC, and
the game is resumed WITHOUT reopening the page. Measured now: **`sum(noble) == round_won +
round_finished` emissions** and **`sum(classic) == 0`** — `_on_round_won` / `_on_round_finished` write
`tables[_main.noble_family_index()]`, so browsing moves a VIEW and not a number. Step 27's version of
this fixture measured the opposite (`sum(classic) == 6`, `sum(noble) == 0`) and said in its own text that
it is the Check step 28 flips; the flip is recorded here, not silently rewritten.

**Harness facts this step paid for (measured, not guessed):**

1. **`wrapi`'s upper bound is EXCLUSIVE.** `wrapi(1, 0, 1)` is **0**; `wrapi(1, 0, 2)` is **1**. The
first version of `show_mode()` wrapped over `MODE_COUNT - 1`, so EVERY press clamped to mode 0: the
arrows worked, the letter moved, and the NOBLE table was **UNREACHABLE** - the suite printed modes
`[0, 0, 0, 0]`, letters `["C", "C"]`, 14 FAILs. The suite keeps that fact as a check
(`O2 ... MEASURED, wrapi's UPPER bound is EXCLUSIVE`) so the next `wrapi` in this project is written
with an exclusive bound too.
2. **A `Signal.get_connections()` Dictionary's keys in Godot 4 are `["signal", "callable", "flags"]`** -
there is NO `"method"` key; the method name lives IN the Callable
(`(c as Dictionary)["method"]` is a runtime `Invalid access to property or key 'method'`).
3. **`check` text is data, not prose.** The 60 checks of TEST O print a measured value in almost every
line (`measured [14, 15, 12, 14]`, `measured []`, `sum(classic) == 6`), so a sabotage row above can
cite the check that fired without re-reading the code.
4. **The suite's exit leak count is NOISY, and a self-reference cycle is not measurable with it.** The
same tree printed no leak warning, 4, 6 and 8 leaked ObjectDB instances across the recorded runs. O2's
`invoker` sentinel is therefore the **SUITE** (`panel.invoker = self`) and not the panel for the reason
the harness states - `panel.invoker = panel` is a cycle, and a Node a cycle holds is never freed, so it
survives `queue_free` - not because a leak counter proved it. Do not read a 2-instance swing here as
evidence.
5. **A fixture's checks must read the state immediately after the action they measure.** Adding the ring
and contract block between the 10-press loop and its own check made the CLEAN baseline print
`1259 PASS / 1 FAIL`: the block's own presses (Right, Left from each mode) left the page on mode 1, and
the 10-press check then read the mode of the LAST block, not of its own loop. The bug was in the
fixture, not in the game - the block was moved after that check. A suite that reads state through a
shared, moving widget has to snapshot it where it is produced.
6. **A runtime script error aborts ONLY the fixture it fires in** - the suite carries on, so one broken
helper line prints a wall of downstream FAILs in the fixtures that follow it. The first run of TEST O
printed 14 FAILs whose only cause was the Dictionary line in fact 2, inside O1; reading them as 14
behaviour failures would have sent a step-27 implementation change after a bug in the harness.
7. A Label's rendered width comes from its `LabelSettings` (a `LabelSettings` is not a theme item, so
`get_theme_font_size` reports the 16 px default) - the same `_gm_text_w` helper TEST L uses.
8. TEST O runs **before** TEST M for the tail-of-stdout reason recorded under TEST N: the sections a run
must READ are never the last ones.

**The sabotages (each applied ALONE, suite run, then the exact bytes restored — `RESTORE_IDENTICAL`):**

| # | Sabotage | suite | FAILs | Caught by |
|---|---|---|---|---|
| S1 | `show_mode` clamps over `MODE_COUNT - 1` (the inclusive bound) | 1239 PASS | **14** | O2 (modes `[0, 0, 0, 0]`, 10-press walk), O3 x4 (letters `["C","C"]`, the rows, the two pages identical, `MODE_LETTERS`), O4 x6 (no route to the noble table, reset lands on the wrong table), O5 x3 |
| S2 | the arrows point the WRONG way (`_on_left_button_pressed` advances, `_on_right_...` goes back) | 1260 PASS | **0** | **nothing, and that is the finding** - at 2 modes `m + 1` and `m - 1` land on the same mode, so the swap has NO observable effect (the ring check documents it, the contract check documents it). The pair is pinned by O1's glyphs and by the contract, which a 3rd table makes testable |
| S3 | the letter is HARD-CODED (`mode_letter()` returns `"C"`) | 1254 PASS | **6** | O3 x2 (mode 1 prints C; the letter is not `MODE_LETTERS[mode]`), O4 x2 (no F to reset in; the player is not shown the table he cleared), O5 x2 (the start page's flip and the pause page open read C) |
| S4 | the flip changes `mode` and never refreshes the page (`update_labels()` dropped) | 1249 PASS | **11** | O2 (the rows in the press's frame), O3 x5 (letters, the rows per mode, the two pages identical, `MODE_LETTERS`, "the Label prints `mode_letter()`"), O4 x2, O5 x3 |
| S5 | the arrows are placed OVER the counter rows (`offset_left = 20 / 40` in the scene) | 1257 PASS | **3** | O1 x3 (target sizes, the `x 0..15` margin, and the coverage check measuring `["row2", ...]` - the todo's "no label is covered by a button") |
| S6 | a flip CLEARS the table it shows (`for i in 14: table()[i] = 0`) | 1256 PASS | **4** | O2 x2 (the rows of the mode entered; "4 flips changed ZERO counters"), O3 (the two pages identical), O4 (the classic history the player arrowed back to is gone) |
| S7 | Reset clears BOTH tables | 1256 PASS | **4** | O4 x2 (the classic history must survive a noble reset; arrowing back must show it) and **N4 x2** — the same sabotage caught from the data side and the page side |
| S8 | a flip CLOSES the page (`visible = false`) | 1258 PASS | **2** | O2 ("the page stayed OPEN through 4 flips"), O3 (`is_visible_in_tree()` in both modes, measured `[false, false]`) |
| S9 | the Right arrow is given the BACK glyph (`frame = 14`) | 1259 PASS | **1** | O1 ("measured `[14, 15, 12, 14]`") |
| S10 | the app's page close pins the mode (`_on_stats_back_pressed` sets `mode = MODE_CLASSIC`) | 1259 PASS | **1** | O5 ("a CLOSED page keeps the mode the player last browsed") |

A clean tree prints **1260 PASS, 0 FAIL, exit 0** (BASE above: two runs, both 1260 PASS).

**Not covered by this step (deliberately):** the WRITE target is the GAME (O6 measured the hazard, step 28
closed it - see TEST P) and the save is 2 keys with the 12-counter migration. Both landed in step 28;
TEST P is the fixture, O6 and N6 are the two checks that flipped.

### TEST P — the SAVE is 2 keys, a round's counters follow the GAME, and an old save migrates (step 28)

Step 28 (todo §C.28) closes the two hazards steps 26 and 27 left open. In the product code it is small:
`main/main.gd` gains **`noble_family_index() -> int`** (`Stats.MODE_NOBLE if noble_family else
Stats.MODE_CLASSIC`, 3 lines + 1 doc line), and `application/application.gd` stops naming a table
itself — `_on_round_won` / `_on_round_finished` write `_stats.tables[_main.noble_family_index()]`,
`save_config()` writes **both** tables (`Stats/classic` + `Stats/noble_family`) and **stops** writing
`Gameplay/totals_and_wins`, and a new `load_stats()` reads the 2 keys, **migrates** the pre-variant key
into the classic table when the new keys are absent, pads the ONE length the old format had, normalizes
what it loads to `Array[int]` (a `ConfigFile` returns `Array`), and applies the size rule
**per table**. TEST P is **66 checks** in 5 fixtures; the same run also carries **O6 flipped** (5 checks
→ 6, the Check step 27 said would flip) and **N6 re-measured** (11 checks, now the migration + drop
fixture, its "noble is zeros" check rewritten as a delta). A clean tree prints **1327 PASS, 0 FAIL, 0
script error, exit 0** (1260 at step 27: 66 + 1 = 67 new checks). TEST P runs **between TEST O and TEST
N**: P DELETES and REWRITES `user://options.cfg`, and N6 reads that file at the start of N's tail, so
the section that mutates the file can never sit after the section that reads it.

- **P1 — the 2 save keys + 2 games + 2 restarts, 24 checks (the todo's gate).** The save file is removed
so the app starts at a state the game knows (both tables zeros, the page printing `0 H 0`). A variant
game plays **2 round ends** on levels 4/4/3/2: the file grows BOTH keys, `Stats/noble_family` equals the
live noble table (`[0, 0, 0, 0, 1, 2, 1, 2, 0, 4, 0, 0, 0, 0]`), `Stats/classic` equals the live classic
table **which is still zeros**, the noble sum is **10 == 2 `round_won` + 8 `round_finished` emissions**,
and the save writes **no** legacy key. Mid-game the player peeks at the CLASSIC table through the page's
own arrow: the index stays NOBLE, and the table he was looking at is **still zeros** — browsing moves a
view. Then the **first restart**: a brand new app reads the file the variant game left, the classic table
is the saved classic history and the noble table is the saved variant history, and a page with no game
running opens on CLASSIC (the mode is picked per game, never persisted). A **classic** game of 2 round
ends in that fresh app: the classic key converges to the live classic table
(`[0, 0, 0, 0, 0, 2, 1, 2, 2, 4, 0, 0, 0, 0]`, **11 == 3 + 8** emissions), the noble table and key are
**exactly** what the variant game left (sum 10 == 10), the file is a file the suite's **own copy of the
load rules** reads back as the same two tables, `Stats` holds EXACTLY `["classic", "noble_family"]`, and
`Gameplay` keeps its speed key with no stats key beside it. The **second restart** reads the file back
unchanged — 2 games, 2 modes, 2 restarts, the 2 tables never mixed.
- **P2 — the migration, 17 checks.** A 12-counter `Gameplay/totals_and_wins` file lands in the CLASSIC
table at the SAME indices padded with the slots it never had (`[100 … 111, 0, 0]`) and the NOBLE table
opens at **zeros** (writing the legacy numbers to both tables would invent 1266 variant counters out of
a file that never mentioned a variant game); the live tables equal the suite's own copy of the rules;
the page **shows** the migrated numbers (`100 H 101`) in the pre-variant pair format; Human's pair stays
on slots 0/1; Level_5's pair stays on 10/11; the padded slots are the **Disabled** pair, the only pair a
12-counter file had no place for. A 14-counter legacy save is the classic table **unchanged**
(`[200 … 213]`) — the right length already, no padding. With BOTH new keys present the legacy key is
**IGNORED** (new keys win: 7s and 9s), because migrating on every boot would double-count. A 5-counter
legacy save is **dropped to zeros** — padding is defined for the ONE length the old format had, not for
any length.
- **P3 — the size rule is per table, 9 checks.** A 3-counter `Stats/classic` drops to zeros (the rule is
`2 * Player.AI_Level.size()` == 14, the pre-variant rule) **and the NOBLE table of the same file
survives** (`[50 … 63]`); a one-table loader drops both, which deletes a healthy variant history
because a classic record is corrupt. The page opens on the dropped zeros, one flip shows the survivor.
The mirror case (bad noble, good classic) is checked in the same fixture: the drop is per table in
**both** directions, so no table's fate depends on the other's.
- **P4 — a classic game files classic, 9 checks (O6's mirror).** The running classic game's index is 0;
opening the page mid-game pins the view to the classic table; the player then flips to NOBLE **while the
classic game runs** and the index does not follow the page; the round ends put **10 counters in the
classic table for 2 `round_won` + 8 `round_finished` = 10** emissions, and the NOBLE table — the table
the player was LOOKING at when those rounds ended — **took nothing**; the file agrees with the table it
is saved from.
- **P5 — the key names and the mode→index key, 7 checks.** The section/key/legacy-pair strings the game
writes are the strings the suite reads (a rename on either side strands a player's history),
`noble_family_index()` is 0 for a classic game and 1 for a variant game — **the mode flag IS the table
index**, so the write path needs no third source of truth — and the width a key has to hold is measured
on the running app's own page (2 tables × 14 counters).

**Harness facts this step paid for (measured, not guessed):**

1. **`ConfigFile` has ONE presence method in Godot 4.7.2: `has_section_key(section, key)`.** The first
version of P's reader called `has_value`, which does not exist; the replacement, `is_section_key_present`
(the name Godot 4 documentation uses for `ConfigFile`'s siblings), does not exist either. Dumping the
methods of a real `ConfigFile` measured `has_section_key` present and `has_value`, `has_key`,
`is_key_present`, `is_section_key_present` ABSENT. A call through a `Variant`-typed base is a runtime
error, not a compile error, so `--check-only` stayed green across both bugs and the suite printed 15-16
FAILs whose only cause was one helper line (harness fact 6 of TEST O, again).
2. **A fixture with per-mode counters must poll per-mode counters.** `_run_menu_rounds()` — TEST M's
driver — polls `_st_won`, the suite-wide list the shared `_on_round_won` handler feeds. P counts in
`_st_pw_won[mode]`, so its first call returned instantly on the PREVIOUS fixture's leftovers and drove
no rounds at all (measured: "0 of 2 after 5 driven round(s)"). P's driver polls `_st_pw_won[mode]` and
connects its own handlers to the app's own `_main` (`round_won` / `round_finished` — the counters are
counted on signals).
3. **A SECOND game in the SAME app dies on `Main.resolve_effect`'s "Player N has 1 card" assertion** the
first time the classic target modal resolves with `type Unknown` (measured in the log:
`resolve_effect for Guard, player 2, type Unknown` → assertion → the game's coroutine is dead → 0 round
ends in 4000 frames). It reproduces with step 28's changes REVERTED, so it is a pre-existing landmine of
the raw-app harness: TEST M's post-exit classic game never walks into it because it counts PLAYS and
never waits for a round end. A fixture that needs ROUND ENDS from a second game needs a fresh app, and
that is what P1's restart chain does for a reason, not by style.
4. **`save_config()` has exactly ONE caller in the game** — `save_stats.emit()` at `main/main.gd:879`
(main.gd mentions `save_stats` twice: the signal declaration and that emit). So a round end is the only
thing that writes the file, and a fixture can only poll a file a round end wrote.
5. **A long poll burns the very counters it is measuring.** At `_speed = 0` a settled deal plays a full
round in tens of frames, so a 2500-frame convergence poll let the live table drift past the harness's
own tally (measured: the file reached the tables, the sums did not match the emissions). P's convergence
budget is **600 frames**.
6. **`Disabled` maps to `2 * -1 == -2`**, which in Godot's negative indexing is the table's TAIL — which
is exactly where the migrated 12-counter file's two padded slots are, and the fixture names that
coincidence (`P2 … the padded slots are the Disabled pair`).

**The sabotages (each applied ALONE to the pristine tree, suite run, then the exact bytes restored —
md5-checked, no `RESTORE MISMATCH`):**

| # | Sabotage | suite | FAILs | Caught by |
|---|---|---|---|---|
| S1 | the counters ignore the game and always file CLASSIC (`tables[Stats.MODE_CLASSIC]`) | 1319 PASS | **8** | O6 ×3 (a variant game's round ends land in classic), P1 ×5 (the noble key/table, the sums, the restart pair) |
| S2 | the save writes ONLY `Stats/classic` (the "one table per save" format) | 1319 PASS | **11** | P1 ×8 (the both-keys check, the noble key, the restart chain, the key list), N6 ×2, P4 ×1 |
| S3 | the loader IGNORES the pre-variant key (no migration) | 1321 PASS | **6** | P2 ×6 (the migrated indices, the padded slots, the page, the suite's own copy of the rules) |
| S4 | the migration pads at the HEAD (`[0, 0, 100 … 111]`) | 1321 PASS | **6** | P2 ×6 (Human's pair moves to slots 2/3, Level_5 to 12/13, the page, the rules copy) |
| S5 | the size rule drops BOTH tables when ONE is stale | 1318 PASS | **9** | P3 ×3 (the survivor must live), P2 ×6 (a 5-counter legacy file drops the healthy noble table too) |
| S6 | the mode → table MAPPING is swapped | 1309 PASS | **18** | N6 ×3, O6 ×4, P1 ×5, P4 ×4, P5 ×2 — every side of the step notices |

**Not covered by this step (deliberately):** the save has no per-mode RESET separation to test beyond
step 27's O4 (Reset clears the VISIBLE table, which is now also the game's table while a game runs), and
the stats page cannot be opened on the mode a game will be played in from the MODE PICKER — `start_game()`
pins it, which TEST N7 covers. Steps 29 (Noble Family help lines) and 30 (Noble Family smoke suite) are
the next sections.

### TEST Q — the NOBLE FAMILY Help pages: 21 in the scene, 17 in a classic game, the Setup page prints the deal table (step 29)

Step 29 (todo §C.29) puts the variant's rules where a player can read them. In the product code it is
4 scene pages + 2 app lines + a filter in the page: `help/card_help_page.gd` gains **`@export var
variant_only: bool = false`** (an editor-set tag on the page widget, carrying no behaviour of its own),
`help/help.tscn` gains **4 pages** — `Family Setup`, `Family Turn`, `Family Out`, `Family Ends` — as
instances of the game's own page widget with `show_card = false`, in ONE block after `Game End`
(index 8) and before `Guard` (index 13), and `help/help.gd` gains **`variant_active`** (a property
SETTER that repaints), **`reachable_pages()`** and **`is_reachable(i)`**; `update_pages()` hides a
`variant_only` page when the flag is false, puts the arrows at the ends of the FILTERED list, and
clamps a page index that fell out of that list to the NEAREST reachable page (never to 0, never to a
hidden index). `application/application.gd` pins the flag on **every open** from `Main.noble_family` —
`_on_start_help_pressed` and `_on_pause_help_pressed` each set it, so no opener can forget it. TEST Q is
**85 checks** in 6 fixtures (Q1 10, Q2 15, Q3 11, Q4 13, Q5 15, Q6 21); a clean tree prints **1412
PASS, 0 FAIL, 0 script error, exit 0** in 66 s (1327 at step 28 — Q's 85 are the whole delta). Q runs
**between TEST P and TEST N**: P has already restored `user://options.cfg` by then, and Q opens the real
app (2 real games), which is the same reason TEST N and TEST O run before TEST M (the tail-of-stdout
rule).

- **Q1 — the scene, 10 checks.** The Help scene holds **21 pages == 17 + 4**, the 4 in one block at
  indices **[9, 10, 11, 12]** in the todo's order, every page name UNIQUE, all 4 variant pages carry
  `variant_only == true` and **no** classic page carries it (0 of 17). Every page is the game's ONE page
  widget (Card sprite + Name + Description, 3 children); the 4 variant pages carry **no card art**
  (`show_card == false`, the sprite hidden, `card_type == Unknown`) while the 8 card pages keep theirs;
  every page's Name Label reads its `card_name` and every Description Label carries >= 30 chars. The
  Help root is 4 children (2 arrows + Back row + the page list) — step 29 added NO widget, NO panel and
  NO third button, only pages.
- **Q2 — classic mode, 15 checks.** A panel at `_ready()` is in CLASSIC mode (the flag defaults false,
  so the Start page's Help shows classic rules **by default, not by a call every opener must
  remember**). **17 of 21** pages are reachable, and they are the pre-variant list **by name and in
  order** — `About … Game End`, `Guard … Princess` — so step 29 ADDS pages, it removes, renames and
  reorders nothing. Each of the 4 variant pages is checked UNREACHABLE by name. The page that opens is
  the FIRST classic page; the Left arrow is hidden there and `is_visible_in_tree()`-false (the ring has
  a front end, it is not a carousel). A 21-press right-sweep, sampled AFTER each press, visits the 17
  classic pages in scene order and **skips the 4 variant ones**; every sampled frame shows EXACTLY ONE
  page; and the last 5 presses at the last page moved NOTHING (no wrap — the pre-variant guard survives
  the filtering). The classic ring's last reachable page is the scene's LAST index (20): the variant
  block sits INSIDE the list, it does not extend it.
- **Q3 — variant mode, 11 checks.** With the flag on, **21 of 21** pages are reachable; a 20-press sweep
  visits every page in scene order, the 4 variant pages between `Game End` and `Guard`, each shown
  EXACTLY ONCE (`[1, 1, 1, 1]` — a page shown twice is a page list built twice, a page never shown is a
  rule the variant player cannot read), and each variant page's own Name and Description Labels are ON
  SCREEN when the ring reaches it. Parked on `Guard` (13) and pressing Left lands on `Family Ends` (12),
  NOT on `Game End`: the arrows walk the SAME filtered list in both directions.
- **Q4 — the mode switch WHILE A PAGE IS OPEN, 13 checks** (the todo's "paging never lands on a hidden
  page", which is the failure mode a filter creates). Parked on the last variant page (12), switching to
  classic CLAMPS the cursor to **8 == `Game End`**, the nearest reachable page below — not to 0 (a page
  the player never asked for), not left at 12 (an index with nothing on screen) — and the clamped page is
  ON SCREEN, exactly one, with BOTH arrows tappable (a clamp into a page with no way out is a dead end
  the player escapes only by Back). Clamped from the MIDDLE of the block (index 10) lands on 8 too, so
  the rule is "the nearest reachable page below", not a rule that knows the block's ends. Switching
  modes when the page is reachable in both modes moves NOTHING (2 clamp-free switches, 0 moves): the
  filter is not a page reset (step 27's stats rule). In classic mode Right from `Game End` skips the 4
  hidden pages to `Guard` (13) and Left from `Guard` skips them back to 8 — at EVERY press, not only at
  the open; the same press with the flag on steps into `Family Setup` (9).
- **Q5 — the text IS the deal table, 15 checks.** The Setup page's 3 numeric rows are read **per clause**
  and compared with values **derived from the code that deals**: "Set aside …" must print
  `Deck.NOBLE_BURN` per seat `[3, 1, 0]`, "family …" must print `Deck.NOBLE_FAMILY_SIZE` per seat
  `[5, 4, 3]`, and "main pile …" must print `16 - burn - one first-hand card per seat - family * seats
  == [1, 0, 0]`. The triple ENDS in 0 — 4p burns nothing, which is why 4p has no widow pile at all — and
  the page states the ONE first-hand card ("Hand 1"). The 4 pages' word gates are the todo's 4 rule
  statements: Setup says *hand / family / set aside*, Turn says *private / draw from it / 1 of 2 /
  prince / widow*, Out says *reveals / hand and family / leaves play / no one*, Ends says *round ends /
  no family card left*. Geometry is measured on the Labels the scene ships, derived from the arrows' own
  rects: the 4 variant pages print 4 / 5 / 5 / 4 lines ending at y **36 / 42 / 42 / 36**, inside the
  Description rect that ends at y 44; every page's text ENDS on the 48 px board (6 lines of the game's
  6 px line height below y 12 is the most a page can print at all); and every page name fits the **52
  px** the arrows leave it — the arrows own x 15..24 and 75..84 and the name row is y 2..8, so
  **`Family Round End` (64 px) does not fit** and the page is named `Family Ends`. MEASURED and LEFT
  ALONE: 5 pre-existing classic card pages (`Guard, Baron, Handmaid, Prince, Princess`) print a 6th line
  below their own 32 px Description rect (12 + 6 * 6 == 48 > 44), on the board, in the 4 px the page has
  under its label — step 29 touches no classic page, and the list of 5 is pinned so a later step cannot
  lose the fact silently.
- **Q6 — the app pins the pages to the GAME, 21 checks**, on the real app, in the order a player does it.
  At boot Help is in classic mode with 17 pages reachable, and the app's Help node IS the Help scene (its
  own page list and filter, not a copy). A NOBLE FAMILY game runs (family `[3, 3, 3, 3]`); its **Pause
  Help opens in VARIANT mode with all 21 pages**, the 4 variant pages in the list, the opened page
  showing ONE page. The player reads through to the last variant page (12) and presses Help's Back: the
  page closes and the PAUSE page is back (the invoker rule the classic Help already has), and a CLOSED
  page KEEPS its view (12) — the clamp belongs to the OPEN, where the mode is known, not to a hidden
  page. Exit-to-menu clears the mode, and the player goes STRAIGHT into a classic game — **no Start-page
  Help in between, so nothing else can reset the flag**: this second Help open is in classic mode with 17
  pages, and it OPENED clamped (the player closed the variant page on `Family Ends`, 12, and the open put
  him on `Game End`, 8). The SCENE still holds all 21 pages in a classic game — a variant page is HIDDEN,
  never deleted, so no mode needs a rebuild — and Back returns to the PAUSE page of the classic game.
  Exit again: the START page's Help is in classic mode with 17 pages (the todo's first Check, measured on
  the app's own page list), showing ONE page, clamped from index 8, which is reachable in both modes, so
  this open moved nothing; Back returns to START.

**Harness facts this step paid for (measured, not guessed):**

1. **`Array.reverse()` mutates in place and returns `null`.** The left-arrow neighbour search first read
   `for i in reach.reverse()`; the loop iterated over `null` and the arrow silently stopped working (Q3's
   "Left from 'Guard' lands on 'Family Ends'" caught it). The current code copies the list, then reverses.
2. **`Control.get_rect()` is positioned at the control's OFFSETS, not at its origin.** A first version of
   Q5 asked the Description label's rect whether it `has_point((0, y))`; the rect starts at (1, 12), so
   the point is outside for **all 21 pages** — a gate that fails the whole tree is a gate about the gate.
   The check compares the rect's END (`end.y == 44`) with the text's bottom (`12 + lines * 6`).
3. **A paging sample must be taken AFTER the press.** Sampling before each press and then prepending the
   page the Help opened on produced `["About", "About", "Deck", …]` — the first page twice, every
   expected list shifted by one. Q2/Q3 press first, so the samples are the pages the presses LANDED on.
4. **Digit matching has to be CLAUSE-scoped, not a run anywhere in the page.** A first version asked
   "does the page's digit list contain the run 3 / 1 / 0?"; sabotage S5 (the burn row typed `4 / 1 / 0`)
   printed **0 FAILs**, because the page still contains a `3, 1, 0` run across the family row and the
   main-pile row. The check now reads the triple that FOLLOWS each clause keyword, so the burn row is
   compared with the burn row (S5 → 1 FAIL).
5. **`is_visible_in_tree()` is the engine's own gate, and the paging evidence is "exactly one page
   visible in this frame".** The Help root is `visible = false` in `application.tscn`, so a fixture that
   measures the app's Help has to press the app's own Help row first; a page whose parent is hidden shows
   NOTHING, which is the state the crowded-frame counter measures (0 visible pages counts as crowded,
   exactly like 2).
6. **`get_node()` is CASE-SENSITIVE** — `"leftButton"` is no node at all, and the crash is on the
   fixture's own line. The arrow helpers take `"Left"` / `"Right"`.
7. **A fixture that indexes a measured list crashes when a sabotage empties it.** S7 (the filter
   inverted) leaves 0 pages reachable in classic mode, so Q2's `rn[0]` line threw a script error
   alongside its 24 FAILs. The suite still fails loudly; a fixture line that indexes a measurement is a
   fixture that reports a crash instead of a message.
8. **A page whose label rect is too small is a MEASUREMENT, not a bug to fix in this step.** 5 classic
   card pages need 6 lines; their rect holds 5. Q5 pins the list of 5 names so a later step that re-flows
   them (or quietly accepts a 7th line) shows up as a change in the pinned list.

**The sabotages (each applied ALONE to the pristine tree, suite run, then the exact bytes restored —
md5-checked, no `RESTORE MISMATCH`; clean tree 1412 PASS, 0 FAIL, exit 0):**

| # | Sabotage | suite | FAILs | Caught by |
|---|---|---|---|---|
| S1 | every open passes a CONSTANT (`_help.variant_active = true` at both opens) — a classic game shows the variant rules | 1407 | **5** | Q6 ×5 (the classic Pause Help's mode and page count, the Start Help's mode, both clamped opens) |
| S2 | the PAUSE open forgets the flag (only the START open sets it) — a variant game's Pause Help shows 17 pages | 1406 | **6** | Q6 ×6 (the variant Pause Help's mode, all 21 pages, the variant page list, the page it ends on, the closed view, the clamped open) |
| S3 | the Right arrow steps the RAW child index (`_active_page + 1 < child_count`) | 1404 | **8** | Q2 ×5 (the classic sweep's order, the no-wrap tail, the hidden-arrow press), Q4 ×3 (Right from `Game End` lands on a hidden page, the block sweep) |
| S4 | `update_pages()` never clamps (`if not reach.has(_active_page)` → `if false`) | 1402 | **10** | Q4 ×9 (the clamp from 12, from the middle of the block, both arrows on the clamped page, the skip in both directions), Q6 ×1 (the app's clamped open) |
| S5 | the burn row typed `4 / 1 / 0` | 1411 | **1** | Q5 ×1 (the burn clause's triple == `Deck.NOBLE_BURN`) |
| S6 | the Setup page drops its family row | 1410 | **2** | Q5 ×2 (the family clause's triple, the page's digit list) |
| S7 | the filter is INVERTED (`variant_active and !variant_only`) — a variant game hides its own pages, a classic game shows all 21 | 1380 | **24** | Q2 ×2, Q3 ×4, Q4 ×10, Q6 ×8 (+1 fixture script error, harness fact 7) |
| S8 | one page untagged (`Family Out`, `variant_only = false`) | 1392 | **20** | Q1 ×1 (the tag count), Q2 ×6 (its own unreachability, the sweep, the tail), Q4 ×9, Q6 ×4 |
| S9 | the round-end line tests the WHOLE table ("when no player has a family card") | 1410 | **2** | Q5 ×2 (the word gate, the 4 pages' line geometry) |
| S10 | the page is named `Family Round End` (the todo's name, 64 px) | 1410 | **2** | Q5 ×2 (the 52 px the arrows leave a name, the printed Name Label) |
| S12 | card art on a variant page (`show_card = true` on `Family Setup`) | 1411 | **1** | Q1 ×1 (a rules page must hide its sprite) |
| S14 | the Pause open sets the flag only when a variant game runs (`if _main.noble_family: true`) — the flag goes STALE across a mode change | 1409 | **3** | Q6 ×3 (the classic Pause Help opened right after a variant game's Help, its page count, its clamped open) |
| S13 / S11 / S15 | the START open sets the flag only when true; the START open forgets it; the LEFT arrow steps the raw child index | **1412** | **0** | **NOT CAUGHT, AND THAT IS THE MEASUREMENT.** At the Start page `Main.noble_family` is ALWAYS false (boot is false and step 25's Exit-to-menu clears it), so "set it to the mode", "set it only when true" and "do not set it at all" are three implementations of the same observable behaviour, and the suite's 17-pages-in-classic checks pass on all three. For the left arrow, `update_pages()` clamps every move, so a raw index and a filtered scan land on the same page in every reachable configuration. Two of Q6's 21 checks exist precisely to make the Start open's behaviour observable; a Start-page open that runs while a variant game is active is not reachable in the product, so no check can distinguish it. |

**Not covered by this step (deliberately):** the Help text is measured, not proofread (Q5 gates the
numbers, the todo's rule words and the geometry, not style); the app fixtures run the 4-player
configuration (the Setup page's numbers are checked from the per-seat deal constants, which cover
2 / 3 / 4 players); the family-stack display strip gets NO Help page (it is display-only, step 18, and
the todo asks for 4 pages, not 5); and `variant_only` is a page tag, so a hypothetical FUTURE variant
would need its own tag semantics — the todo names one variant, and Q1 pins the tag count on both sides
(4 tagged, 17 untagged) so that change cannot happen quietly. Step 30 (the Noble Family smoke suite) is
the next section.

## tests/noble_family_smoke.tscn — Noble Family variant, whole games on the AI (steps 7, 11, 14)

Variant games (`main.noble_family = true`) with every seat on the AI (levels 4/4/3/2), animations
at speed 0, audio muted: the "the variant plays and terminates" check, the twin of
`tests/smoke_games.tscn` for the classic path.

    godot --headless --path . tests/noble_family_smoke.tscn                        # 4 players
    godot --headless --path . tests/noble_family_smoke.tscn -- --players=3 --rounds=40
    godot --headless --path . tests/noble_family_smoke.tscn -- --seed=999         # other deal/RNG
    godot --headless --path . tests/noble_family_smoke.tscn -- --levels=1234      # one seat per AI level
    godot --headless --path . tests/noble_family_smoke.tscn -- --seed=777 --log=1 > run.log
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

**Determinism (as step 11 measured it, superseded by the log below):** two runs of
`--players=4 --rounds=20` on the default seed print
byte-identical play logs (506 `new_turn` / `resolve_effect` / effect lines each); the same suite
with `--seed=999` prints a different log (489 lines) - level 1's `valid_moves[0]` is deterministic,
level 2's uniform pick is not. `--print_moves=1` dumps every enumerated move; in a 4p variant game
every line carries its draw, e.g. `Move score 20: Baron (0), draw King (#2), keep King, tgt 0`, and
a Baron turn on family `[Prince, Guard, King]` prints 37 moves (7 + 24 + 6).

### Step 12 — the AI draw policies: every joint move legal, every level measured

The paragraph above counted raw dump lines. Step 12 makes the claim about the **decisions**, plus a
per-level legality rail, so the suite adds two things:

**`--levels=` (one digit per seat, 1..5).** The default mix is `4432`; the suite now runs any mix, so
the gate "levels 1-4 all play legal joint moves" is checked in real variant games with every level
on the board (`--levels=1234`), not only in the hand-built list of rules TEST B. Level 5 (the random
mix of 1-4) is accepted too.

**`--log=1` — one line per play:** `LOG  r<round> s<seat> lvl<level> <Move>` (the `Move` line names
the played card, the family card it drew, the card it kept, the target and the Guard's declared type).
Nothing nondeterministic is in it - no timing, no board dumps. `Main._new_game()` seeds the global
RNG per game (`seed(_random_seed)`), so a fixed seed is a **reproducible run**.

**The joint-move legality rail** (`check_joint_move`, on the seat's own `move_chosen`): it runs at
the moment the seat COMMITS its triple, which is *before* the chain animates the draw, so the family
data and the 1-card hand the harness reads are exactly the state the move was chosen from. Every
move is checked: it names a real family index and that slot's type; the played type is one of the
pair `(active, family[f])` and `_leftover_type` is the other one; the Countess rule is obeyed
(a Countess + man pair never plays the man); `_played_card` is the seat's hand node for an
active-card play (`_played_card_idx == 0`) and **null** for a drawn-card play; the hand holds
exactly 1 card; the target follows the type rules. The suite counts every move that passes, per
AI level, and fails on any violation, on 0 checks, or on a configured level that made no play.

The target rule the rail enforces is stated from the rules, **not** read from `Main._other_protected`
- a rail that reads the enumerator's own flag agrees with a buggy enumerator. The rule is: naming a
protected opponent is legal only when every other active seat is protected (Handmaid's edge case).
The first version of this rail inverted that and reported 1 "illegal" move per 6-round run - the
move was legal, the rail was wrong. A legality rail has to be able to disagree with production.

Measured (40 rounds unless stated, seed as stated, every run prints `plays == joint moves verified
legal` - the rail found 0 illegal moves):

| run | seed | levels | plays | by level | family-out ends | exit |
|---|---|---|---|---|---|---|
| 4p canonical mix | 20260607 | `4432` | 326 | L4 166, L3 89, L2 71 | 2 | 0 |
| 4p, one seat per level | 20260607 | `1234` | 330 | L1 79, L2 77, L3 91, L4 83 | 1 | 0 |
| 4p, same levels, shuffled seats | 555 | `4321` | 336 | L1 78, L2 80, L3 87, L4 91 | 1 | 0 |
| 4p, same levels, other seed | 999 | `1234` | 325 | L1 78, L2 72, L3 81, L4 94 | 1 | 0 |
| 4p, all level 1 | 20260607 | `1111` | 335 | L1 335 | 3 | 0 |
| 4p, all level 1 | 777 | `1111` | 302 | L1 302 | 0 | **1** (the family-out gate, see the note) |
| 4p, all level 1, **120 rounds** | 777 | `1111` | 945 | L1 945 | 3 | 0 |
| 4p, all level 2 | 20260607 | `2222` | 314 | L2 314 | 3 | 0 |
| 4p, all level 2, other seed | 777 | `2222` | 319 | L2 319 | 3 | 0 |
| 4p, level 5 (random mix) + 4 | 777 | `5454` | 335 | L5 169, L4 166 | 3 | 0 |
| 3p, one seat per level | 20260607 | `123` | 283 | L1 88, L2 89, L3 106 | 1 | 0 |
| 3p, all level 1 | 777 | `111` | 260 | L1 260 | 2 | 0 |
| 2p, levels 1 + 4 | 20260607 | `14` | 166 | L1 80, L4 86 | 3 | 0 |
| 2p, levels 1 + 4, other seed | 999 | `14` | 149 | L1 73, L4 76 | 2 | 0 |
| 2p, all level 1 | 777 | `11` | 126 | L1 126 | 4 | 0 |

**Log comparisons (the determinism gate).**

| pair | result |
|---|---|
| `1234` seed 20260607, run twice | **byte-identical** (330 lines) |
| `1111` seed 20260607, run twice | **byte-identical** (335 lines) |
| `11` seed 777 (2p), run twice | **byte-identical** (126 lines) |
| `1234` seed 20260607 vs seed 999 | **differ** |
| `1111` seed 20260607 vs seed 777 | **differ** |
| `2222` seed 20260607 vs seed 777 | **differ** |
| `1111` vs `2222`, **same** seed 20260607 | **differ** — the deals are identical, only the policy differs |

So a run is reproducible, a seed changes the game, and the **policy** changes the plays on a fixed
deal. Level 1's fingerprint is exactly the todo's promise: **every one of its 335 plays draws family
index `#0`** and plays the active card (`_played_card_idx == 0` in 78 of its 79 plays in the `1234`
run - the 1 exception is the Countess forcing the drawn Countess). Levels 2/3/4 spread over all
family indices (e.g. L2 `42/26/9` over `#0/#1/#2`) and play the drawn card about as often as the
active one (`31/46` for L2, `44/47` for L3, `38/45` for L4): the drawn card is the *cheaper* half of
the pair in level 3's picks, which is what its policy is.

**The all-level-1 note:** with 4 seats and every seat on level 1, a 40-round run has 93 eliminations
and **no** family-out end, so it fails the suite's "at least 1 round ran to the family-out end"
gate. That is a property of the policy, not a stall: level 1 always takes family `#0`, which makes
seats open Prince/Baron fights early, so rounds end by elimination. `--rounds=120` reaches 3
family-out ends and exits 0; in 2p/3p the same policy produces family-out ends within 40 rounds.

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
