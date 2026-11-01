## Love Letter AI Strategy Analysis

### Background: Card Hierarchy & Scoring

Cards rank from lowest to highest:
```
Guard(0) < Priest(1) < Baron(2) < Handmaid(3) < Prince(4) < King(5) < Countess(6) < Princess(7)
```
Counts: 5G, 2Pris, 2Ba, 2Ha, 2Prin, 1Ki, 1Co, 1Pru = 16 cards total. Each player holds 2 cards, plays 1.

---

### Level 1: "First Valid Move" (Greedy Sequential)

```gdscript
return valid_moves[0]
```

**Strategy:** Always picks the first move in the list returned by `find_valid_moves()`.

**Behavior:** The order in `find_valid_moves()` is deterministic:
1. Iterates left-to-right through the player's 2 cards (index 0, then 1)
2. For Guard: iterates players sequentially, then type (Priest→Unknown)
3. Other cards iterate players in order

**Evaluation:**
- **Pros:** Extremely fast, consistent, easy to debug
- **Cons:** Completely predictable; always favors the same card and same target. Will never deviate regardless of situation. Essentially a "dumb bot" — but the ordering bias gives it a weak systematic preference (e.g., always tries Guard first if holding Guard).
- **Effective strength:** ~0. In a competitive setting, you'd exploit it in one game and always know the move.

---

### Level 2: "Random Valid Move" (Uniform Sampling)

```gdscript
return valid_moves[randi() % len(valid_moves)]
```

**Strategy:** Uniform random selection among all valid moves.

**Evaluation:**
- **Pros:** Unpredictable; introduces meaningful variance. Guards are weighted proportionally to how many Guard-vs-X guesses are available (5 guards × 5 targets × 5 types = lots of Guard moves in the list).
- **Cons:** No strategic reasoning at all. Will randomly play Countess as a pass when it could do something useful. Will randomly guard-check with Guard=Guard (useless). Will randomly Baron-check when it has a Baron and the target is unknown (50% chance of losing).
- **Effective strength:** ~Low. Better than Level 1 because unpredictability adds a small edge, but fundamentally random. In simulation (1000 games), would perform near the bottom against any strategy with information.

---

### Level 3: "Prefer Cheaper Card" (Cost-Aware Selection)

```gdscript
var cheaper_idx = 0 if hand.get_child(0).type <= hand.get_child(1).type else 1
var filtered: Array[Move]
for m in valid_moves:
    if m._played_card_idx == cheaper_idx:
        filtered.append(m)
if filtered.is_empty():
    filtered.append_array(valid_moves)
return filtered[randi() % len(filtered)]
```

**Strategy:** Identifies the cheaper (lower card type) card in hand, filters moves to prefer playing that card, then picks randomly among those. Falls back to all moves if no valid move exists for the cheaper card (i.e., the cheaper card is a Handmaid/Countess pass, which has no targeting).

