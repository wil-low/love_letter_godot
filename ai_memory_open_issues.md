AI level 4 - open issues in memory handling and move scoring
============================================================

Scope: `player/player.gd` (`eval_moves`, `select_move`), `main/main.gd` (effect resolution,
memory updates, and the reveal guards of section 6), `deck/deck.gd` (card accounting). Line
numbers are from the current working tree (after the Guard-memory fix of section 0 and the memory
fix of section 4; re-verified line by line).

Reproduction harness: `tests/repro_guard_princess.tscn`
(`godot --headless --path . tests/repro_guard_princess.tscn`), documented in `tests/README.md`.
Aggregate measurements come from `tests/prince_memory_sim.py` (and `tests/issue2_tiebreak_sim.py`
for the tie-break probe), decision-time state checks from `tests/repro_belief_truth.tscn`. The
section 6 measurements (Priest broadcast policies `fix_plus_bc` / `bc_vs_human`, scoring policy
`denied`) come from instrumented copies of `tests/prince_memory_sim.py` that are not in the repo,
as in section 3; the numbers below are the record.

Legend: severity H = plays a move a human would call irrational, M = loses information /
misses opportunities, L = latent, only reachable in specific states.


0. Background: the belief model and the fixed issue
---------------------------------------------------

Each player keeps `_memory: Array[Deck.CardType]` of length 4 (`player.gd:58`). The intended
invariant is

> `_memory[i][j] = T` means "player i believes player j's single card in hand is T",
> and `Unknown` means "no belief".

Writes are made in `main.gd`: Priest reveal (`:322-325`), Baron tie (`:339-340`), Baron tie
propagation to third parties (`:341-346`), King trade (`:385-392`). Clears are made when a
card is played (`main.gd:215-217`, clears only if the belief pointed at the played card),
in the Prince branch (`main.gd:363-364`) and in `set_inactive` (`main.gd:290-291`). All beliefs
are wiped at the start of a round (`main.gd:129-130`).

The deck contains exactly one Princess (`deck.gd:card_count`), so a belief "player j holds
the Princess" is *provably false* as soon as the believer itself holds the Princess - and,
because every writer above is a read of a real card, that combination never occurs in play
(section 1).

Fixed (this working tree): `eval_moves` Guard branch

```gdscript
# before
if mem != Deck.CardType.Unknown:
# after
if mem != Deck.CardType.Unknown and mem != Deck.CardType.Guard:
```

`find_valid_moves` generates Guard guesses only for `range(Deck.CardType.Priest,
Deck.CardType.Unknown)` (`main.gd:512`), i.e. Guard is not a guessable type. A memory of
Guard therefore can never satisfy `mem == m._target_type`; treating it as "known" disabled
the card-count heuristic, scored every legal move 0, and handed the decision to the
zero-score fallback - which is the Princess declaration reported by players. Verified by
`Test B`: the same turn now scores `sum = 40` with `Princess = 0` and the AI picks
Baron/Handmaid/Prince.

The issues below are what remains - section 4 is fixed (the fix and its tests are recorded
there), sections 1, 2 and 3 are closed as not an issue (1: the state its scoring rests on has no
construction path once section 4 landed, and the guardrail it drafted is unreachable code; 2: the
tie-break arbitrates moves the scoring table has already judged worthless; 62% of the time there is
nothing to arbitrate, and the deterministic pick is the best of the three; 3: it rested on a false
premise - `Deck.CardType.Unknown` is 8, not 0, so the score is 400, not 0, and is downgraded to L),
section 5 turned out to be the model working as designed, and section 6 is new and open: the
disclosure model - who the rules entitle to see which reveal - found while proving the invariant
that closes section 1.


1. The Guard memory branch has no deck-accounting guardrail (severity L, was H)
   NOT AN ISSUE
---------------------------------------------------------------------------------

**Verdict: the mechanism is exactly the code the old section quotes; the state it scores is
unreachable.** With section 4's fix in place, measured over 60 000 rounds (20 000 x 3 player
counts, `tests/prince_memory_sim.py`, memory policy `fix_plus` = the applied fix) and 13 917 real
level 4 decisions in the engine (`tests/repro_belief_truth.tscn`): **0** beliefs that do not name
the rival's real hand card, **0** memory-driven Guard guesses naming a type that cannot be
anywhere, **0** Baron plays scored on a false belief, **0** Prince plays wasted on a believed
Princess. The `left <= 0` guardrail drafted here is unreachable code, and the scoring rewrite that
came with it measures as a small loss (Guard hit rate 24.37 -> 24.18 in four-player games, win
rate inside Monte-Carlo noise). Design decision recorded here: **no change to `eval_moves`** - the
invariant that makes the memory branch safe is pinned by a test, not by a score.

The mechanism (`player.gd:226-235`, unchanged):

```gdscript
Deck.CardType.Guard:
    if mem != Deck.CardType.Unknown and mem != Deck.CardType.Guard:
        if mem == m._target_type:
            m._score = EvalScore.GOOD * m._target_type     # Princess: 50 * 7 = 350
    else:
        var left := left_cards[m._target_type]
        if hand.get_child(0).type == m._target_type:
            left -= 1
        if hand.get_child(1).type == m._target_type:
            left -= 1
        m._score = EvalScore.BAD * left
```

The memory branch never consults `left_cards`, so a belief naming a card that is out of play would
be paid `GOOD * rank` - 350 for the unique card, the greediest play the Guard branch makes. That
reading of the code is correct. What is not correct is the premise that such a belief exists.

Why the belief cannot exist
---------------------------

`_memory` is a seat's own array, and every writer is **sound** (it writes a card somebody has
read) *and* **entitled** (it writes it into a row whose owner is a party the rules grant that
view to). The second condition is the one section 6 is about; the entitlement argument per writer
is spelled out there (Priest: only the author is a party; Baron third parties: the tie is
deducible from the public outcome, not from the secret comparison; King third parties: the trade is
a public event). Read as "public information" the sentence below is loose in exactly those two
rows - it is the looseness that produced the first draft of section 6:

| writer | line | why the slot it writes is true |
|---|---|---|
| Priest reveal | `main.gd:325` | the Priest player writes the card he has just looked at |
| Baron tie | `:339-340` | a tie means both cards are equal, so each seat writes the other's real card |
| tie propagation to third parties | `:342-346` | deduction: a tie means the two hands are equal, so my true belief about one of them is a true belief about the other |
| King trade | `:385-392` | beliefs travel with the cards that are traded; third-party slots are swapped |
| a play of the believed type | `:217` | clears - section 4 item 3, the sound direction |
| a Prince on a target | `:364` | clears the slot that names the hand that changed |
| an elimination | `:291` | clears beliefs about the seat that left the round, and that seat's own array |
| a new round | `:129-130` | wipes everything |

No writer ever guesses: the only writes that *add* information are reads of a real card, and the
one write that is probabilistic (the type-matching play clear) goes in the conservative direction.
Hence:

> **Invariant (measured at every level 4 decision, `tests/repro_belief_truth.tscn`): every
> non-Unknown slot of `_memory` that names a live rival equals that rival's hand card.**

Two consequences, and they are the two ends of issue 1:

- `_memory[j] == Princess` with `j` live means the Princess is in `j`'s hand. The deck has exactly
  one Princess (`deck.gd:card_count`), so the deciding seat cannot be holding it. The state
  "I hold the Princess **and** I believe rival `j` holds the Princess" has no construction path.
