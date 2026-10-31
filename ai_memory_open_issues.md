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

The four issues below are what remains.


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


5. `left_cards` counts cards that cannot be drawn (severity M)
--------------------------------------------------------------

`Deck.prepare` (`deck.gd:48-63`) resets `_left` to the full deck composition, then moves
`widow_count` cards into `_widow_cards` (1 card for 3-4 players, 3 cards for a 2-player
game). Only `Main.discard()` decrements `_left` (`main.gd:405-416`). Consequences for the
level 4 heuristic `EvalScore.BAD * left_cards[t]`:

- the widow cards are counted as available forever, so every probability is inflated. With
  2 players, 3 of the 16 cards are permanently out of reach and the AI's ranking is skewed
  by them - in a 2-player game the Princess is in the widow roughly 3 times more often than
  the raw count suggests;
- `_left` also counts cards currently sitting in other players' hands, including cards the
  AI itself has *pinned* with a Priest. The only subtraction is the AI's own two cards
  (`player.gd:231-234`). A belief that "player 2 holds the King" is used by the Baron and
  King branches, but is not subtracted from the Guard guess counts, so the AI over-values
  types it knows are already elsewhere;
- the Prince player's own card and the target's new card are in hand/deck, and neither is
  accounted for.

Fix, in order of cost:

1. in `Deck.prepare`, decrement `_left` for each widow card:
   ```gdscript
   for i in widow_count:
       var w = _cards.pop_front()
       _widow_cards.append(w)
       _left[w] -= 1
   ```
2. normalise the Guard estimate by the number of unknown hands, and subtract the cards
   pinned in known hands (a `probability = free_copies / unknown_hands` helper, as drafted
   in `tests/README.md` discussion). This also subsumes issue 1's guardrail: `free_copies`
   reaching 0 makes the guess score 0.
3. keep `_left` as the single source of truth: decrement on widow setup and never let
   `_left` count cards that are in hands.

Note: `_left` has 8 entries (`card_count.size()`), while `CardType` has 9 values with
`Unknown == 8`. Nothing indexes `_left[Unknown]`, so this is currently harmless, but any
loop over `CardType` would run off the end.


Summary
-------

| # | Issue | Severity | Where | Symptom in play |
|---|---|---|---|---|
| 1 | Stale Princess belief scored 350, deck accounting ignored | H | `player.gd:226-235` | Guaranteed-failed "Princess" call, Princess stuck in hand |
| 2 | `valid_moves[-1]` tie-break | H | `player.gd:195-203` | Every all-zero-score turn becomes a Princess declaration |
| 3 | `GOOD * m._target_type` (0) | H | `player.gd:230,244,258` | Winning Baron and Princess-killing Prince never played |
| 4 | Prince clears the Prince player's slot; eliminations clear nothing | M | `main.gd:346-348`, `279-286` | Rival believed to hold a discarded card; Priest knowledge lost |
| 5 | `_left` counts widow cards and cards in hands | M | `deck.gd:48-63` | Guard guesses biased toward types that cannot be there |

Sections 1 and 2 are the two halves of the reported "level 4 plays Guard and says
Princess"; section 0 (the Guard-memory check) removed its most frequent trigger, sections 1
and 2 remove the remaining triggers, and sections 3-5 are the score/accounting work that
makes level 4's play match the scoring table it already prints.
