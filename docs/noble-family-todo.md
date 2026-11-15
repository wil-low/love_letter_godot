# Noble Family Variant — Implementation TODO

Detailed, ordered, single-level checklist. Work **one step at a time**, finish and verify
each step before starting the next. Never leave the project in a state where classic mode is
broken: after every step the classic path must still run headless games
(`godot --headless --path . tests/smoke_games.tscn` exits `0`).

Decisions come from `GRILL-ME.md`; they are not re-litigated here.

## Fixed rules (do not re-decide during implementation)

- Deal (16 cards): burn/widow **3 / 1 / 0** for 2 / 3 / 4 players; **1** first-hand card per
  seat (not part of the family); family **5 / 4 / 3** per seat; main pile leftovers **1 / 0 / 0**.
- 4p burns nothing → in 4p there is **no widow pile**.
- Turn: draw from own family **first** (mandatory), then play 1 of 2. Hand is 2 cards at
  decision time; the leftover is the active card. Countess rule unchanged.
- Widow = fallback pile for **Prince redraws only**; never drawable at turn start; empty widow
  ⇒ the Prince target is eliminated.
- Round ends at **turn start** when the seat to act has an empty family.
- Eliminated seat: reveal hand + family face-up, then move them to the discard pile, no effects,
  decrement `_deck._left`; clear memories as today.
- `_deck._left` = deck leftovers + widow + all live families (decrement on play and on
  elimination reveal; family draws do not change it).
- Families are private (own face-up, others fully hidden, no counts), re-dealt every round,
  kept as `Array[Deck.CardType]` per seat in **as-dealt order** (no sorting).
- AI levels 1–4 extend `find_valid_moves()` with the draw choice: L1 first valid move,
  L2 uniform random, L3 cheapest play + cheapest draw, L4 existing weighted eval with the
  drawn family card as the leftover card (no new scoring terms).
- Human: cascade face-up family stack in seat 0's free bottom strip (display only) + a modal
  draw panel centered over the Table, no cancel button.
- Menu: new GameMode scene opened by PLAY (`CLASSIC` / `NOBLE FAMILY` / `BACK`);
  `Main.noble_family` set by `application.gd` before `init_players`; mode is **not persisted**;
  `speed_run` stays classic-only.
- Docs spec `docs/Noble family variant.md` stays untouched.

## Phase A — rules core (no UI)

### 1. Mode flag on Main

- **Files:** `main/main.gd`
- **Do:** add `var noble_family: bool = false` near `interrupted`; no behaviour changes.
- **Check:** `godot --headless --path . tests/smoke_games.tscn` → exit `0`.
- **Gate:** flag exists, classic untouched.

### 2. Family storage on Player

- **Files:** `player/player.gd`
- **Do:** add `var family: Array[Deck.CardType] = []`, `func family_size() -> int`,
  `func pop_family(idx: int) -> Deck.CardType`, `func clear_family() -> void` (clears the array;
  visual clearing is added in step 17).
- **Check:** `godot --headless --path . tests/smoke_games.tscn` exits `0` (loads every script, no SCRIPT ERROR).
- **Gate:** API compiles, unused so far.

### 3. Noble deal table in Deck

- **Files:** `deck/deck.gd`
- **Do:** add `const NOBLE_BURN := [0, 0, 3, 1, 0]` and `const NOBLE_FAMILY_SIZE := [0, 0, 5, 4, 3]`
  (index = player count); add `func prepare_noble(player_count: int) -> Array[Array[Deck.CardType]]`
  that shuffles `_cards`, pops the burn into `_widow_cards` (3/1/0), pops 1 card per seat into a
  first-hand array, then pops `NOBLE_FAMILY_SIZE[player_count]` cards per seat into per-seat
  family arrays (all in as-dealt order), leaves the remainder in `_cards`, leaves `_left`
  at full counts, and calls `update_piles()`. Return the per-seat arrays; expose the first-hand
  list via `var first_hand: Array[Deck.CardType]`.
- **Check:** `godot --headless --path . tests/smoke_games.tscn` exits `0`, no SCRIPT ERROR in the log.
- **Gate:** dealing logic exists, no callers yet.