- `_memory[j] == T` being true puts a copy of `T` in `j`'s hand, so `left_cards[T] >= 1` and
  `left_cards[T] - (my copies of T) >= 1`. The guardrail's condition (`left <= 0`) and the memory
  branch's condition (`mem == m._target_type`) are **mutually exclusive**: a true belief always
  names a type that still has a copy in play, which is the only case where the guardrail could
  have fired.

Measured over 20 000 rounds per cell, four players. The left column is the memory policy as it was
before section 4 (the state the old section was written against), the right column is the applied
fix; move scoring is the shipped one in both:

| metric | pre-fix (policy `shipped`) | now (policy `fix_plus`) |
|---|---|---|
| Guard guesses driven by a belief | 4 836 | 4 952 |
| ... the belief did not match the real card | 257 | **0** |
| ... the declared type cannot be anywhere else (`left - own <= 0`) | 207 | **0** |
| Baron plays scored by a belief / of them false | 1 012 / 97 | 942 / **0** |
| ... Baron self-eliminations caused by a false belief | 25 | **0** |
| Prince plays aimed at a believed Princess / wasted on nothing | 667 / 0 | 730 / **0** |
| beliefs about seats already out, visible at decision time | 8 149 | **0** |
| decisions declaring "Princess" while holding the Princess | 51 | 50 |
| ... of those, scored by the memory branch (the 350 play) | 0 | **0** |

2 players: 3 487 belief-driven guesses, 0 false, 0 impossible; 1 016 belief-scored Barons, 0 false;
0 declarations. 3 players: 5 641 / 0 / 0, 1 227 / 0, 28 declarations.

The engine test repeats the same checks inside the production scripts - `Player.move_chosen` fires
after `select_move` and before `_on_card_played`, so the hook sees the decision-time view (memory
as scored, hands as scored, `_deck._left` as scored): 1 500 four-player rounds, 4 x level 4,
13 917 decisions, 1 200 belief observations with **0** false, 387 belief-driven Guard guesses with
387 hits and **0** impossible, 101 belief-scored Barons with **0** false, 0 zombie slots, exit 0.
The default run is 500 rounds (~7 min; the cost is superlinear in rounds, so the test takes
`--rounds=N`): 4 666 decisions, 412 beliefs with **0** false, 118 belief-driven guesses with 118
hits and **0** impossible, 1 703 count-driven guesses with **1** impossible - a legal probe whose
0 comes from the count branch itself, which is section 5 item 1's case, not a missed play.
The two tools agree on rates: the sim's 4 952 belief-driven guesses per 20 000 rounds is 371 per
1 500 rounds, the engine counted 387.

The 50 declarations that remain are not issue 1's
-------------------------------------------------

50 per 20 000 four-player rounds (0.027% of 185 102 decisions) is the tail section 2 closed. The
AI holds the Princess, declares the Princess, and the count branch has *already* zeroed that guess:
`EvalScore.BAD * (left_cards[Princess] - 1) = 0`, because the copy the count includes is the one in
the AI's own hand. Measured directly on those 50 decisions: **0** are scored by the memory branch,
i.e. none is the 350-point play this section describes. They are all-zero turns, and
`valid_moves[-1]` is the last generated guess, which is the Princess guess. Issue 1's scoring
change does not remove them - it moves their count from 82 to 92 per 30 000 rounds
(`tests/issue2_tiebreak_sim.py`, `fixed13`).

Why Test A sees the state
-------------------------

`tests/repro_guard_princess.tscn` Test A writes the slot by hand (`p0.update_memory(1,
Deck.CardType.Princess)`) next to a Princess in P0's own hand. That state has no construction path;
the scenario is kept as the unit test of the scoring branch - it documents that the memory branch
pays `GOOD * 7 = 350` for a provably impossible call. Test B reaches the same hand through the real
King sequence, and it asserts the opposite of the old section's story:

    check(p0._memory[1] == Deck.CardType.Guard,
        "memory is NOT stale - King overwrote it with the rival's real card")

What the section leaves behind
------------------------------

