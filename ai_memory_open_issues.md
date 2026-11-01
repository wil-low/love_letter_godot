AI level 4 - open issues in memory handling and move scoring
============================================================

Scope: `player/player.gd` (`eval_moves`, `select_move`), `main/main.gd` (effect resolution
and memory updates), `deck/deck.gd` (card accounting). Line numbers are from the current
working tree (after the Guard-memory fix described in section 0).

Reproduction harness: `tests/repro_guard_princess.tscn`
(`godot --headless --path . tests/repro_guard_princess.tscn`), documented in `tests/README.md`.

Legend: severity H = plays a move a human would call irrational, M = loses information /
misses opportunities, L = latent, only reachable in specific states.


0. Background: the belief model and the fixed issue
---------------------------------------------------

Each player keeps `_memory: Array[Deck.CardType]` of length 4 (`player.gd:58`). The intended
invariant is

> `_memory[i][j] = T` means "player i believes player j's single card in hand is T",
> and `Unknown` means "no belief".

Writes are made in `main.gd`: Priest reveal (`:320`), Baron tie (`:334-335`), Baron tie
propagation to third parties (`:330-333`), King trade (`:369-376`). Clears are made when a
card is played (`main.gd:209-210`, clears only if the belief pointed at the played card) and
in the Prince branch (`main.gd:346-348`). All beliefs are wiped at the start of a round
(`main.gd:129-130`).

The deck contains exactly one Princess (`deck.gd:card_count`), so a belief "player j holds
the Princess" is *provably false* as soon as the believer itself holds the Princess.

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

The four issues below are what remains - section 4 is now fixed (the fix and its tests are
recorded there), sections 1 and 2 are still open, section 3 turned out to rest on a false
premise (`Deck.CardType.Unknown` is 8, not 0, so the score is 400, not 0) and is downgraded
to L, and section 5 is kept for completeness -
it turned out to be the model working as designed.


1. A stale belief about the Princess is played greedily (severity H)
--------------------------------------------------------------------

Code (`player.gd:226-235`):

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

The memory branch never consults the deck. If `_memory[rival] == Princess` while the AI
itself holds the Princess, the guess is impossible, yet it scores 350 - the top score the
Guard branch can produce, second only to the accidental `GOOD * Unknown == 400` of the
Baron/Prince branches (section 3) - so the weighted random in `select_move` picks it with probability
`350 / sum`, which is 1.0 when every other move scores 0. Measured by `Test A`, scenario
"memory of rival = Princess":

```
Priest 0  Baron 0  Handmaid 0  Prince 0  King 0  Countess 0  Princess 350
AI plays: Guard (1), tgt 1, Princess
```

Mechanism summary: the count branch has the right guard (own hand is subtracted from
`left_cards`), the memory branch has none. So a *correct* belief is trusted, and a *stale*
belief is trusted just as strongly - and it is trusted most strongly for the unique card.

Consequence: a guaranteed-failed Guard play. The Princess is kept (suicide to play), the
Guard is spent, the rival is unharmed, and the AI's most valuable card is left rotting in
hand, which also makes it a Baron/Prince bait.

Fix: use the accounting in both branches - trust a belief only while the type is still
possible:

```gdscript
var left := left_cards[m._target_type]
for c in [hand.get_child(0).type, hand.get_child(1).type]:
    if c == m._target_type:
        left -= 1
if left <= 0:
    m._score = EvalScore.LOSE           # no copy of that type can be anywhere else
elif mem == m._target_type:
    m._score = EvalScore.GOOD * (1 + mem)
else:
    m._score = EvalScore.BAD * left
```

With this, the impossible move is unrepresentable, and stale beliefs can never be played -
independently of how they were created.

Extension (this is the legitimate half of section 5 - cards the AI itself has pinned with a
Priest are copies that cannot be anywhere else):

```gdscript
# copies pinned in OTHER players' hands; the target's own belief is deliberately
# excluded, because `mem == m._target_type` means the guess is a certain hit
var pinned := 0
for j in _memory.size():
    if j != m._target_player and _memory[j] == m._target_type:
        pinned += 1
left = max(0, left - pinned)   # clamp: Baron-tie propagation can pin one copy twice
```

This needs no new data - `_memory` is the deciding player's own array, so `eval_moves`
can see every belief it is entitled to use (`_memory[idx]` is never written, so it does not
self-pin). The clamp is what keeps the Baron-tie cloning of section 4 from turning a
unique-copy type negative. With it in place, `left == 0` means "no copy of this type can be
in any unknown hand", which is the exact condition issue 1 needs.