### 4. Deal-table repro test (test-first for the rest of Phase A)

- **Files:** `tests/noble_family_rules.gd`, `tests/noble_family_rules.tscn` (new)
- **Do:** headless `Node` suite that calls `Deck.prepare_noble()` for 2, 3, 4 players and asserts:
  burn/widow sizes 3/1/0; family sizes 5/4/3 and equal per seat; first-hand 1 per seat;
  conservation `burn + first_hand + families + main_left == 16`; `_left` equals
  `Deck.card_count` (nothing decremented); families are permutations of the deck (no card
  duplicated, no card lost). Print a per-case PASS/FAIL line, `_exit_code = 1` on any failure.
- **Check:** `godot --headless --path . tests/noble_family_rules.tscn; echo $?` → `0`.
- **Gate:** the deal table is pinned by an executable test.

### 5. Noble round setup in Main

- **Files:** `main/main.gd`
- **Do:** in `_new_round()`, when `noble_family`: call `_deck.prepare_noble(_player_count)`,
  deal each active seat's first-hand card through the existing animated `deal_card()` path
  extend the signature to `func deal_card(p: Player, allow_widow: bool = false, card_type:
  Deck.CardType = Deck.CardType.Unknown) -> void` — when `card_type` is given, deal that type
  instead of popping from the deck — so the
  first-hand card type comes from `_deck.first_hand`, and assign `_players[i].family =
  families[i]` for active seats only (instant, no animation).
- **Check:** add temporary `print` of family sizes; run `tests/smoke_games.tscn` (classic) → `0`.
- **Gate:** variant round starts with 1 hand card + family arrays per seat.

### 6. Family draw helper in Main

- **Files:** `main/main.gd`
- **Do:** add `func deal_from_family(p: Player, family_idx: int) -> void`: pop
  `p.family[family_idx]`, instantiate `card_scene` in `_animation_layer`, `type =` popped type,
  `faceup = p.idx == 0`, start at the seat's position (`p.global_position`), `await
  Animator.move_card(c, p.drawn_card_position())`, then `p.add_card(c)` + `c.position =
  p.hand.to_local(...)`; play `_deal_audio_player`; **no `_deck._left` change**;
  `_deck.update_piles()` untouched.
- **Check:** script loads; helper unused so far.
- **Gate:** one draw path exists for both human and AI.

### 7. Turn-start branch: family draw or round over

- **Files:** `main/main.gd`
- **Do:** in `new_turn()`, when `noble_family`: replace the `if _deck._main.visible:`
  block with `if p.family.is_empty(): round_over()` / else `await deal_from_family(p, 0)` for
  **all** seats as a temporary placeholder, marked `# TODO(step 20): human modal, AI joint move`
  so the AI does not yet choose the draw.
- **Check:** write `tests/noble_family_smoke.gd` / `.tscn` (copy `tests/smoke_games.gd`
  structure, set `main.noble_family = true`, all-AI levels 4/4/3/2, `Animator._speed = 0`,
  rounds/eliminations counters) and run it: rounds must complete; a round must end when the
  3-card family runs out (4p: expect ~4 plays per seat before round end).
- **Gate:** variant games play and terminate; no infinite turn.

### 8. Move gains the draw

- **Files:** `player/move.gd`
- **Do:** add `_drawn_family_idx: int = -1` (`-1` = classic / no draw choice), `_drawn_type:
  Deck.CardType = Deck.CardType.Unknown`, `_leftover_type: Deck.CardType = Deck.CardType.Unknown`,
  `_drawn_card: Card = null`; extend `_init()` with defaults (keep positional order
  `played_card, played_card_idx, target_player, target_type` and add the new ones last);
  extend `_to_string()` with `", draw " + name + " (#idx)"` and the leftover type.
- **Check:** `godot --headless --path . tests/repro_score_multiplier.tscn; echo $?` → `0`.
- **Gate:** `Move` can describe a (draw, play, target) triple.

### 9. eval_moves scores from types