- an **assert / comment**, not a fix. The Guard branch deserves the invariant written down ("a
  belief is a read of a real card, so a memory-driven guess is a certain hit; deck accounting is
  the job of the count branch"), and `eval_moves` deserves the non-negativity pin section 2 asks
  for. `tests/repro_belief_truth.tscn` is the regression net: it fails the first time a writer
  produces a belief that does not name the real card - which is the bug class this section
  describes, and section 4 is an instance of it (its pre-fix numbers are the non-zero column of
  the table above).
- the **pinned-copy accounting** - the legitimate half, and it is not about the memory branch at
  all: it is about the count branch, where `left_cards` includes copies the seat itself has pinned
  in *other* known hands, so a legal probe aimed at a third player can be a certain miss and still
  score `BAD * 1 = 5`. It belongs to section 5 item 1, with the in-game measurements recorded there
  (193 guesses per 20 000 four-player rounds are affected, ~1 per 100 rounds; the subtraction takes
  the Guard hit rate from 24.37% to 24.18% at a win rate indistinguishable from noise).
  Calibration, not repair.
- the drafted **ordering note and clamp are moot**: with `set_inactive` clearing in both directions
  (section 4), there are no zombie slots to steal a copy from the count (measured 0) and no
  Baron-tie cloning into a dead slot, so `max(0, left - pinned)` has nothing to clamp.
- the summary-table severity is now L. The H it carried belongs to section 4, where the same
  symptom (a guaranteed-failed belief-driven play, `GOOD * rank` paid for it) is measured, fixed
  and tested.

2. `return valid_moves[-1]`: a positional tie-break in states where every move scores 0
   (severity L, was H) - NOT AN ISSUE
----------------------------------------------------------------------------------------

**Verdict: the mechanism is exactly as the old section describes; the severity is not.** The
tie-break is arbitrary, the moves it arbitrates between are moves the scoring table has already
judged worthless, 62% of the time there is nothing to arbitrate, and measured over 30 000
four-player rounds the three candidate tie-breaks are one win rate. Design decision recorded
here: **keep `valid_moves[-1]`** - a deterministic tie-break keeps the repro tests
deterministic and the seeds paired, at no measured cost, and it is the best-performing of the
three.

Code (`player.gd:195-203`, unchanged):

```gdscript
if sum == 0:
    sum = 1
var rmove := randi() % sum
sum = 0
for m in valid_moves:
    sum += m._score
    if sum > rmove:
        return m
return valid_moves[-1]
```

and the generation order that gives it meaning (`main.gd:512-543`): the hand in child order
(the hand is never sorted, so a Guard is "last in hand" about as often as any other card),
inside a card, targets in player order, and for a Guard the guesses in enum order
`Priest .. Princess`.

When the fallback is reached - and only there
--------------------------------------------

`EvalScore.LOSE = 0` (`player.gd:209-215`) is the floor of the whole table and no branch of
`eval_moves` writes a negative number, so `sum == 0` means "every move scores 0" and nothing
else: `if sum == 0: sum = 1` is the guard that keeps `randi() % sum` from dividing by zero, and
`return valid_moves[-1]` is unreachable from any other path. Measured over 277 576 four-player
decisions (`tests/issue2_tiebreak_sim.py`): the prefix-sum loop fell through on a non-zero sum
**0 times**. Two things worth recording about that:

- a 0-score move can never be returned by the weighted loop - reaching move k implies
  `sum(0..k-1) <= rmove`, so a 0-score move cannot push the accumulation above `rmove`. The
  loop is therefore not a weighted sampler over the move list, it is a **dominance order**: any
  positive-score move beats every 0-score move. That is the intended semantics - it deserves a
  comment - and it is the only reason the fallback matters at all;
- the non-negativity of the table is load-bearing. Put a penalty into `EvalScore`
  (`LOSE = -10`, a risk term) and both `randi() % sum` and the prefix-sum loop change meaning:
  the fallback becomes reachable from a non-zero sum, and negative-score moves can be skipped
  entirely by the accumulation. `assert m._score >= 0` at the end of `eval_moves` pins the
  invariant down.

How often it fires and what it picks
------------------------------------

`tests/issue2_tiebreak_sim.py` - 30 000 four-player rounds (10 000 x 3 paired seeds), the
rules/scoring/memory of `tests/prince_memory_sim.py`, the shipped memory policy, three
tie-breaks measured in one run (Monte-Carlo sd on the win rate: 0.25pp):

|                                       | `valid_moves[-1]` (shipped) | uniform (the drafted fix) | `valid_moves[0]` (control) |
|---|---|---|---|
| decisions                             | 277 576 | 277 577 | 277 597 |
| zero-score decisions (fallback fires) | **1 212 (0.437%)** | 1 218 (0.439%) | 1 223 (0.441%) |
| ... the list had exactly **1** legal move | **747 (61.6%)** | 751 (61.7%) | 752 (61.5%) |
| ... every legal move is a Guard probe | 82 (6.8%) | 84 (6.9%) | 88 (7.2%) |
| the last generated move               | Prince 648, Priest 409, **Guard 82**, Baron 73 | 650 / 411 / 84 / 73 | 650 / 412 / 88 / 73 |
| the first generated move              | Prince 648, Priest 383, **Baron 97**, Guard 84 | 650 / 385 / 97 / 86 | 650 / 386 / 97 / 90 |
| Guard plays / hit rate                | 108 129 / 23.98% | 108 134 / 23.96% | 108 127 / 23.96% |
| "Princess" declared while holding the Princess | **74** | 11 | **0** |
| seat 0 round win rate, seeds 1234 / 777 / 4242 | 25.99 / 25.92 / 25.60 | 25.84 / 25.76 / 25.42 | 25.73 / 25.63 / 25.28 |
| ... mean                              | **25.84** | 25.67 | 25.55 |

The `first` column is a control, not a proposal. In an all-zero list every move scores 0, so
the three policies only swap one worthless move for another - and *which* one is worth 0.3pp:
the first generated move is a Baron 97 times, and a zero-score Baron is a **known loss** (the
memory branch pays nothing when `my_type < mem`), so the control plays 97 known-losing Barons
per 30 000 rounds and finishes last - 0.29pp x 30 000 = 87 rounds, which is the arithmetic of
those eliminations. The last generated move is a Prince 53% of the time, which is the most
valuable thing on offer in those turns. That is the whole story of the severity: the tie-break
is choosing between 0-score moves, and it happens to choose well.

Four numbers decide the severity:

1. **62% of the time there is no tie to break.** 747 of 1 212 zero-score decisions offer a
   single legal move; `[-1]`, `[0]` and `randi() % len` are one policy there. This is also
   where the "the tie-break could make the AI burn its own Princess" worry dies: a hand of
   `[Prince, Princess]` with every rival protected has `valid_moves == [Prince on self]` - any
   tie-break plays it, because it is the only move.
2. **The Princess declaration is 0.03% of decisions** - 82 of 277 576, one per 366 rounds. The
   old title ("turns everything-scores-0 into a Princess declaration") describes 6.8% of the
   0.44% slice; the majority of the picks are a Prince (53%), then a Priest (34%).
3. **In the motivating state there is nothing to choose.** The section's example is
   `[Princess, Guard]` late in a round with every other guessable copy in the discard, i.e.
   `left_cards[t] == 0` for every `t` - which is *why* the scores are 0. `find_valid_moves`
   has no Princess case (`main.gd:512-543`) and `eval_moves` has none either, so the Princess
   in hand is not a move at all: the whole list is Guard probes, every one of them a certain
   miss, and the pick is a coin flip between guaranteed misses that costs the AI a Guard - a
   card it is discarding this turn under all three tie-breaks - while the Princess stays in
   hand. The Guard-Princess call is also the count-heuristic argmax (section 5: `_left` is the
   exact posterior, and the Princess is the unique copy), i.e. a *sane* probe in general; it is
   only a certain miss in the one case that matters, when the AI itself holds the Princess -
   which is issue 1's guardrail's job, not the tie-break's.
4. **The shipped pick is the best of the three, not the worst** (25.84 / 25.67 / 25.55, one
   number within noise, ordered by how valuable the move it lands on is: Prince 53% > Priest
   34% > Guard 7% > Baron 6%). Uniform is not a repair, it is a re-randomisation of a choice
   the scoring table has already declared irrelevant - and it gives up the Prince-heavy tail
   that makes `[-1]` the best of the three.

What survives the closure
-------------------------

- The mechanism is real and it is the one that produced the reported behaviour: zero-score
  fallback + generation order = deterministic Princess declaration. `tests/repro_guard_princess.tscn`
  Test A still pins it down ("all 7 guesses score 0 -> the last one, Princess, is picked"), and
  the section 0 fix removed its frequent trigger.
- Knock-on measured on the drafted issue 1+3 table (the one section 1's closure declines to
  land): zeroing guaranteed-miss Guard guesses moves turns from "one positive score" to "all
  zero". With `scoring = fixed13` (the issue 1+3 table, same seeds) the probe measures **1 254**
  zero-score decisions (0.451%, +42) and **92** last-is-Guard turns (from 82). The drafted repair
  would *grow* this tail, which is one more reason to answer this section with a comment and an
  assert rather than to buy a scoring change that feeds it.
- What the snippet genuinely deserves is a comment and an assert (above), not a fix.

3. `EvalScore.GOOD * m._target_type`: the premise was wrong, the value is 400, not 0
   (severity L, was H) - NOT AN ISSUE
------------------------------------------------------------------------------------

The old text of this section assumed `_target_type` is `Deck.CardType.Unknown == 0`.
`Unknown` is **8**: `deck.gd:3-11` numbers the enum Guard = 0, Priest = 1 ... Princess = 7,
Unknown = 8 (section 5, item 3 of this doc already states it). `find_valid_moves` builds
Baron / Prince / King moves without a target type (`Move.new(cards[i], i, p.idx)`,
`main.gd:531-543`), so the three multiplications evaluate to:

| line | branch | expression | value |
|---|---|---|---|
| `player.gd:230` | Guard, correct guess | GOOD x rank of the *guess* (`find_valid_moves` guesses Priest..Princess = 1..7) | 50 .. 350 |
| `player.gd:244` | Baron, `my_type > mem` (we win, rival eliminated) | GOOD x `Unknown` | **400** |
| `player.gd:258` | Prince on a known Princess holder | GOOD x `Unknown` | **400** |

400 is the *largest* number in the scoring table - above the best Guard guess (50 x 7 = 350)
and above every fixed score - so those two branches do not suppress the best kills of the
game, they pay them the top score, and level 4 plays them greedily. Measured in the engine
(`tests/repro_score_multiplier.tscn`, documented in `tests/README.md`; run `godot --headless --path .
tests/repro_score_multiplier.tscn`, exit 0):

| position | old claim | measured |
|---|---|---|
| `[Baron, King]`, memory of rival = Priest (the Baron **wins**: King > Priest) | 0 = LOSE, never played | Baron 400 vs King 5 -> played **390/400** samples |
| `[Baron, Guard]`, memory of rival = Priest (the Baron **loses**) | - | score 0, played **0/400** - the branch is coherent |
| `[Prince, Handmaid]`, memory of rival = Princess | 0, never played | Prince 400 vs Handmaid 20 -> played **387/400** samples |
| what the multiplier encodes | GOOD x rank of the killed card | Baron win vs a believed Priest / Prince / Countess = **400 / 400 / 400**: the multiplier is the constant `Unknown`, not a rank |

Whole games: instrumented subclass of `tests/prince_memory_sim.py` (same rules, three
scoring variants, paired seeds, current `main.gd` memory bookkeeping, 30 000 four-player
rounds per cell; the instrumentation script is not in the repo, the numbers below are the
record). `shipped` is `eval_moves` as it stands, `rank-scaled` is the drafted
`GOOD * (1 + mem)`:

| metric | shipped | rank-scaled |
|---|---|---|
| decisions | 277 443 | 277 479 |
| decisions with a **known Baron win** on offer | 1 890 | 1 904 |
| ... scored 0 (= LOSE) by the table | **0** | 0 |
| ... **actually played** | **1 776 (94%)** | 1 570 (82%) |
| known Princess-kill Prince: on offer / played | 1 381 / **1 072 (78%)** | 1 398 / 1 082 |
| seat 0 round win rate, seeds 1234 / 777 / 4242 | 25.74 / 25.68 / 25.64 | 25.70 / 25.65 / 25.65 |

The "0 = LOSE, therefore never played" chain of the old section 2 argument applies to
exactly one value of `_target_type`: a Guard *target* (`Guard == 0`), i.e. the section 0
bug, already fixed. Nothing else in `eval_moves` multiplies by a zero, and the known-win
moves are played with the weighted-random probability their 400 buys them (400 / (400 + the
~16 average score of the competing plays) - hence 94%, not 100%).

Verdict: the symptom the old section 3 describes does not exist. Design decision recorded
here: **keep the 400**. The rank-scaled multiplier takes strictly fewer guaranteed kills
(94% -> 82%) at a win-rate difference that flips sign between seeds - Monte-Carlo noise
(sd ~ 0.25pp at 30 000 rounds) - so it is a rebalance, not a repair.

What is left is real, and all of it is latent (severity L):

1. **An enum ordinal sits inside a scoring expression.** `GOOD * m._target_type` is a
   number that happens to come out right. Reorder `CardType`, insert a type before
   `Unknown`, change `Unknown`, and every Baron/Prince kill score rescales silently. It is
   the same bug class section 0 fixed - multiply by an ordinal - the Guard case zeroed, the
   Baron/Prince case inflates. Cheap hardening: name the constant
   (`EvalScore.KILL = 400`) and keep `GOOD * rank` only where a rank is genuinely
   available (the Guard branch).
2. **The "higher cards are worth more" intent is not implemented for Baron/Prince kills**:
   every known kill scores 400, so a Princess-burning Prince and a Baron win on a believed
   Guard are valued identically. The rank-scaled candidate is measured above; like section
   5 item 2 this is a scoring-table calibration question, not a memory/accounting bug.
3. **The 400 is paid for false beliefs as well as true ones** - the Baron branch trusts
   `_memory[target]` blindly, and section 4's table records the price: 97 false Baron
   beliefs and 25 AI self-eliminations from them per 20 000 four-player rounds (shipped
   scoring). A rank-scaled multiplier does not cure it (`GOOD * (1 + Guard) = 50` still
   beats the ~16 of the competing plays). What covers it is the invariant that closes section 1
   - beliefs are reads of real cards, so a belief-driven Baron is a Baron the seat has *seen*
   the losing condition of - measured 0 false beliefs at 60 000 rounds and 13 917 engine
   decisions. `tests/repro_belief_truth.tscn` is the net that keeps item 3 priced at 0.

Knock-ons inside this doc:

- section 1's "350 - the highest number in the scoring table": 400 is higher. Its `GOOD * (1 +
  mem)` reproduces 400 for the unique card, which is why the fixed scoring tables in section 4
  read continuously with the shipped ones - and why that comparison measures a rebalance, not a
  repair, on both sections at once;
- section 2's "every state that scores all moves 0": with 400s in the table those states
  are rare - measured 1 212 of 277 576 four-player decisions (0.437%), and the last
  generated move is a Guard (the Princess declaration) in 82 of them (~0.03% of decisions),
  a Prince in 648, a Priest in 409, a Baron in 73 (`tests/issue2_tiebreak_sim.py`). The 400s
  are why a nonzero sum is the normal case; the loop falling through on a nonzero sum was
  measured 0 times, because `LOSE = 0` is the floor - the fallback is reachable exactly from an
  all-zero list;
- section 5 item 3 (`CardType` has 9 values with `Unknown == 8`) is the fact this section
  was written against.

Related, same table: `EvalScore` has no branch for a played Princess (`eval_moves`
initialises `_score = LOSE` at `player.gd:223` and the `match` has no Princess case), which
is correct by accident - playing the Princess is suicide. `find_valid_moves` has no Princess
case either (`main.gd:512-543`), so the AI is never offered that move; the human is, and a
human can play it.

4. The Prince cleared the belief about its own player, not about the rival whose hand
    changed (severity H for level 4) - FIXED
---------------------------------------------------------------------------------------------

The rule the memory model implies, and which the King branch already implements correctly
(`main.gd:385-392` swaps the two traders' beliefs and the third parties' slots):

> `_memory[i][j] = T` means "player i believes **player j's hand card** is T".
> A belief must be cleared (or moved) exactly when **that card** leaves j's hand.

Two places in `main.gd` broke it:

1. **Prince cleared the wrong slot** (`main.gd:363-364`, and that is where the fix now sits).
   The hand that changes is the target's; the loop cleared beliefs about the Prince player.
   Exactly right for a self-targeted Prince - which is why the bug survived, the code was
   written for that case - and inverted for the common one.
2. **Elimination cleared nothing** (`set_inactive`, `main.gd:286-296`).

**The third one is not a bug, and a "fix" for it is cheating.** `_on_card_played`
(`main.gd:215-217`) clears every belief about the playing player whose type matches the
played card. The tempting reading of the rule above is "beliefs name the card at index 0, so
a player who plays the card he has just drawn has not invalidated them". A seat cannot know
that: a player holds two cards face-down and turns one face-up, so the observer sees the
**card**, never the **slot** it came from. If seat 0 believes "seat 1 holds a Handmaid" and
seat 1 plays a Handmaid, seat 0 cannot tell whether the known card left the hand. The
inference is probabilistic, and it favours clearing:

- measured over 20 000 four-player games (`tests/prince_memory_sim.py`): 16 369 plays
  matched a belief and triggered the clear; in **14 808 (90.5%)** the played card *was* the
  card the belief named, so the clear was required; in **1 561 (9.5%)** the player held both
  copies and the belief was still true.
- in the deterministic position of test D the draw pile at seat 1's draw holds 11 cards with
  exactly one Handmaid in them, so "the play was the duplicate" is a 1-in-11 shot.

Keeping the belief in the 90% case is worse than losing it in the 9% case: a false belief is
what the level 4 memory branch trusts blindly, at `GOOD * rank` (issue 1). So the shipped
rule stays as it is. Selecting the played card by index inside `_on_card_played` and clearing
only then would give every seat information the physical game hides - it was tried, measured,
and reverted.

How much the two real halves are worth. `tests/repro_prince_memory.tscn` measures the
positions inside the engine; `tests/prince_memory_sim.py` replays the same rules (scoring
included) over 20 000 four-player games:

|                                                        | shipped | draft fix below | applied fix |
|---|---|---|---|
| Guard plays that are certain misses                      | 257     | 0             | 0           |
| false Baron beliefs / AI self-eliminations from them     | 97 / 25 | 0 / 0         | 0 / 0       |
| Guard hit rate                                           | 23.91%  | 23.98%        | 24.37%      |
| seat 0 round win rate                                    | 25.46%  | 25.49%        | 25.50%      |
| true belief about the Prince player kept (test B)        | no      | no            | yes         |

- **The Prince target is the real bug.** Test A: seat 0 learns "seat 1 holds a Handmaid"
  from a Baron tie, seat 2 then Prince-eliminates that Handmaid, and the last Handmaid in
  the game ends up in seat 0's own hand. The memory branch never consults `_left`, so it
  pays `GOOD * HANDMAID = 150` for a call that is provably impossible, against 0..5 for
  every alternative; level 4's weighted pick plays the guaranteed miss in **63%** of 400
  samples. With the slot cleared the same call scores 0 (the card-count branch: one left,
  the copy in my hand) and is played in 0% of samples.
- **The elimination half is housekeeping, not strength.** `find_valid_moves` filters targets
  on `is_active()`, so a belief about a dead seat is never scored: test C recomputes the
  score table with the slot cleared and every score is identical. What they do cost is
  indirect: the Baron-tie propagation loop (`main.gd:341-346`) clones a dead seat's belief
  onto a live player, and section 1's "don't guess a type pinned in a known hand" guardrail
  fires on cards that are out of the round (147 of 396 zeroings in the simulation). 8 149
  such slots existed at decision time over the simulated rounds.
- **Why the draft fix is not enough:** it adds the clear of the target's slot (right) and
  keeps the destructive clear of the Prince player's own slot (wrong). The Prince destroys
  ~9.2 true beliefs per 100 rounds for every ~9.5 stale ones it legitimately removes; with a
  16-card deck and ~8 plays per round, that is a large share of everything the AI learns.
  Test B is the deterministic version: seat 0's Priest reveals that seat 2 holds a Handmaid,
  seat 2 then Princes seat 3 and keeps the Handmaid - the draft clears the stale belief about
  seat 3 and destroys the true one about seat 2 in the same breath.

Fix applied (two hunks):

```gdscript
# Prince, main.gd: the hand that changed is the target's
     await deal_card(tp, true)
     for pl in _players:
-        if pl.idx != _cur_player:
-            pl.update_memory(_cur_player)  # hand is unknown now
+        pl.update_memory(tp.idx)           # tp's new hand is unknown to everybody
```

A self-targeted Prince collapses to the same single clear, since `tp.idx == _cur_player`.

```gdscript
# set_inactive: a seat out of the round has no hand to believe in, and its own beliefs
# will never guide a move again
 for pl in _players:
     pl.update_memory(p.idx)
+for j in 4:
+    p._memory[j] = Deck.CardType.Unknown
```

Both clears are public information: the Prince discards the target's card in the open, and an
eliminated player's hand is revealed and discarded. Nothing here tells a seat anything it
could not read off the table.

Reachability note for the "stale Princess" story: the Princess leaves a live player's hand
only through the King trade, and the King branch rewrites memories correctly. Removing the
Princess by Prince, by playing it, or by losing a Baron/Guard duel eliminates its owner. So
a Princess belief attached to a *live* rival is true, and it travels through the
propagation loop (`main.gd:342-346`, a Baron tie clones a belief from one player's slot into
another's, which a tie makes a valid deduction). With this fix the two sources of staleness that
loop used to amplify are gone: the Prince no longer leaves a belief pointing at a card that left
the game, and a seat that left the round has no belief left to clone. That is the invariant
section 1 is closed on - measured 0 false beliefs, 0 impossible memory-driven guesses, 0 false
Baron beliefs over 60 000 rounds and 13 917 engine decisions. The residue the note points at (a
copy the seat itself pinned in somebody else's hand, which the card count still charges to an
unknown hand) is a count-branch matter, recorded in section 5 item 1.

Verification: `tests/repro_prince_memory.tscn` (A-D assert the behaviour in the engine,
including test D's posterior for the played-card clear, E replays the two Prince decisions
under the shipped, draft and applied policies), `tests/smoke_games.tscn` (300 AI-driven
rounds, 137 eliminations, no script error), and the pre-existing
`tests/repro_guard_princess.tscn`, which still passes with these changes.

5. `_left` counts widow cards and cards in hands - by design (severity L, was M)
--------------------------------------------------------------------------------

Verdict: not a bug. `Deck` maintains one invariant - `Deck.prepare` (`deck.gd:48-63`)
initialises it and `Main.discard()` (`main.gd:421-433`) is the only writer:

```
_left[t] = copies of type t that are not in the discard
         = draw pile + widow + every player's hand
