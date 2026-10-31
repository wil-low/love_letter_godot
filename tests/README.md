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