- **Files:** `player/player.gd`
- **Do:** in `eval_moves()`, compute `var my_type: Deck.CardType = m._leftover_type if
  m._leftover_type != Deck.CardType.Unknown else hand.get_child(1 - m._played_card_idx).type`,
  and move the `assert(hand.get_child_count() == 2, ...)` behind `if m._drawn_family_idx == -1`
  (variant moves are scored before the card is drawn, so the 2-card assert does not apply).
- **Check:** `tests/repro_score_multiplier.tscn`, `tests/repro_guard_princess.tscn`,
  `tests/repro_belief_truth.tscn --rounds=150` all exit `0`.
- **Gate:** classic scoring unchanged; variant moves are scorable without a `Card` node.

### 10. Countess rule over types

- **Files:** `player/player.gd`
- **Do:** add `func countess_restricted_types(a: Deck.CardType, b: Deck.CardType) -> int`
  (the existing Prince/King "men" logic, index 0 = `a` forced, 1 = `b` forced, `-1` = none) and
  make `countess_restricted()` call it with the two hand cards.
- **Check:** classic Countess behaviour via `tests/smoke_games.tscn` → `0`.
- **Gate:** one implementation of the rule, usable for (active, drawn) pairs.

### 11. find_valid_moves: joint (draw, play, target) enumeration

- **Files:** `main/main.gd`
- **Do:** in `find_valid_moves()`, when `noble_family`: the seat holds exactly 1 hand card
  (the active card); for each family index `f` build the pair
  `(active, p.family[f])`, apply `countess_restricted_types()` (forced play only), then emit
  moves with the existing target/type rules (`Guard` → active opponents × `range(Priest, Unknown)`;
  `Priest`/`Baron`/`King` → active non-protected opponents; `Handmaid`/`Countess` → self;
  `Prince` → any active non-protected, self included), setting `_drawn_family_idx = f`,
  `_drawn_type = p.family[f]`, and `_leftover_type` = the other card of the pair. `_played_card`
  is the active `Card` when the active card is played, `null` when the drawn card is played
  (`_played_card_idx` 0 = active, 1 = drawn).
- **Check:** run `tests/noble_family_smoke.tscn` with `print_valid_moves` on for one seat and
  eyeball counts (family 3 in 4p ⇒ ~3 × up to 21 moves for a Guard turn; every line shows a draw).
- **Gate:** variant move list is complete and legal; no move plays a card that is not played.

### 12. AI draw policies

- **Files:** `player/player.gd`
- **Do:** in `select_move()`, add the variant branches keyed on `valid_moves[0]._drawn_family_idx
  != -1`: L1 `return valid_moves[0]`; L2 `return valid_moves[randi() % len(valid_moves)]`;
  L3 = pick the lowest-rank `_drawn_type` family card, filter moves to that draw, then filter by
  "cheaper play" (`played type <= _leftover_type`, compare `Deck.CardType` ranks) and random-pick,
  falling back to the draw-filtered list when the play filter is empty; L4 keeps the existing
  weighted-score loop (no new scoring terms).
- **Check:** `tests/noble_family_smoke.tscn` with fixed seed twice → identical play logs
  (L1 determinism), different seeds → different logs (L2 randomness), no script errors, exit `0`.
- **Gate:** levels 1–4 all play legal joint moves.

### 13. Play the chosen draw

- **Files:** `main/main.gd`
- **Do:** in `_on_move_chosen(move)`, when `move._drawn_family_idx != -1`: `await
  deal_from_family(_players[_cur_player], move._drawn_family_idx)` and set `move._drawn_card =
  _players[_cur_player].hand.get_child(1)` **before** `_on_card_played(move._played_card)`; when
  the played card is the drawn one (`_played_card_idx == 1`), pass `move._drawn_card` to
  `_on_card_played()`.
- **Check:** `tests/noble_family_smoke.tscn` → exit `0`, and `assert(pl.hand.get_child_count()
  == 1, ...)` in `resolve_effect()` never fires.
- **Gate:** variant turns animate draw → play → effect with the 1-card hand invariant intact.

### 14. Remove the step-7 placeholder

- **Files:** `main/main.gd`
- **Do:** in `new_turn()` variant branch: do **not** draw for AI seats (their draw comes from the
  chosen move in step 13); keep the `p.family.is_empty() → round_over()` check; keep a
  `# TODO(step 20)` placeholder draw for the human seat.