```

pile -> hand moves (a deal, a Prince redraw) leave `_left` alone; only cards that have
left the game decrement it. That is precisely the quantity a Guard guess needs, because a
Guard guess is about a *hand*, not about the draw pile.

**The count is exact, not an estimate.** Conditioned on what a player legitimately knows
(own hand + discard piles), the target's single card is a uniformly random card of the
unknown pool `U = sum(_left)`, so

```
P(target holds t) = _left[t] / U
```

`EvalScore.BAD * left_cards[t]` (`player.gd:232-237`) is therefore an affine transform of
the true posterior: correct ranking, correct scale, and the widow sits in the denominator,
where it belongs. The AI's own two cards are subtracted (`player.gd:233-236`), which is
the only subtraction the count is entitled to make. This is the point `level4.md:32`
attributes to the AI ("Guard probability is crude: ... not accounting for cards already
revealed") - it is not crude, and that line should be reworded to name the one real gap:
cards pinned in *other* players' known hands (item 1 below).

Measured on 200k random deals, 4 players, no memory (argmax over the count vs the type the
target actually holds) - `tests/left_cards_sim.py`, run `python3 tests/left_cards_sim.py`.
The theoretical ceiling for *any* estimator with this information is
`(5 - 2*5/16) / 14 = 0.3125` - in a fresh round the argmax is always Guard:

| estimator | hit rate | comment |
|---|---|---|
| **current `_left`** | **0.3132** | at the information-theoretic optimum (0.3125, within Monte-Carlo noise) |
| `_left` minus the actual widow cards (proposed fix 1) | 0.3135 | +/- 0.1% noise, and only by using `_widow_cards`, which the Deck node knows and the player at the table does not |

**Fix 1 (decrement `_left` for widow cards) is rejected.** Removing the widow does not
"correct a bias", it re-conditions from *the target's card is in the unknown pool* (right)
to *the target's card is in the hands* (noisy), and the only thing that buys is hidden
information. The advantage it buys grows as the round runs down - 2 players, widow = 3
cards, no memory, 200k deals:

| discards | current `_left` hit rate | with fix 1 |
|---|---|---|
| 4 | 0.317 | 0.344 |
| 8 | 0.361 | 0.444 |
| 10 | 0.401 | **1.000** |

At 10 discards in a 2-player game, `16 - 10 - 3 - 2 = 1`, so the last unaccounted card *is*
the rival's hand: fix 1 turns the final Guard guess of every 2-player round from 40% into a
certain hit, at exactly the moment a human is watching most closely. Design decision
recorded here: **the widow stays hidden from the AI**; level 4 plays with table-legal
information only.

The three bullets of the original section that describe non-defects:

- "cards in other players' hands are counted" is the conditioning that makes the estimator
  exact - not a flaw;
- "the Prince player's own card and the target's new card are not accounted for" - they
  are: pile -> hand deliberately does not change `_left` (a hand card is still unknown), and
  the Prince player's remaining card is unknown to everybody. The AI's own card is
  subtracted. Nothing to fix.
- "cannot be drawn" is also literally false: `deal_card(tp, true)` in the Prince branch
  (`main.gd:358`, `deck.gd:66-71`) pops from `_widow_cards` when the draw pile is empty.

What is left of this issue - three things, all small:

1. **Cards pinned in known hands are not subtracted** - the one real gap, and the legitimate
   half of the old fix 2. With a belief "player 2 holds the King", the correct posterior for
   a guess on a *different* player is `(N_t - pinned_t) / (U - pinned_count)`; the missing
   `- pinned_t` lets a guaranteed-failed guess score `BAD * 1 = 5` instead of 0, and the
   pinned copy inflates the count of its own type. Measured (4 players, one Priest reveal,
   guess on an unknown player; share of Guard guesses aimed at the type the AI *knows* is in
   the revealed hand, and the resulting hit rate):

   | discards | current `_left`: picks the pinned type | with the subtraction | hit rate `_left` -> subtracted |
   |---|---|---|---|
   | 0 | 31.2% | 29.8% | 0.3132 -> 0.3130 |
   | 4 | 31.7% | 19.9% | 0.3163 -> 0.3228 |
   | 6 | 33.1% | 16.6% | 0.3310 -> 0.3452 |
   | 8 | 36.2% | 14.4% | 0.3601 -> 0.3781 |
   | 10 | 40.1% | 12.4% | 0.4024 -> 0.4450 |

   In a fresh round the effect is noise; it grows with the discard count, and in the last
   third of a round the level 4 AI spends ~40% of its Guard guesses on a card it has
   personally revealed into somebody else's hand. This is the guardrail section 1's drafted
   extension was built around - the `unknown_hands` denominator of the drafted
   `probability = free_copies / unknown_hands` helper is identical for every Guard guess in
   a turn, i.e. a constant multiplier that changes nothing inside a turn, so the helper was
   dropped and only the `- pinned_t` survives. Do it here, not as deck surgery. Its severity
   is L, not H: the guess it misprices is a legal play, it costs one Guard (a card the seat is
   discarding this turn anyway) and the score it earns is 5, so the AI plays it only when
   nothing better is on offer.

   In-game, whole rounds (20 000 rounds per cell, section 4's memory policy in force, scoring
   shipped vs. `fixed13` = this subtraction plus the rank-scaled kill scores): guesses the
   subtraction zeroes: 0 (2p) / 92 (3p) / 193 (4p) per 20 000 rounds - ~1 per 100 rounds in 3-4
   players, never in 2p, where any belief the seat holds is about the *target*, so there is
   nothing to subtract. Guard hit rate 22.80 -> 22.14 / 25.16 -> 24.82 / 24.37 -> 24.18; seat 0
   win rate 50.62 -> 50.76 / 33.77 -> 33.68 / 25.50 -> 25.55 (sd 0.25pp, so: noise). The
   synthetic rows above promise a better hit rate because they hold the discard count fixed and
   compare argmaxes; in real rounds the zeroed probes are replaced by *other* probes, and the
   mix is what moves. Recorded as an open calibration item, not landed.

   One implementation note for whoever lands it: the subtraction is only defined over the targets
   that are in the round. A belief naming an eliminated seat is a slot the seat should not have -
   section 4's `set_inactive` clear is exactly what keeps that from happening, and section 5's
   zombie row measures it at 0 - and a dead seat's slot is a copy the target-`left_cards` check
   cannot see, so a version of this rule that subtracts pinned copies from all rows silently
   converts a stale slot into a silenced guess. Scope it to live rows.
2. **Guard probe scores are inflated relative to the fixed scores of the other cards.**
   `sum(_left) = 14` at the start of every round, of which 11 (2 players) / 13 (3-4
   players) are outside the widow, so 2-player Guard probes carry ~27% more weight against
   Priest/Handmaid (20), WEAK (10) and Countess (5) than the "copies in hands" reading
   implies; in 3-4 players it is ~8%. Real, but it is a scoring-table calibration question
   (`level4.md:35`, "score multipliers are arbitrary"), not a memory/accounting bug - a
   probe is not worthless and its price is a design choice.
3. `_left` has 8 entries (`card_count.size()`), `CardType` has 9 values with
   `Unknown == 8`. Nothing indexes `_left[Unknown]` today - the Guard branch is the only
   consumer of `left_cards`, and it is reached only with a guessable type - so this is
   harmless now, but any `for t in CardType` loop, and any helper that indexes
   `left_cards[m._target_type]` for a non-Guard move (`_target_type == Unknown`), runs off
   the end.

Cosmetic: the debug print `Left ...` (`main.gd:164-165`) means "cards of this type still in
play (pile + widow + hands)", not "cards I can draw". Worth renaming to `In play` so the
next reader does not assume the count is a draw-pile counter.

6. The disclosure model: who the rules entitle to see what, and the one legal channel nobody
   records (severity M, open item: 3 only; 1 and 2 are not issues, 4 is cosmetic)
---------------------------------------------------------------------------------------------

Found while proving the invariant that closes section 1. That invariant is about a belief being
**true**; it says nothing about who is **entitled** to it. Section 6 is the entitlement question,
and the answer is the card text, not the screen. Design decision recorded here: **the game plays
the official disclosure convention** - the 16-card deck of `deck.gd:card_count` is the Classic
variant of the Z-Man rulebook, and the rule lines quoted below are the governing text. The
first draft of this section argued from "a reveal that is on the screen is table-legal for every
seat", and both of its halves came out backwards.

The rules split the table into disclosure classes, and every branch of `resolve_effect` lands in
exactly one of them:

| event | who is entitled | the rule text |
|---|---|---|
| a hand card | its owner | a player may keep his hand secret |
| a played or discarded card | everybody | played and discarded cards stay faceup, visible to all |
| a knock-out | everybody | an out player discards his hand faceup |
| Guard: the named card, and the target's answer | everybody | the card is *named* (spoken), and the answer must be truthful |
| Priest: the card looked at | **the Priest player only** | "Choose another player and **secretly** look at their hand (**without revealing it to anyone else**)" |
| Baron: the two compared cards | **the two contestants only** | "You and that player **secretly compare** your hands" |
| Baron: the **outcome** - who is out, "nobody" included | everybody | the elimination is on the table; "If there is a tie, neither player is out" |
| King: the trade; each party's new card | everybody; each party | trade hands |
| Prince: the discarded hand | everybody | the target discards his hand faceup and redraws |

Two facts fall out of that table and they are the two the first draft had inverted: **a Priest peek
is private** (there is nothing owed to the table), and **a Baron tie is public even though the
compared cards are private** (nobody leaving the round *is* the tie). Everything below is derived
from the table.

1. **A Priest reveal teaches exactly one seat: its author - and that is the rule.**
   **NOT AN ISSUE (severity: none; the drafted broadcast is REJECTED)**

   `main.gd:325` writes the Priest player's own row and `main.gd:323` animates only for a human
   author. Volume (`tests/prince_memory_sim.py`): 25 107 Priest reveals per 20 000 four-player
   rounds, 1.26 per round, each one a certain belief about a hand card, each recorded by exactly
   one seat; the model runs on 15 966 live beliefs per 20 000 rounds, every one first-hand.

   - *"the human is the one player the rules grant the view, and he does not get it"* - true only
     when the human **is** the Priest player, which is exactly the branch that reveals
     (`if p.is_human(): Animator.reveal_hand(tp)`). When an AI authors the peek, the rules give
     the view to that AI and to nobody else; showing it on the screen would hand the human - i.e.
     an opponent of that AI - information the card reserves to the Priest. `main.gd:326`'s
     `print("Priest: reveal hand")` is what made the branch read as a missing reveal; it is a
     private read, and the log should say so.
   - *"a reveal that is on the screen is table-legal for every seat"* - the screen is not the
     criterion. `main.gd:75` (`Human is allowed for Player 0 only`) means one human seat on one
     device, so "on screen" = "in the human's hands": a *player*, not the table. Section 5 set the
     criterion - *"level 4 plays with table-legal information only"* - and rejected the widow for
     exactly this reason; a Priest peek is the same class of information as the widow, and a much
     bigger stake: 1.26 certain facts about live hands per round.
   - the broadcast (`for pl in _players: pl.update_memory(tp.idx, revealed_type)`) is therefore
     not "widening who is allowed to read", it is **collusion between the AI seats against the
     human**. Measured (instrumented copy of `tests/prince_memory_sim.py`, policies
     `fix_plus` = section 4's applied memory rules, `fix_plus_bc` = every seat records every
     Priest reveal, `bc_vs_human` = the AI seats share reveals while seat 0, standing in for the
     human, keeps today's legal view; shipped scoring; 20 000 rounds per cell, paired seeds 1234;
     the instrumentation script is not in the repo, the numbers are the record):

   | players | Guard hit rate % | seat 0 round win rate % |
   |---|---|---|
   | 2p: `fix_plus` / broadcast | 22.80 / 22.80 | 50.62 / 50.62 (nothing to share: in a 2-seat game the only other seat *is* the target, who owns the card) |
   | 3p: `fix_plus` / bc_all / bc_vs_human | 25.16 / 27.86 / **26.92** | 33.77 / 33.53 / **32.82** |
   | 4p: `fix_plus` / bc_all / bc_vs_human | 24.37 / 29.38 / **28.35** | 25.50 / 25.35 / **24.65** |

   +4pp Guard hit rate and -0.85pp (4p) / -0.95pp (3p) of the human's round win rate: 3-4x the
   Monte-Carlo sd of 0.25pp. Section 5 refused a change that bought 0.1% of noise; this one buys a
   standing handicap for the human player.
   - the sentence this section used as the motive for the broadcast - *"pinned copies only exist as
     beliefs, and today a seat pins a copy only in the hands it personally looked at"* - does not
     need the broadcast to be useful. Section 5 item 1's subtraction is about the copies *the seat
     itself* pinned, and author-only Priest reads supply exactly those. Section 5 item 1 stands
     unchanged under the official convention.

   **No change**: `main.gd:323-325` stays as it is, single-author memory stays the model of record
   (`level4.md`, "memory depth is single-author"), and the one cosmetic item is the log wording.

2. **The Baron tie propagation is a legal deduction from the public outcome - NOT AN ISSUE**

   The first draft's premise here ("a tie is public" for the cards, and "the human is given a
   deduction whose premise he was never shown") is half false in both directions: the compared
   cards are secret, and the tie is public. The propagation loop (`main.gd:341-346`) copies a
   belief `pl` *already holds* about `p` into `pl`'s slot for `tp` (`if`/`elif`, one direction per
   seat, and it never invents a type), and the premise it needs is not "I saw both cards", it is
   "the two hands are equal". A Baron duel has three outcomes and all three are on the table:
   `p` is out, `tp` is out, or **nobody** is out - and "nobody is out" *is* the tie. So any seat,
   the human included, can derive `p == tp` from the outcome without seeing a card, and a true
   belief about one of them is then a true belief about the other. That is the section 1 invariant
   argument, and it survives the secret-comparison reading.

   The display supports the derivation: the played card goes faceup on the table (`main.gd:199`),
   the chosen target is marked for the whole effect resolution (the `_target_player` setter,
   `main.gd:52-58`, puts `_player_selection` on the target and `resolve_effect` hides it again at
   `:314`), and a knock-out has its own audio and animation. What is *not* said out loud is the
   word "tie" - `main.gd:347` prints it, the screen does not. Measured volume: 836 Baron ties and
   129 third-party propagations per 20 000 four-player rounds (`fix_plus`, shipped scoring), so
   the human's array is rewritten this way about once per 155 rounds. **Item 2 closes here as a UX
   call-out nit** (a "Tie" label at `:347`), not an information-flow bug, and the reveal guard
   (`main.gd:328-331`, cards shown only to a human party, nothing shown in an AI-vs-AI duel) is
   correct for a secret comparison. The whole Baron branch - `> / < / ==` resolution, the lower card
   out, tie = neither out, the contestants' two writes at `:339-340` - matches the card text.

3. **The public Guard answer is the one channel no seat records (OPEN, severity M)**

   "Name a character other than Guard" is spoken at the table and the target must answer
   truthfully, so **every failed Guard guess publicly proves `target's card != the named type`**.
   That is table-legal information under section 5's criterion, and `main.gd:319-321` discards it:
   `_memory` cannot hold it - every value of `CardType` names a card (or `Unknown`, section 5 item
   3), so the model has no representation of a negative belief and no seat can use the answer.
   It is the real "reads that never happen", and the target marker + the elimination animation
   make it visible to the human seat as well.

   Volume and effect (instrumented copy of `tests/prince_memory_sim.py`, scoring `denied` = a
   Guard guess aimed at a publicly-denied (seat, type) pair scores `LOSE`, memory policy
   `fix_plus`; a denial is invalidated with section 4's discipline - cleared by a Prince on that
   seat, cleared by its elimination, and it **travels with the card** through a King trade, because
   "A's card is not a Guard" follows A's card into B's hand):

   | players | Guard plays | aimed at a publicly-denied pair (certain miss) | ... of them still played when those score `LOSE` | Guard hit rate % | seat 0 win rate % |
   |---|---|---|---|---|---|
   | 2p | 37 866 | 1 633 (4.3%) | 22 | 22.80 -> 22.85 | 50.62 -> 50.34 |
   | 3p | 61 269 | 3 158 (5.2%) | 37 | 25.16 -> 25.43 | 33.77 -> 33.59 |
   | 4p | 72 099 | **3 380** (5.2%) | 18 | 24.37 -> **24.75** | 25.50 -> 25.39 |

   ~0.17 provably-doomed guesses per four-player round, all of them the kind section 1's legend
   calls "a move a human would call irrational", removed at a Guard hit rate +0.38pp and a seat 0
   win rate inside noise - and, unlike item 1, the channel is symmetric: it handicaps the AI seats
   and the human equally, because both hear the answer.

   The 18/37/22 that survive zeroing are section 2, not staleness: zeroing a move does not remove
   it from `valid_moves`, and an all-zero list hands the pick to `valid_moves[-1]`. Zeroing
   guaranteed misses *grows* that tail, exactly as section 2's "what survives the closure" records
   for the drafted issue 1+3 table - which is why this item, if landed, lands together with a
   tie-break note and not on its own.

   Implementation notes for whoever lands it: (a) it needs the negative-belief schema - a per-seat
   bitset of "not these types" is the natural shape, and it must be wiped with the rest of the
   memory at `main.gd:129-130`; (b) the consumer is the Guard **count** branch (`player.gd:232-237`)
   - the memory branch is untouched and keeps its section 1 guarantee; (c) it is the negative twin
   of section 5 item 1 (copies pinned in known hands), and the two are the same bookkeeping: both
   say "this copy is accounted for", one in a hand, one as an excluded pair; (d) a denial is about
   a *seat*, and a seat holds exactly one card, so a seat's denial set is the complement of its
   hand card - worth stating in the comment, because it is what makes the King-trade rule
   (denials travel with the card) non-obvious.

