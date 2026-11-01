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

The four issues below are what remains (section 5 is kept for completeness - it turned out
to be the model working as designed).


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
itself holds the Princess, the guess is impossible, yet it scores 350 - the highest number
in the scoring table - so the weighted random in `select_move` picks it with probability
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


3. `EvalScore.GOOD * m._target_type` zeroes the best moves of the game (severity H)
------------------------------------------------------------------------------------

`m._target_type` is the *guessed* card of a Guard move; for every other card,
`find_valid_moves` builds the move without a type (`Move.new(cards[i], i, p.idx)`,
`main.gd:516-527`), so `_target_type` is `Deck.CardType.Unknown == 0`. Three branches
multiply by it:

| line | branch | intended value | actual value |
|---|---|---|---|
| `player.gd:230` | Guard, correct guess | GOOD x rank of the kill | `GOOD * Guard == 0` for a Guard target (now unreachable, see section 0) |
| `player.gd:244` | Baron, `my_type > mem` (we win, rival eliminated) | GOOD x rank | `GOOD * 0 = 0` = LOSE |
| `player.gd:258` | Prince on a known Princess holder | GOOD x rank, the best kill in the game | `GOOD * 0 = 0` = LOSE |

So a level 4 AI can never score a guaranteed Baron win above LOSE, and can never score the
Princess-kill Prince above LOSE. Since moves scoring 0 are unreachable for the weighted
loop (see section 2), these moves are effectively *never played* by level 4/5: the AI
prefers a Handmaid (20) over eliminating a rival with a Baron it knows it wins, and it will
not burn a known Princess out of a rival's hand.

Fix: multiply by the rank of the *known* card (the card that is being eliminated), with a
rank factor that never zeroes:

```gdscript
m._score = EvalScore.GOOD * (1 + mem)     # Guard on Guard = 50, King = 300, Princess = 400
```

`mem` is defined and known in all three branches (`player.gd:222`). This keeps the author's
"higher cards are worth more" intent, restores Guard-on-Guard, Baron wins and Prince kills,
and makes the AI's elimination decisions match the printed score tables.

Related, same table: `EvalScore` has no branch for a played Princess (`eval_moves`
initialises `_score = LOSE` at `player.gd:223` and the `match` has no Princess case), which
is correct by accident - playing the Princess is suicide. `find_valid_moves` has no Princess
case either (`main.gd:505-527`), so the AI is never offered that move; the human is, and a
human can play it.


4. Prince clears the wrong memory slot; eliminations clear nothing (severity M, H for level 4)
---------------------------------------------------------------------------------------------

Code (`main.gd:338-348`):

```gdscript
Deck.CardType.Prince:
    var type = tp.hand.get_child(0).type
    await discard(tp.hand)
    if type == Deck.CardType.Princess:
        await set_inactive(tp, false)
    else:
        await deal_card(tp, true)
        for pl in _players:
            if pl.idx != _cur_player:
                pl.update_memory(_cur_player)  # hand is unknown now
```

The hand that changed is the **target's** (`tp` discarded its card and drew a new one),
but the loop clears beliefs about the **Prince player** (`_cur_player`). Two effects:

1. every belief about `tp` - including the AI's own freshly-revealed one - survives and
   points at a card that has left the game. This is a genuine stale memory: `_memory[*][tp]`
   becomes false, and (via issue 1) it is then played greedily.
2. beliefs about the Prince player are erased for everybody, even though that player's
   remaining card never changed. Valid information is destroyed every time a Prince is
   played on somebody else - the AI forgets what it learned with its own Priest.

For self-targeted Prince (`tp.idx == _cur_player`) the line is exactly right, which is why
the bug survived: the code was written for the self case.

Second half of the issue: `set_inactive` (`main.gd:279-286`) discards the eliminated
player's hand and never touches memories. Beliefs about dead players stay forever (they are
inert for targeting, because `find_valid_moves` filters on `is_active()`, but they are read
by the Baron-tie propagation loop, `main.gd:330-333`, and they survive until the round
ends).

Fix:

```gdscript
    else:
        await deal_card(tp, true)
        for pl in _players:
            pl.update_memory(tp.idx)           # tp's new hand is unknown to everybody
            if pl.idx != _cur_player:
                pl.update_memory(_cur_player)  # the Prince player discarded his hand too
```

and in `set_inactive`:

```gdscript
for pl in _players:
    pl.update_memory(p.idx)                    # a eliminated player has no hand to believe in
```

(The self-Prince case collapses to a single clear, since `tp.idx == _cur_player`.)

Reachability note for the "stale Princess" story: the Princess leaves a live player's hand
only through the King trade, and the King branch rewrites memories correctly
(`p.update_memory(tp.idx, my_card.type)`, `tp.update_memory(p.idx, their_card.type)`, third
parties swap, `main.gd:369-376`). Removing the Princess by Prince, by playing it, or by
losing a Baron/Guard duel eliminates its owner. So a Princess belief attached to a *live*
rival is normally true; it becomes false through the propagation path
(`main.gd:330-333`, a Baron tie copies a belief from one player to another, cloning any
staleness in the source slot) - which requires the staleness created by this issue. That is
why fixing 4 is what makes issue 1 reachable in real play.


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
| 2 | `valid_moves[-1]` tie-break | H | `player.gd:195-203` | Every all-zero-score turn becomes a Princess declaration |
| 3 | `GOOD * m._target_type` (0) | H | `player.gd:230,244,258` | Winning Baron and Princess-killing Prince never played |
| 4 | Prince clears the Prince player's slot; eliminations clear nothing | M | `main.gd:346-348`, `279-286` | Rival believed to hold a discarded card; Priest knowledge lost |
| 5 | `_left` counts widow + hand cards = correct pool; only pinned copies are missing | L | `deck.gd:48-63`, `player.gd:232-237` | Guaranteed-failed Guard guesses score 5 instead of 0 (fix folded into 1) |

Sections 1 and 2 are the two halves of the reported "level 4 plays Guard and says
Princess"; section 0 (the Guard-memory check) removed its most frequent trigger, sections 1
and 2 remove the remaining triggers, sections 3 and 4 are the score/accounting work that
makes level 4's play match the scoring table it already prints, and section 5 turned out to
be the counting model working as designed (`_left` is the exact posterior pool for a Guard
guess) - downgraded to L, with the widow deliberately kept hidden from the AI.