- **Check:** `tests/noble_family_smoke.tscn` exit `0`; add to `tests/noble_family_rules.tscn` a
  scripted case (via `tests/fake_deck.gd` pattern) asserting a 4p round ends exactly when the
  seat to act has an empty family.
- **Gate:** the round-end condition lives only at turn start, for every seat.

### 15. Prince: family draw, widow fallback, elimination

- **Files:** `main/main.gd`
- **Do:** in the `Deck.CardType.Prince` branch of `resolve_effect()`, replace `await
  deal_card(tp, true)` for the variant: if `tp.family` is non-empty → `await
  deal_from_family(tp, 0)` for AI seats (as-dealt order, index 0); for a human target use
  `human_draw_from_family(tp)` — created in step 21, so in this step call `deal_from_family(tp, 0)`
  with a `# TODO(step 21)` marker; else if
  `_deck._widow_cards` is non-empty → `await deal_card(tp, true)`; else `await
  set_inactive(tp, false)`. Keep the existing memory-clearing loop.
- **Check:** extend `tests/noble_family_rules.tscn` with three scripted cases — target draws from
  family; target with empty family draws the widow (2p/3p only); target with empty family **and**
  empty widow is eliminated (must happen in 4p, where there is no widow).
- **Gate:** Prince never leaves a seat without exactly 1 hand card, and never draws from the
  family at the wrong time.

### 16. Elimination reveal + discard of the family

- **Files:** `main/main.gd`
- **Do:** in `set_inactive(p, reveal_hand)`, variant branch: reveal the hand as today, then
  materialize `p.family` face-up at the seat with inline `card_scene` nodes at the cascade offsets
  defined in step 18 (`x = i * 9`, `faceup = true`, one `Animator.flip` each), `await
  Animator.delay(1)`, then discard hand + family cards through the
  existing `discard()` path (no effects, `_deck._left` decrements), clear `p.family`, keep the
  existing memory clearing. Step 18 replaces these inline nodes with `Player.render_family()`.
- **Check:** extend `tests/noble_family_rules.tscn`: kill a seat, assert `_deck._left` dropped by
  exactly the revealed types and that `sum(_deck._left) == 16 - played_cards_count` after the
  reveal; assert no double decrement (the `assert(_deck._left[ch.type] >= 0)` in `discard()`).
- **Gate:** out-of-round cards become public, leave play, and are counted once.

### 17. `_left` invariant guard in the smoke suite

- **Files:** `tests/noble_family_smoke.gd`
- **Do:** hook the deciding seat's `ai_move` (or watch frames) to assert
  `sum(_deck._left) == 16 - played_total` at every decision, and count rounds/eliminations as now.
- **Check:** run → exit `0`.
- **Gate:** card accounting is verified continuously, not just in scripted cases.

## Phase B — human interface

### 18. Family stack node + rendering for the human seat