4. **Three call sites hide a public reveal (severity L, cosmetic, human-facing only)**

   An out player discards his hand faceup, visible to everybody, so the eliminated card is public
   information and the human is entitled to see it. `set_inactive`'s `reveal_hand: bool = true`
   (`main.gd:286`) means *flash and hide* (`Animator.reveal_hand(p, hide_afterwards)`), so:

   | call | line | hide_afterwards | rule |
   |---|---|---|---|
   | Guard kill | `:321` (default) | `true` - hidden | public: show it |
   | Baron kill | `:335`, `:337` (`!party.is_human()`) | `true` when no human is a party - hidden | public: show it |
   | self-played Princess | `:395` (default) | `true` - hidden | public: show it |
   | Prince forces the Princess out | `:356` (`false`) | shown and left faceup | **the correct pattern** |

   The one-line shape is `reveal_hand = false` at the first three (reveal, and leave it faceup
   through `discard()`, `main.gd:421-433`). No AI strength content: the AI already counts the
   discard via `_left`. Related, same family and equally cosmetic: `round_over` (`main.gd:441`)
   reveals every survivor's hand even when one player is left, where the rules require a reveal
   only when the deck ran out - harmless, since all memory is wiped at `main.gd:129-130`.


Summary
-------

| # | Issue | Severity | Where | Symptom in play |
|---|---|---|---|---|
| 1 | The Guard memory branch has no deck-accounting guardrail (stale Princess belief scored 350) | L (was H) | `player.gd:226-235` | none: 0 false beliefs, 0 impossible memory-driven guesses, 0 false Baron beliefs over 60 000 rounds (20 000 x 3 player counts) and 13 917 engine decisions - a belief is a read of a real card, so a memory-driven guess is a certain hit. The drafted guardrail is unreachable code. **Not an issue**, `tests/repro_belief_truth.tscn` |
| 2 | `valid_moves[-1]` is a positional tie-break for zero-score turns | L (was H) | `player.gd:195-203` | 0.437% of 4p decisions are all-zero-score; 62% of them have one legal move (no tie), 6.8% are pure Guard-probe turns, and 82 per 30 000 rounds end in a Princess declaration - in states where every legal move is a certain miss. Uniform/first tie-breaks measure the same win rate (25.84 / 25.67 / 25.55, sd 0.25pp). **Not an issue**, `tests/issue2_tiebreak_sim.py` |
| 3 | `GOOD * m._target_type` is `GOOD * Unknown == 400`, **not** 0: known Baron wins and Princess-killing Princes are played, not suppressed | L (was H) | `player.gd:230,244,258` | none in play - latent: enum ordinal inside the score formula, no rank scaling for kills, 400 pays false beliefs too. **Not an issue**, `tests/repro_score_multiplier.tscn` |
| 4 | Memories did not follow the hand card (Prince cleared the Prince player's slot, eliminations cleared nothing, plays cleared on type) | H for level 4 | `main.gd:363-364`, `286-296`, `215-217` | Guaranteed-failed Guard call paid 150 and played 63% of the time; Priest knowledge destroyed. **Fixed**, `tests/repro_prince_memory.tscn` |
| 5 | `_left` counts widow + hand cards = correct pool; only pinned copies are missing | L | `deck.gd:48-63`, `player.gd:232-237` | Guaranteed-failed Guard guesses score 5 instead of 0: 193 per 20 000 4p rounds; the subtraction measures -0.19pp Guard hit rate at a win rate inside noise. Open calibration item (section 1's extension folded here) |
| 6 | Disclosure model: who is entitled to what. Priest is private by rule, Baron compares in secret and its **outcome** is public, the Guard answer is public and recorded by nobody | **M, open (item 3)**; 1 and 2 not issues, 4 cosmetic | `main.gd:319-321`, `322-325`, `327-346`, `286-296` | 25 107 Priest reveals per 20 000 4p rounds teach exactly one seat each - their author, which is what the card says; the drafted broadcast measures +4pp AI Guard hit rate and **-0.85pp (4p) / -0.95pp (3p) of the human's round win rate**, so it is rejected as AI collusion. The Baron tie propagation (129 third-party writes per 20 000 4p rounds) is a legal deduction from "nobody left the round", so the human's array is justified by what is on the table. The open gap: 3 380 of 72 099 Guard plays per 20 000 4p rounds (5.2%) aim at a (seat, type) pair the whole table has publicly heard denied; zeroing them measures Guard hit 24.37 -> 24.75 at a seat 0 win rate inside noise |

Sections 1 and 2 are the two halves of the reported "level 4 plays Guard and says
Princess". Section 0 (the Guard-memory check) removed its frequent trigger, and the trigger that
is left is section 2's all-zero tail - 50 declarations per 20 000 four-player rounds, **0** of
them scored by the memory branch, i.e. none of them is the play section 1 describes. So section 1
is closed as not an issue: its state has no construction path once section 4 landed (beliefs are
reads of real cards; measured 0 false ones in 60 000 rounds and 13 917 engine decisions,
`tests/repro_belief_truth.tscn`), its guardrail is unreachable code, and the scoring change it
drafted measures as a -0.19pp Guard hit rate at a win rate inside noise. Section 2 is closed as
not an issue (the tie-break picks between moves the table has already judged worthless - 62% of
zero-score turns have a single legal move, the pathological Princess declaration is 0.03% of
decisions, and the three tie-breaks are one win rate: 25.84 / 25.67 / 25.55 for last / uniform /
first, sd 0.25pp, so the deterministic pick stays). Section 3 is closed as not an issue (the 0 it
claimed is `GOOD * Unknown == 400`; the known Baron wins are played in 94% of the opportunities and
the Princess kills in 78%, `tests/repro_score_multiplier.tscn`), leaving a latent enum-ordinal
note. Section 4 is fixed (beliefs are cleared and moved with the hand card they name,
`tests/repro_prince_memory.tscn`). Section 5 turned out to be the counting model working as
designed (`_left` is the exact posterior pool for a Guard guess) - downgraded to L, with the widow
deliberately kept hidden from the AI, and with the pinned-copy accounting as its one open
calibration item. Section 6 is the open one, found while proving section 1's invariant - and
rewritten after the rule texts were read: its premise ("a reveal on the screen is table-legal for
every seat") is false for the two reveals it was built on, since the Priest peek is secret by card
text and the Baron comparison is secret between its two contestants. Under the official
disclosure convention the model's writers all check out - Priest writes its author's row only,
Baron's third-party tie propagation deduces from the public "nobody is out" outcome, the King
third-party swap deduces from the public trade - the drafted Priest broadcast is rejected as
collusion (measured: -0.85pp of the human's round win rate at 4 players), and the one legal
channel the model really drops is the public Guard answer: 3 380 provably-doomed guesses per 20 000
four-player rounds, and the negative beliefs that would prevent them are the schema change item 3
of that section spells out.