Ordering note: a memory slot is a claim about a *live* hand, so this extension depends on
section 4's `set_inactive` clear. A belief left behind by an eliminated player steals a
copy from the count and makes the guardrail fire too eagerly - the failure direction is
safe (a legal guess scores 0, an illegal one never scores above 0), but it silences good
guesses, so land 4 before this.


2. `return valid_moves[-1]` turns "everything scores 0" into a Princess declaration
-----------------------------------------------------------------------------------

Code (`player.gd:195-203`):

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

When `sum == 0`, `rmove` is forced to 0, the accumulation loop can never satisfy
`sum > rmove`, and the function falls through to the last element of the move list. The
list order is not random: `find_valid_moves` iterates the hand in child order and, for a
Guard, the guessable types in enum order `Priest..Princess` (`main.gd:512`). The last
generated move of a hand containing a Guard is therefore the **Princess guess**.

So "no move looks good" is systematically resolved as "announce Princess". This is the
fallback that produced the reported behaviour before the section 0 fix, and it is still
live for every state that scores all moves 0 - e.g. a hand of `[Princess, Guard]` late in a
round where Priest, Baron, Handmaid, Prince, King and Countess copies are all in discard
(`left_cards` = 0 for every guessable type), which the count branch scores 0.

Measured frequency (30 000 four-player rounds, `tests/prince_memory_sim.py` rules, current
`main.gd`): all-zero-score decisions are 1 215 of 277 443 decisions (0.44%) - most turns
buy a positive score somewhere - and the last generated move is a Guard (the Princess
declaration) in 83 of them, a Prince in 667, a Baron in 75. The mechanism is systematic, the
frequency is not: see section 3's knock-on list.

Fix: make the tie-break uniform instead of positional, and give the probe plays a score of
their own (a Guard played as a probe is not worthless - it is cheap pressure and it keeps
the hand):

```gdscript
if sum == 0:
    return valid_moves[randi() % len(valid_moves)]
```

Note that a 0-score move can never be returned by the weighted loop itself: reaching move
k implies `sum(0..k-1) <= rmove`, so a 0-score move cannot push the accumulation above
`rmove`. Only the fallback can play them.


3. `EvalScore.GOOD * m._target_type`: the premise was wrong, the value is 400, not 0
   (severity L, was H) - NOT AN ISSUE
------------------------------------------------------------------------------------

The old text of this section assumed `_target_type` is `Deck.CardType.Unknown == 0`.
`Unknown` is **8**: `deck.gd:3-11` numbers the enum Guard = 0, Priest = 1 ... Princess = 7,
Unknown = 8 (section 5, item 3 of this doc already states it). `find_valid_moves` builds
Baron / Prince / King moves without a target type (`Move.new(cards[i], i, p.idx)`,
`main.gd:516-527`), so the three multiplications evaluate to:

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
   beats the ~16 of the competing plays); issue 1's deck accounting is the guardrail.

Knock-ons inside this doc:

- section 1's "350 - the highest number in the scoring table": 400 is higher. Section 1's
  `GOOD * (1 + mem)` reproduces 400 for the unique card, which is why the fixed scoring
  tables in section 4 read continuously with the shipped ones;
- section 2's "every state that scores all moves 0": with 400s in the table those states
  are rare - measured 1 215 of 277 443 four-player decisions (0.44%), and the last
  generated move is a Guard (the Princess declaration) in 83 of them (~0.03% of decisions),
  a Prince in 667, a Baron in 75;
- section 5 item 3 (`CardType` has 9 values with `Unknown == 8`) is the fact this section
  was written against.

Related, same table: `EvalScore` has no branch for a played Princess (`eval_moves`
initialises `_score = LOSE` at `player.gd:223` and the `match` has no Princess case), which
is correct by accident - playing the Princess is suicide. `find_valid_moves` has no Princess
case either (`main.gd:505-527`), so the AI is never offered that move; the human is, and a
human can play it.

4. The Prince cleared the belief about its own player, not about the rival whose hand
    changed (severity H for level 4) - FIXED
---------------------------------------------------------------------------------------------

The rule the memory model implies, and which the King branch already implements correctly
(`main.gd:369-376` swaps the two traders' beliefs and the third parties' slots):

> `_memory[i][j] = T` means "player i believes **player j's hand card** is T".
> A belief must be cleared (or moved) exactly when **that card** leaves j's hand.

Two places in `main.gd` broke it:

1. **Prince cleared the wrong slot** (`main.gd:346-348`). The hand that changes is the
   target's; the loop cleared beliefs about the Prince player. Exactly right for a
   self-targeted Prince - which is why the bug survived, the code was written for that case
   - and inverted for the common one.
2. **Elimination cleared nothing** (`set_inactive`, `main.gd:279-286`).

**The third one is not a bug, and a "fix" for it is cheating.** `_on_card_played`
(`main.gd:208-210`) clears every belief about the playing player whose type matches the
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
  indirect: the Baron-tie propagation loop (`main.gd:330-333`) clones a dead seat's belief
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
a Princess belief attached to a *live* rival is normally true, and it travels through the
propagation loop (`main.gd:330-333`, a Baron tie clones a belief from one player's slot into
another's). With this fix the two sources of staleness that loop used to amplify are gone:
the Prince no longer leaves a belief pointing at a card that left the game, and a seat that
left the round has no belief left to clone. Section 1's deck-accounting guardrail stays
needed - a belief can still be true for one player and the guess can still be impossible
when the only copy is pinned in the guesser's own hand.

Verification: `tests/repro_prince_memory.tscn` (A-D assert the behaviour in the engine,
including test D's posterior for the played-card clear, E replays the two Prince decisions
under the shipped, draft and applied policies), `tests/smoke_games.tscn` (300 AI-driven
rounds, 137 eliminations, no script error), and the pre-existing
`tests/repro_guard_princess.tscn`, which still passes with these changes.

5. `_left` counts widow cards and cards in hands - by design (severity L, was M)
--------------------------------------------------------------------------------

Verdict: not a bug. `Deck` maintains one invariant - `Deck.prepare` (`deck.gd:48-63`)
initialises it and `Main.discard()` (`main.gd:405-416`) is the only writer:

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
  (`main.gd:345`, `deck.gd:66-71`) pops from `_widow_cards` when the draw pile is empty.

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
   personally revealed into somebody else's hand. This is **issue 1's guardrail** (see the
   extension under section 1) - the `unknown_hands` denominator of the drafted
   `probability = free_copies / unknown_hands` helper is identical for every Guard guess in
   a turn, i.e. a constant multiplier that changes nothing inside a turn. Do it as part of
   1, not as deck surgery.
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

Summary
-------

| # | Issue | Severity | Where | Symptom in play |
|---|---|---|---|---|
| 1 | Stale Princess belief scored 350, deck accounting ignored | H | `player.gd:226-235` | Guaranteed-failed "Princess" call, Princess stuck in hand |
| 2 | `valid_moves[-1]` tie-break | H | `player.gd:195-203` | All-zero-score turns (0.44% of 4p decisions) play the last generated move - the Princess declaration when a Guard is last in hand |
| 3 | `GOOD * m._target_type` is `GOOD * Unknown == 400`, **not** 0: known Baron wins and Princess-killing Princes are played, not suppressed | L (was H) | `player.gd:230,244,258` | none in play - latent: enum ordinal inside the score formula, no rank scaling for kills, 400 pays false beliefs too. **Not an issue**, `tests/repro_score_multiplier.tscn` |
| 4 | Memories did not follow the hand card (Prince cleared the Prince player's slot, eliminations cleared nothing, plays cleared on type) | H for level 4 | `main.gd:346-348`, `279-286`, `208-210` | Guaranteed-failed Guard call paid 150 and played 63% of the time; Priest knowledge destroyed. **Fixed**, `tests/repro_prince_memory.tscn` |
| 5 | `_left` counts widow + hand cards = correct pool; only pinned copies are missing | L | `deck.gd:48-63`, `player.gd:232-237` | Guaranteed-failed Guard guesses score 5 instead of 0 (fix folded into 1) |

Sections 1 and 2 are the two halves of the reported "level 4 plays Guard and says
Princess"; section 0 (the Guard-memory check) removed its most frequent trigger, sections 1
and 2 remove the remaining triggers, section 3 is closed as not an issue (the 0 it claimed is
`GOOD * Unknown == 400`; the known Baron wins are played in 94% of the opportunities and the
Princess kills in 78%, measured in `tests/repro_score_multiplier.tscn`), leaving a latent
enum-ordinal note, section 4 is fixed (beliefs are
cleared and moved with the hand card they name, and the tests in `tests/README.md` pin that
down), and section 5 turned out to be the counting model working as designed (`_left` is the
exact posterior pool for a Guard guess) - downgraded to L, with the widow deliberately kept
hidden from the AI.
