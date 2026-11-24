### Level 4: "Score-Based Weighted Random" (Probabilistic Evaluation)

Reference for the code in `player/player.gd` (`select_move` `:159-206`, `EvalScore`
`:209-215`, `eval_moves` `:218-271`). This document describes what the code *actually
does*, not what the scoring table intends — the intent/bug list lives in
`ai_memory_open_issues.md`.

```gdscript
eval_moves(valid_moves, left_cards)  # assigns m._score to each move
# weighted random selection using scores as weights
```

Level 4 is also the "best" strategy that **Level 5** can pick: Level 5 has no strategy of
its own, it re-rolls a Level 1-4 strategy every turn (`player.gd:162-164`).

### Selection loop (`player.gd:187-203`)

Scores are summed, then a move is drawn with probability `_score / sum`. Two properties
matter:

- **A 0-score move can never be picked by the weighted loop.** Reaching move *k* requires
  `sum(0..k-1) > rmove`, which a 0-score move cannot produce.
- If **all** moves score 0, `sum` is forced to 1, `rmove` becomes 0, the loop never
  satisfies `sum > rmove`, and the function falls through to `valid_moves[-1]` — the
  *last generated* move, which for a hand containing a Guard is the **Princess guess**
  (`find_valid_moves` emits guesses in enum order `Priest..Princess`, `main.gd:528-530`).
  See `ai_memory_open_issues.md` §2.

### Score constants

`LOSE=0, BAD=5, WEAK=10, MODERATE=20, GOOD=50`; `CardType` is ordered `Guard=0 … Princess=7`
with `Unknown=8` (`deck.gd:4-14`), so `GOOD * type` tops out at **50×8 = 400**, on
`Unknown`; for a named card it tops out at **50×7 = 350**.

`my_type` = the card **kept** in hand (`1 - played_card_idx`), `mem` = `_memory[target]`.

`m._target_type` is the *guessed* card, and it is only ever set for Guard moves
(`main.gd:528-530`); for Baron/Prince/King moves it stays `Unknown == 8`, so every
`GOOD * m._target_type` outside the Guard branch evaluates to **400**, the top score of the
table (`ai_memory_open_issues.md` §3 - the reading "`Unknown == 0`, so 0 == LOSE" is wrong and
the claim built on it, "guaranteed kills score 0", is measured false: these kills are played in
94% / 78% of the opportunities). The table below shows *intended* and *effective* values.

### Scoring by played card