**Evaluation:**
- **Pros:** Introduces the concept of **cost management** — don't waste a powerful card (like King) when a cheap card (Guard) will do. This is a real strategic principle in Love Letter. The fallback handles the case where the cheaper card is a non-targeting card.
- **Cons:** 
  - Only considers card *type value*, not card *utility*. Will still prefer playing a Baron over a Princess (which is correct — you'd rather Baron than Princess-die), but would also prefer Baron over Countess when Countess pass is actually better.
  - Random within the filtered set, so no evaluation of target quality. Could still guard-check randomly or Prince any player.
  - Ignores memory entirely.
- **Effective strength:** ~Medium. Significantly better than Level 2 because cost awareness is a genuine strategic advantage. Still quite weak against Level 4.

---

### Level 4: "Score-Based Weighted Random" (Probabilistic Evaluation)

```gdscript
eval_moves(valid_moves, left_cards)  # assigns m._score to each move
# Weighted random selection using scores as weights
```

**Evaluation function** assigns scores from 0 (LOSE) to ~210 (GOOD×7) based on:

| Card Played | Logic | Score Range |
|---|---|---|
| **Guard** | If memory knows target's card: `GOOD × type` if correct guess, else LOSE. If unknown: uses card-count remaining (`left_cards` array) — more of a type = higher score. | 0 to ~210 |
| **Priest** | If target's card unknown: `MODERATE` (20). Otherwise LOSE. | 0 to ~20 |
| **Baron** | If memory known: `GOOD × type` if my card > theirs, else `WEAK` (10). If unknown: `MODERATE` if my card > Handmaid, else `BAD` (5). | 0 to ~210 |
| **Handmaid** | Fixed `MODERATE` (20). Safe but passive. | 20 |
| **Prince** | Self + unknown Princess: `GOOD × type`. Self + known Princess: same. Self + >Handmaid: `WEAK`. Others known Princess: `GOOD × type`. Others >Handmaid: `WEAK`. | 0 to ~210 |
| **King** | Same-card swap: `WEAK` (10). Unknown: `BAD` (5). Known different: `BAD`. Known higher: `BAD`. | 5 to 10 |
| **Countess** | Always `BAD` (5). Forced play when Countess+Prince/King/Men present. | 5 |

**Strengths:**
- Uses **memory** (`_memory` array) for informed decisions on known cards
- Uses **card-count remaining** (`left_cards`) for Guard probability estimation — a very Love-Letter-specific insight (Guard is a guessing game, so you guess the most numerous remaining type)
- Weighted random selection means good moves are chosen more often, but bad moves can still happen (simulates "imperfect" decision-making rather than perfect play)
- The `GOOD` score is multiplied by `m._target_type`, meaning higher-ranked cards are worth more to eliminate — correct strategic thinking

**Weaknesses:**
- **No lookahead:** Doesn't consider the game state beyond the current turn. Doesn't account for:
  - How many cards remain in the deck (endgame pressure)
  - How close any player is to winning (score)
  - The trade-off between playing a card now vs. holding it for later
  - Turn order implications (which player goes next after this)
- **Guard probability is crude:** Only uses `left_cards` array counts, not accounting for cards already revealed or in other players' hands
- **Baron risk is incomplete:** Doesn't factor in how likely the opponent is to be holding a higher card given what's been played/revealed
- **Prince self-evaluation is weak:** The scoring for Prince on self doesn't distinguish between "I have Guard (safe)" vs "I have Princess (death)" very well
- **Score multipliers are arbitrary:** `GOOD * type` (e.g., GOOD×7=350 for Princess) creates very uneven score distributions, making the weighted random heavily biased toward high-value targets
- **Doesn't consider protection state well** in all cases

**Effective strength:** ~High. Much better than the other levels, but not perfect. Would likely win ~40-60% of rounds against a random opponent in a 4-player game, depending on seed.

---

### Summary Comparison

| Aspect | L1: First | L2: Random | L3: Cheaper | L4: Weighted |
|---|---|---|---|---|
| **Predictability** | 100% | 0% | Low | Low |
| **Uses memory** | No | No | No | Yes |
| **Uses deck counts** | No | No | No | Yes (Guard only) |
| **Considers cost** | No | No | Yes | Indirectly |
| **Considers risk** | No | No | No | Yes |
| **Strategic depth** | None | None | Low | Medium |
| **Looks ahead** | No | No | No | No |

### Recommendation

**Level 4 is the only one with actual strategic reasoning**, but it has room for improvement. The biggest missing pieces would be:
1. **Endgame awareness** — adjusting strategy when few deck cards remain
2. **Score-awareness** — playing more conservatively when leading, aggressively when behind
3. **Better Prince self-evaluation** — Prince is the most powerful card; the scoring should reflect its unique power more clearly
4. **Baron risk quantification** — using remaining card distributions to estimate Baron win probability
