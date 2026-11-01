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
  (`find_valid_moves` emits guesses in enum order `Priest..Princess`, `main.gd:512`).
  See `ai_memory_open_issues.md` §2.

### Score constants

`LOSE=0, BAD=5, WEAK=10, MODERATE=20, GOOD=50`; `CardType` is ordered `Guard=0 … Princess=7`
(`deck.gd:4-14`), so `GOOD * type` tops out at **50×7 = 350**.

`my_type` = the card **kept** in hand (`1 - played_card_idx`), `mem` = `_memory[target]`.

`m._target_type` is the *guessed* card, and it is only ever set for Guard moves
(`main.gd:512`); for Baron/Prince/King moves it stays `Unknown == 0`, so every
`GOOD * m._target_type` outside the Guard branch evaluates to **0 == LOSE**
(`ai_memory_open_issues.md` §3). The table below shows *intended* and *effective* values.

### Scoring by played card

| Card played | Branch | Score | Effective |
|---|---|---|---|
| **Guard** | known belief (and belief is not `Guard` — a Guard can never be a legal guess, `player.gd:226-228`), belief == the guess | `GOOD × guess` | 50 … 350 |
| | known belief, guess is wrong | `LOSE` | 0 |
| | belief `Unknown` **or** `Guard` → card-count probe: `left_cards[guess]` minus the copies of `guess` in my own hand (`:233-236`) | `BAD × left` | 0 … 10 (only Priest/Baron/Handmaid/Prince have 2 copies) |
| **Priest** | target unknown | `MODERATE` | 20 |
| | target known | `LOSE` | 0 |
| **Baron** | known and my card beats theirs | `GOOD × type` | **0** (intended 100-350) |
| | known and tie | `WEAK` | 10 |
| | known and my card loses | `LOSE` | 0 |
| | unknown, my card > Handmaid | `MODERATE` | 20 |
| | unknown, my card ≤ Handmaid | `BAD` | 5 |
| **Handmaid** | always | `MODERATE` | 20 |
| **Prince** (self) | kept card is the Princess | `LOSE` | 0 |
| | kept card > Handmaid | `BAD` | 5 |
| | kept card ≤ Handmaid | `WEAK` | 10 |
| **Prince** (other) | known Princess holder | `GOOD × type` | **0** (intended 350) |
| | known card > Handmaid | `WEAK` | 10 |
| | known card ≤ Handmaid | `LOSE` | 0 |
| | unknown | `WEAK` | 10 |
| **King** | my card == their known card (safe swap) | `WEAK` | 10 |
| | known and my card is lower | `MODERATE` | 20 |
| | known and my card is higher | `BAD` | 5 |
| | unknown | `BAD` | 5 |
| **Countess** | always | `BAD` | 5 (forced when Countess + Prince/King is in hand, `countess_restricted` `:121-129`; in that case `find_valid_moves` offers only the Countess) |
| **Princess** | no branch — never scored | `LOSE` | 0 (and never offered as a move, `main.gd:505-527`) |

Net effect: **every guaranteed kill scores 0**, so Level 4 rarely plays them — a Handmaid
(20) out-competes a Baron it knows it wins, and a known Princess in a rival's hand is never
burned with a Prince. The only high scores the AI can actually reach are correct Guard
guesses; everything else lives in the 5-20 band.

`eval_moves` is also called for the **human** player (`main.gd:181`) purely to print the
score table when `print_valid_moves` is on — it does not constrain the human's choice.

### Strengths

- **Memory-driven**: uses `_memory` for Guard/Baron/Prince/King decisions, so known cards
  are treated as facts (`player.gd:222`).
- **Card-count probing for Guard guesses**: `left_cards[guess]` is the correct Bayesian
  prior — `_left` starts at full card counts and is decremented on every discard
  (`main.gd:411`), so it tracks exactly the cards the AI cannot see; the code also removes
  the copies it holds itself. Guessing the most numerous remaining type is a genuinely
  Love-Letter-specific insight.
- **Weighted random** keeps the AI imperfect: good moves are *more* likely, bad moves still
  happen, which makes it a beatable opponent rather than a solver.
- **Rank-weighted kills** (`GOOD × type`) express "eliminating a higher card is worth more"
  — correct intent, realised only for Guard.
- **King is the best modelled card**: safe swap, trading down, trading up and blind trade
  are four distinct scores (10 / 20 / 5 / 5).
- **Prince on self** distinguishes self-kill from safe self-play (0 vs 5/10).

### Weaknesses

- **No lookahead**: only the current turn is scored. Deck exhaustion, the race to
  `_max_score` (6 / 5 / 4 points for 2 / 3 / 4 players, `main.gd:109-114`), holding a card
  for later, and who plays next are all invisible to the evaluation.
- **Guaranteed kills score 0** (`GOOD * 0`, see table): the AI systematically prefers passive
  20-point moves over winning a Baron or burning a Princess.
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
- **Memory hygiene is lossy**: Prince clears the wrong slot, eliminations clear nothing, so
  Level 4 acts on stale beliefs (`ai_memory_open_issues.md` §4).
- **Protection is only implicit**: `find_valid_moves` filters protected targets (and self on
  Prince), so the AI never *sees* an illegal move — it does not weigh "keep the Handmaid for
  later".
- **Stakes-blind**: `GOOD × type` ignores that eliminating the player at 3 points (in a 4-player
  game, where `_max_score = 4`) is match-point, while eliminating a 0-point player is not.

### Effective strength

Strongest of the scripted levels: in the speed-run runs recorded in `speedrun.txt` (six
1000-game runs, levels 1-4 in fixed order, Level 4 seated at player 3) the Level 4 seat has
the highest total score in every run (2694-2923 vs 1329-1547 for Level 1). Two caveats:
player order and seeds are fixed, so position bias is baked in, and the runs predate the Oct 31
Guard-memory fix. Its aggression is also capped by the zero-scored kills above, so it plays
passively far more often than a human would.

Treat the old "~40-60% of rounds vs a random opponent in a 4-player game" figure as unmeasured
folklore. Before quoting numbers, re-run with shuffled player order and rotating seeds
(`strength_evaluation.md`, `speedrun.txt` run 2 onwards).