| Card played | Branch | Score | Effective |
|---|---|---|---|
| **Guard** | known belief (and belief is not `Guard` — a Guard can never be a legal guess, `player.gd:226-228`), belief == the guess | `GOOD × guess` | 50 … 350 |
| | known belief, guess is wrong | `LOSE` | 0 |
| | belief `Unknown` **or** `Guard` → card-count probe: `left_cards[guess]` minus the copies of `guess` in my own hand (`:233-236`) | `BAD × left` | 0 … 10 (only Priest/Baron/Handmaid/Prince have 2 copies) |
| **Priest** | target unknown | `MODERATE` | 20 |
| | target known | `LOSE` | 0 |
| **Baron** | known and my card beats theirs | `GOOD × type` | **400** (the multiplier reads `Unknown`, not the rival's card) |
| | known and tie | `WEAK` | 10 |
| | known and my card loses | `LOSE` | 0 |
| | unknown, my card > Handmaid | `MODERATE` | 20 |
| | unknown, my card ≤ Handmaid | `BAD` | 5 |
| **Handmaid** | always | `MODERATE` | 20 |
| **Prince** (self) | kept card is the Princess | `LOSE` | 0 |
| | kept card > Handmaid | `BAD` | 5 |
| | kept card ≤ Handmaid | `WEAK` | 10 |
| **Prince** (other) | known Princess holder | `GOOD × type` | **400** (the multiplier reads `Unknown`) |
| | known card > Handmaid | `WEAK` | 10 |
| | known card ≤ Handmaid | `LOSE` | 0 |
| | unknown | `WEAK` | 10 |
| **King** | my card == their known card (safe swap) | `WEAK` | 10 |
| | known and my card is lower | `MODERATE` | 20 |
| | known and my card is higher | `BAD` | 5 |
| | unknown | `BAD` | 5 |
| **Countess** | always | `BAD` | 5 (forced when Countess + a card ranked 5+ - Prince/King/Princess - is in hand, `countess_restricted` `:121-134`; in that case `find_valid_moves` offers only the Countess) |
| **Princess** | no branch — never scored | `LOSE` | 0 (and never offered as a move, `main.gd:512-543`) |

Net effect: the two guaranteed kills (a Baron the AI knows it wins, a Prince on a known
Princess) score **400 - the top of the table**, so they are played, not suppressed: measured in
94% of the opportunities and 78% respectively (`ai_memory_open_issues.md` §3). What the enum
ordinals buy is not suppression but flatness: a Baron win on a Countess and one on a Princess
cost the same 400, because the multiplier reads `Unknown` where the rank of the kill was meant to
be read. Only correct Guard guesses carry rank scaling; the rest of the table lives in the 5-20
band.

`eval_moves` is also called for the **human** player (`main.gd:181`) purely to print the
score table when `print_valid_moves` is on — it does not constrain the human's choice.

### Strengths

- **Memory-driven**: uses `_memory` for Guard/Baron/Prince/King decisions, so known cards
  are treated as facts (`player.gd:222`).
- **Card-count probing for Guard guesses**: `left_cards[guess]` is the correct Bayesian
  prior — `_left` starts at full card counts and is decremented on every discard
  (`main.gd:421`), so it tracks exactly the cards the AI cannot see; the code also removes
  the copies it holds itself. Guessing the most numerous remaining type is a genuinely
  Love-Letter-specific insight.
- **Weighted random** keeps the AI imperfect: good moves are *more* likely, bad moves still
  happen, which makes it a beatable opponent rather than a solver.
- **Rank-weighted kills** (`GOOD × type`) express "eliminating a higher card is worth more"
  — realised for Guard, where `type` is the guess, and flattened to 400 for Baron and Prince,
  where `type` is `Unknown`.
- **King is the best modelled card**: safe swap, trading down, trading up and blind trade
  are four distinct scores (10 / 20 / 5 / 5).
- **Prince on self** distinguishes self-kill from safe self-play (0 vs 5/10).

### Weaknesses

- **No lookahead**: only the current turn is scored. Deck exhaustion, the race to
  `_max_score` (6 / 5 / 4 points for 2 / 3 / 4 players, `main.gd:109-114`), holding a card
  for later, and who plays next are all invisible to the evaluation.
- **Guaranteed kills are rank-blind**: they score 400 and are played (94% / 78% of the
  opportunities), but a Baron win worth a match point and one worth nothing cost the same.
- **0-score moves are unplayable**, and the all-zero fallback is positional, not uniform —
  it lands on the Princess guess.
- **Score multipliers are arbitrary**: `GOOD × type` (50 → 350) sits next to fixed 5-20
  scores, so the distribution is very uneven and the probe branch (max 10) is compressed
  relative to a passive Handmaid (20). This is a calibration question, not a bug
  (`ai_memory_open_issues.md` §5.2).
- **`left_cards` blind spots**: widow cards and cards in other players' hands are counted as
  available targets (by design, `ai_memory_open_issues.md` §5), and a card already pinned in a
  known hand is not subtracted from the count.
- **Baron/Prince risk is not probabilistic**: with no belief, Baron is scored on my card
  alone (`> Handmaid ? 20 : 5`); the likelihood of the rival holding a higher card, given
  what is in discard, is not considered.
- **Memory depth is single-author**: `_memory` records only what this seat itself revealed
  (Priest) or deduced (Baron tie, King trade). That is the rule, not a limitation: the Priest card
  says the peek is secret, so a reveal made by another seat is information this seat is *not*
  entitled to (`ai_memory_open_issues.md` §6.1), and a Baron tie is public through its outcome, not
  through the compared cards (§6.2). The one public channel no seat records is the Guard answer
  (§6.3, open), so the model sees the table through the hand of one player - deliberately.
- **Protection is only implicit**: `find_valid_moves` filters protected targets (and self on
  Prince), so the AI never *sees* an illegal move — it does not weigh "keep the Handmaid for
  later".
- **Stakes-blind**: `GOOD × type` ignores that eliminating the player at 3 points (in a 4-player
  game, where `_max_score = 4`) is match-point, while eliminating a 0-point player is not.

### Effective strength

Strongest of the scripted levels: in the speed-run runs recorded in `speedrun.txt` (six
1000-game runs, levels 1-4 in fixed order, Level 4 seated at player 3) the Level 4 seat has
the highest total score in every run (2694-2923 vs 1329-1547 for Level 1). Two caveats:
player order and seeds are fixed, so position bias is baked in, and the runs predate both the
Oct 31 Guard-memory fix and the November memory-bookkeeping fix (§4). Measured recently, with
shuffled seats and 10 000 games per player count: Level 4 wins 50.8% of 2-player games, 33.6%
of 3-player games and 25.5% of 4-player games when every seat is Level 4
(`tests/ai_policy_sim.py` / `tests/issue2_tiebreak_sim.py` - i.e. the seat advantage is the
early-seat advantage, and the policy variants sit within 0.25pp of each other).

Treat the old "~40-60% of rounds vs a random opponent in a 4-player game" figure as unmeasured
folklore. Before quoting numbers, re-run with shuffled player order and rotating seeds
(`strength_evaluation.md`, `speedrun.txt` run 2 onwards).