- **Files:** `player/player.tscn`, `player/player.gd`, `main/main.gd` (replace step 16's inline reveal nodes)
- **Do:** add child `Node2D` named `Family` at local `(26, 0)` (right of the 2 hand cards, the
  free bottom strip of seat 0 at global x 31..78, y 31..48); in `player.gd` add
  `@onready var family_root: Node2D = $Family` and `func render_family() -> void`: only when
  `is_human()`, rebuild `card_scene` children at `x = i * 9` (cascade, 2 px visible slivers),
  `faceup = true`, **no `input_event` connections** (display only); `clear_family()` also frees
  these nodes.
- **Check:** run the game as a human in 4p and 2p: seat 0 shows a readable cascade, the row stays
  inside 84×48 with 5 family cards + 2 hand cards; AI seats show nothing.
- **Gate:** "look at your noble family at any time" is satisfied with no extra widget.

### 19. FamilySelector modal scene

- **Files:** `family_selector/family_selector.gd`, `family_selector/family_selector.tscn` (new)
- **Do:** follow `type_selector` (`Node2D` + `Card` children + `card/selection.png` sprite):
  `signal draw_selected(family_idx: int)`; `func open(family: Array[Deck.CardType])` rebuilds one
  row of `Card` nodes (`card_type` = family type, `faceup = true`, positions `x = 12 + i * 12`,
  `y = 22`, 5 max), connects `input_event` → `draw_selected.emit(index)`, hides the panel when
  done; selection sprite on tap. No cancel/BACK control.
- **Check:** instantiate the scene standalone (`godot --headless --path .
  family_selector/family_selector.tscn` clean) and open it manually in a debug run with a fake
  family of 5 types.
- **Gate:** panel renders up to 5 face-up cards and reports the tapped family index.

### 20. Human turn-start draw through the modal

- **Files:** `main/main.tscn`, `main/main.gd`
- **Do:** add the `FamilySelector` node (as a sibling of `TypeSelector`, `z_index = 10`,
  `visible = false`); in `main.gd` factor the modal draw into
  `func human_draw_from_family(p: Player) -> void` (hide `_table`, open the modal with
  `p.family`, `await` the selection signal, close it, show `_table`,
  `await deal_from_family(p, idx)`); in `new_turn()` replace the step-7 human placeholder with a
  call to it, then continue with the existing `find_valid_moves()` / `eval_moves()` /
  `SELECT_CARD` branch.
- **Check:** manual human game (seat 0 = H): modal opens at every turn start, tap draws the card,
  then the play selection works; `tests/smoke_games.tscn` (all-AI classic) still exits `0`.
- **Gate:** the human's mandatory draw uses only the modal.

### 21. Mid-effect forced draw (human self-Prince)

- **Files:** `main/main.gd`
- **Do:** call `human_draw_from_family(tp)` from the `Prince` branch of `resolve_effect()` when
  `tp.is_human() and tp.family` is non-empty, replacing the step-15 `# TODO(step 21)` call site
  (this covers both a human self-Prince and an AI's Prince aimed at the human); when the family is
  empty use the step-15 chain (widow, then elimination).
- **Check:** manual run: hold Prince, Prince yourself, the modal opens mid-effect, the chosen card
  animates to hand, play selection resumes; the `hand.get_child_count() == 1` assert never fires.
- **Gate:** no human path auto-picks a family card; no modal leak.

### 22. Modal/input guard rails

- **Files:** `main/main.gd`
- **Do:** guarantee exclusivity: the modal opens only when the human must draw; while it is open,
  `_select_other_player` / `_select_any_player` / `_type_selector` stay hidden; taps outside cards
  do nothing; `_on_family_draw_selected` is `CONNECT_ONE_SHOT`-safe (guard with a
  `_drawing = true/false` flag); the modal is closed on every exit path (turn start, self-Prince).
- **Check:** manual pass through Guard (target + type selector), Countess-forced play, King swap,
  Baron reveal and self-Prince in one human game: no stuck overlays, no double draws.
- **Gate:** the modal cannot deadlock a human turn.

### 23. Family deal presentation

- **Files:** `main/main.gd`
- **Do:** keep the first-hand card animated (`deal_card`), deal families instantly (fill arrays +
  `render_family()`), play `_deal_audio_player.play()` once for the family batch, and call
  `render_family()` after every family change (draw, elimination, re-deal).
- **Check:** at `Animator._speed = 2` (settings speed 1) round setup is under ~1 s; at speed 5 it is
  visually instant; families appear in the stack with the burn applied.
- **Gate:** setup looks intentional on mobile and stays fast.

## Phase C — mode menu, stats, help

### 24. GameMode scene

- **Files:** `game_mode/game_mode.gd`, `game_mode/game_mode.tscn` (new)
- **Do:** `Node2D` with the `start.tscn` pattern (Label + flat full-area `Button`): rows
  `CLASSIC`, `NOBLE FAMILY`, `BACK`; signals `classic_pressed`, `noble_family_pressed`,
  `back_pressed`; handlers `hide()` then emit; `_ready()` hides all rows until `show()`.
- **Check:** run the scene standalone; all three rows are tappable in 84×48.
- **Gate:** the mode picker exists as its own scene.

### 25. Wire the mode menu into the application

- **Files:** `application/application.tscn`, `application/application.gd`
- **Do:** add `GameMode` node (`visible = false`, `process_mode = 3` like the other overlays);
  change `_on_start_play_pressed()` to `_start.hide(); _game_mode.show()`; add
  `_on_game_mode_classic()` → `_main.noble_family = false; start_game()`,
  `_on_game_mode_noble_family()` → `_main.noble_family = true; start_game()`,
  `_on_game_mode_back()` → `_start.show()`; `start_game()` = the current
  `_main.show(); _main.init_players(...)` body; `_on_pause_exit_pressed()` resets
  `_main.noble_family = false`; leave `speed_run` alone.
- **Check:** PLAY → picker → NOBLE FAMILY starts a variant game; BACK returns to the start page;
  after Exit-to-menu, PLAY → CLASSIC plays classic; `speed_run = true` still runs classic.
- **Gate:** the mode is chosen per game and never persisted.

### 26. Per-mode stats tables (data)

- **Files:** `stats/stats.gd`
- **Do:** `var tables: Array[Array[int]]` = two 12-counter tables (index 0 = classic, 1 = noble
  family), `var mode: int = 0`, `func table() -> Array[int]`, keep `_totals_and_wins` as a getter
  alias to `tables[mode]`; `update_labels()` reads `table()`; `_on_reset_button_pressed()` zeroes
  only `tables[mode]`.
- **Check:** `godot --headless --path . tests/smoke_games.tscn` exits `0`, no SCRIPT ERROR in the log.
- **Gate:** two independent tables exist.

### 27. Stats page mode switch (UI)

- **Files:** `stats/stats.tscn`, `stats/stats.gd`
- **Do:** add `LeftButton` / `RightButton` (`level_selector/digit_button.tscn` instances, frames
  `Frame_Left = 12`, `Frame_Right = 13`) in the left margin, e.g. `(0, 19)` and `(0, 29)`
  (labels start at x = 16, BackButton owns y ≥ 40, ResetButton owns y 0..9 — adjust in editor),
  plus a 1-char mode `Label` ("C" / "F") at `(0, 10)`; handlers `_on_left_button_pressed()` /
  `_on_right_button_pressed()` flip `mode` (wrap between 0 and 1) and call `update_labels()`.
- **Check:** Stats page flips between two tables, mode letter matches, reset clears only the
  visible table, no label is covered by a button.
- **Gate:** per-mode stats are reachable in 84×48.

### 28. Stats plumbing per mode

- **Files:** `application/application.gd`, `stats/stats.gd`
- **Do:** `_on_round_won/_on_round_finished` index `_stats.tables[_main.noble_family_index()]`
  (add a tiny `Main` helper returning `0`/`1`); `save_config()` writes
  `Stats/classic` and `Stats/noble_family`; `load_config()` loads both tables, keeps the existing
  stale-size drop per table, and reads legacy `Gameplay/totals_and_wins` into the classic table
  when the new keys are absent; `_stats.mode` defaults to the mode just played (set when Stats is
  opened from Pause/Start).
- **Check:** play 2 rounds in each mode, restart the app: both tables restored, counters in the
  right mode; delete `user://options.cfg`, run once, verify fresh zeros; old-format save (12
  counters) migrates to the classic table.
- **Gate:** per-mode stats survive restarts and old saves do not crash or mix modes.

### 29. Variant Help pages

- **Files:** `help/help.tscn`, `help/help.gd`
- **Do:** append 4 `card_help_page.tscn` pages with `show_card = false`, tagged with a new
  exported `variant_only: bool` on `card_help_page.gd` (editor-time set is fine):
  - **Family Setup** — burn 3/1/0, 1 first-hand card, family 5/4/3, leftovers 1/0/0, 4p burns nothing.
  - **Family Turn** — you must draw from your family; your family is private; widow is used only by Prince redraws.
  - **Family Out** — an out player reveals hand and family; they leave play, unseen by nobody else.
  - **Family Round End** — the round ends when the player to act has no family card left.
  `help.gd` hides `variant_only` pages when a variant game is not active (add
  `var variant_active: bool` set by `application.gd` from `_main.noble_family`) and keeps
  `_active_page` clamped after filtering.
- **Check:** Start-page Help shows only classic pages; Pause Help during a variant game shows the
  4 extra pages; left/right paging never lands on a hidden page.
- **Gate:** rules text matches the implemented numbers.

## Phase D — tests, docs, polish

### 30. Variant smoke suite finished

- **Files:** `tests/noble_family_smoke.gd` (from step 7), `tests/README.md`
- **Do:** run 2p, 3p and 4p all-AI variant games (seat levels 4/4/3/2, seat 0 AI, `max_games`
  respected, `Animator._speed = 0`, audio muted), assert ≥ 100 rounds total, ≥ 1 elimination per
  player count, the `_left` invariant from step 17, and `grep`-clean `SCRIPT ERROR` output; exit
  `0`/`1`; document the suite and its result in `tests/README.md`.
- **Check:** `godot --headless --path . tests/noble_family_smoke.tscn; echo $?` → `0`.
- **Gate:** variant games flow for every player count.

### 31. Variant rules repro suite finished

- **Files:** `tests/noble_family_rules.gd`, `tests/noble_family_rules.tscn`
- **Do:** collect the scripted cases from steps 4, 14, 15, 16 with the `tests/fake_deck.gd`
  technique (scripted deal order, deterministic seats driven as Human after `init_players`),
  covering: deal table conservation and equal families; round end exactly at turn start with an
  empty family; Prince family draw; Prince widow fallback (2p/3p); Prince with empty family and
  empty widow → elimination (4p); elimination reveal + discard accounting; joint move legality
  (every enumerated move plays a card the seat can legally play, Countess forced when required);
  L1 determinism under a fixed seed. Document in `tests/README.md`.
- **Check:** `godot --headless --path . tests/noble_family_rules.tscn; echo $?` → `0`.
- **Gate:** the resolved rules are pinned by assertions, not by manual play.
- **Implemented (2026-08-20, TEST R in `tests/noble_family_rules.gd`, 21 checks):** the six
  scripted cases the step lists were ALREADY in the suite (A/C = deal table + family-out round
  end, J = the human modal rails, D = the Prince family/widow/elimination chain, E = the
  elimination reveal, I = a human's Countess-forced play), so what the step was missing is the
  pair of rails the two bullets name. `CountingMain.joint_legality(move, seat)` states the whole
  joint rule over the LIVE board (~20 numbered rules, each with its own message: the drawn slot
  exists in a 1-card seat's family, played X is one of the pair, X + kept BE the pair, the Countess
  pair plays the Countess, the per-type target rules, the protection rule stated from the seats and
  NOT read off `Main._other_protected`, and the node shape - a drawn play has no hand node, an
  active play references it); `check_enumeration()` runs it on the FULL `find_valid_moves()` list at
  the seam where production enumerates it, and the committed triple is checked again at
  `_on_move_chosen` before the chain animates the draw. R1 (4p, 4 Countesses - twice the real
  supply - every family carrying a man, all seats level 1, whole rounds): **17 plays, 19 turns, 8
  Countess+man pairs (4 forcing the ACTIVE Countess, 4 the DRAWN one), 465 enumerated moves
  checked, 0 eliminations, 0 main-pile draws, 0 violations**, with the derivation written out in the
  section header and reproduced by the printed play log. R2: **8 whole games, 4737 rail checks, 0
  violations**; same seed + level 1 twice → IDENTICAL play logs (scripted 25 lines, REAL-deck 23 -
  the production shuffle is seeded, so the deal and family order are inside the equality), the same
  seed on level 4 → a DIFFERENT log, seed+1 → a different game. Clean tree **1433 PASS, 0 FAIL, 0
  script error, exit 0 in 73 s** (1412 / 66 s at step 29); the classic gate carries the same section
  nested and went 101 s → 139 s.
- **Two suite facts this step measured** (they constrain every later fixture): a game's round ends
  spend global RNG (`Main.round_over()` picks the next starter with `randi()`), so a section that
  plays whole games MOVES the RNG stream the scripted fixtures read - R placed in front of TEST J
  moved J1 from 19 plays to 16, so R runs immediately after J; and a fixture that raises mid-frame
  prints NO checks and the suite still exits 0 (measured: 0 of R's 21 checks ran, 1412 PASS, exit 0),
  which is why R counts its checks through `r_check()` and ends with `END R: 21 checks run, 0
  failure(s)`.

### 32. Classic regression sweep

- **Files:** none (run only)
- **Do:** run every existing suite: `tests/smoke_games.tscn`,
  `tests/repro_guard_princess.tscn`, `tests/repro_prince_memory.tscn`,
  `tests/repro_score_multiplier.tscn`, `tests/repro_belief_truth.tscn --rounds=150`.
- **Check:** all exit `0`.
- **Gate:** classic mode is provably untouched (this is the acceptance gate for Phase A–C).

### 33. Implementation doc

- **Files:** `docs/noble-family-implementation.md` (new)
- **Do:** write the doc: the resolved deal table (with the 16-card arithmetic), the widow scope and
  the 4p "no widow" consequence, turn flow and round-end rule, elimination reveal/accounting and
  the `_left` definition, the family data model, the human UI (stack + modal) with coordinates, the
  `Move`/`find_valid_moves`/`eval_moves`/`select_move` extension and per-level policies, the menu
  and mode plumbing, the per-mode stats schema (keys, counters, migration), the Help pages, the
  test commands and measured results, plus an "Open, unmeasured" section: the two spec
  contradictions ("exactly 4 remain", "not considered discarded"), the fact that 4p loses the
  widow fallback, and that Level 4's Guard-count calibration from `tests/left_cards_sim.py`
  describes the classic deal and is not yet re-measured with families.
- **Check:** the doc lists no rule that contradicts the code; `docs/Noble family variant.md` is
  byte-identical (`git diff --stat -- "docs/Noble family variant.md"` shows nothing).
- **Gate:** the variant is documented and the source spec is pristine.

### 34. Manual QA on desktop and Android presets

- **Files:** none (play + fix)
- **Do:** play as seat 0 Human in 2p, 3p, 4p variant games against L1/L2/L3/L4 seats: verify the
  cascade stack with 5 family cards, the modal tap targets on the 672×384 viewport, the widow pile
  visible in 2p/3p and hidden in 4p, the main pile hidden, round-over reveals of out players'
  families, mode reset via Exit-to-menu, Stats tabs + reset + restart, Help gating, and that
  pause/resume mid-draw does not reopen the modal.
- **Check:** the Android export builds (`godot --headless --path . --export-release Android
  /tmp/ll.apk` using the existing preset) and `speed_run = true` still plays classic headless to
  completion; the Linux preset (`--export-release Linux /tmp/ll.x86_64`) builds too.
- **Gate:** nothing in the accepted design surprises a player on a small screen.

### 35. Housekeeping

- **Files:** `README.md`, `design.md` (only if needed), `GRILL-ME.md` (read-only)
- **Do:** add one README feature bullet ("Noble Family variant mode with per-player noble family
  draw"), link `docs/noble-family-implementation.md` from `README.md`, and commit with a message
  naming the deal table (`burn 3/1/0, family 5/4/3`) so the numbers are in git history.
- **Check:** `git status` clean; `godot --headless --path . tests/smoke_games.tscn` and
  `tests/noble_family_smoke.tscn` both exit `0` at HEAD.
- **Gate:** the work is discoverable and reproducible.

## Notes for the implementer

- `main.gd` owns all state changes (`design.md` central-manager rule): `Player` keeps family data
  and rendering, `Deck` keeps the supply, `Main` decides when a family is drawn.
- Family order is **as-dealt** everywhere (enumeration, rendering, Level 1 determinism) — never
  sort a family array.
- Variant moves are scored **before** the card is drawn: `Move._drawn_type` /
  `Move._leftover_type` exist so `eval_moves()` needs no `Card` node; `_drawn_card` is filled in
  step 13 only for the winning move.
- `hand.get_child_count() == 1` after every effect must stay true for every seat, in every player
  count, including Prince/elimination paths — that assert is the invariant the whole design rests on.
- `_deck._left` must never be decremented for family dealing; only for plays and for revealed
  out-of-round cards.
