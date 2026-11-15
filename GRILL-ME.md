# Grill Me Results

Generated: 2026-11-08T04:24:39.007Z

## Plan

implement Noble Family variand of Love Letter

## Shared Understanding

Noble Family variant as a mode of the existing engine: a new GameMode scene (CLASSIC / NOBLE FAMILY / BACK) opened by PLAY on the start page makes application.gd set Main.noble_family before init_players (not persisted, speedrun stays classic). Each round burns 3/1/0 cards as the widow (2p/3p/4p), deals 1 first-hand card per seat (face-up for seat 0) and then a per-seat family of 5/4/3 drawable cards; the main deck pile ends at 1/0/0 and is hidden, the widow pile stays visible face-down with no count. The turn stays draw-then-play: at turn start the seat must draw from its own family (human picks in a modal TypeSelector-style panel centered over the Table, AI decides jointly with the play), so hand size at decision time is still 2 and Countess/eval semantics are unchanged. A family draw is mandatory; the widow is the fallback pile only for Prince redraws (empty widow eliminates the target). A round ends at turn start when the seat to act has an empty family; eliminated seats reveal hand + family, then those cards are moved to the discard pile with no effects, decrementing _deck._left (which counts deck leftovers + widow + all live families). Families are per-seat type arrays re-dealt every round; only the human gets Card nodes (cascade face-up stack in seat 0's bottom strip + the modal). find_valid_moves is extended with the draw choice for AI levels 1-4 (L1 first valid move in as-dealt family order, L2 uniform random, L3 cheapest play + cheapest draw, L4 weighted eval where the drawn family card is the leftover card, no new scoring terms). Stats become per-mode tables with left/right tab buttons and per-mode options.cfg keys; Help gains 4 variant_only pages shown only in a variant game; tests are a variant smoke suite plus a deterministic scripted fake-deck repro suite; docs get a new docs/noble-family-implementation.md and the source spec stays pristine.

## Questions and Answers

### 1. Where does the card-type rank live in this engine, and what does adding a card type touch?

**Recommended answer:** Rank is the CardType enum index itself; adding a type touches the enum, sprite frame index (cards.png has 9 frames of 11x17), card_count/card_names, find_valid_moves, resolve_effect, eval_moves, type_selector.tscn, and help pages.

**User answer:** Discovered: Deck.CardType (deck.gd:4-13) doubles as the rank table — round_over picks the highest enum int, Baron compares my_type > their_type, eval_moves scores with GOOD * _target_type and mem > Handmaid; Card.gd sets _sprite.frame = type against a 99x17 sheet (9 frames, 11x17 each); find_valid_moves guesses range(Priest, Unknown); countess_restricted hardcodes Prince/King as "men"; eval_moves has no default branch, so an unhandled type scores LOSE=0 and level 4 degrades to uniform random; main.gd:284 asserts exactly 1 card in hand for every active seat.

**Status:** resolved

**Notes:** Constrains every later answer: any new card must land in rank order in the enum, and the 1-card hand invariant decides which Noble Family effects are cheap.

### 2. Which family-dealing table do we implement, given the doc's 'exactly 4 cards remain' contradicts its own per-player numbers?

**Recommended answer:** Doc per-player numbers: 1 to each, then 5 more (2p) / 4 more (3p) / 3 more (4p) -> family 5/4/3, burn 3/1/0, deck left 1/0/0; the 'exactly 4 remain' headline is arithmetically impossible with those numbers.

**User answer:** Doc per-player numbers (family 5/4/3, burn 3/1/0, deck 1/0/0)

**Status:** resolved

**Notes:** Combined with the engine widow (3/1/1) the real remainders are 0/0/1 in the main pile; widow pile holds the burned cards.

### 3. Is the card dealt as 'their first hand' counted inside the family, or is the family only the extra distributed cards?

**Recommended answer:** Family excludes the first hand (family 5/4/3, total owned 6/5/4), so the family pile is exactly the drawable set.

**User answer:** First card is dealt to each player's hand. Then everyone receives noble family cards that they will draw from (family pile = drawable cards only).

**Status:** resolved

**Notes:** Player starts a round with 1 hand card + family pile of 5/4/3 (2p/3p/4p).

### 4. Whose hand size do we keep at decision time: draw-then-play or play-then-draw?

**Recommended answer:** Draw from family first, then play 1 of 2 - matches the existing new_turn -> deal_card -> find_valid_moves flow and keeps eval_moves' leftover-card logic valid.

**User answer:** Draw from family first, then play 1 of 2

**Status:** resolved

**Notes:** Hand is 2 cards at decision time; the leftover becomes the active card.

### 5. How does the Countess restriction work in the variant?

**Recommended answer:** Unchanged: Countess + Prince/King in the 2-card hand forces the Countess play ('No other changes').

**User answer:** Unchanged: Countess + man in hand forces the Countess play

**Status:** resolved

**Notes:** countess_restricted() needs no edit under draw-then-play.

### 6. What exactly happens when a player is eliminated: reveal hand+family, where do the cards go, and how is deck._left accounting affected?

**Recommended answer:** Reveal hand+family face-up at the seat, cards stay there (not moved to the discard pile), and Main decrements _deck._left for each revealed card (public, out of play).

**User answer:** Reveal, update memories, discard all of them without effects

**Status:** open

**Notes:** User answer says the revealed family/hand cards ARE discarded (no effects), which conflicts with the doc's 'They are not considered discarded'; confirm discard animation/target and _left decrement in round 2.

### 7. Where is the round-end condition checked?

**Recommended answer:** At turn start: seat to act has an empty family -> round_over() (same slot as the current deck-empty check).

**User answer:** At turn start: seat to act has empty family -> round_over()

**Status:** resolved

**Notes:** Single round-end rule; family only shrinks on your own turn.

### 8. A Prince discards the target's active card; what if the target's family is empty?

**Recommended answer:** Target is eliminated (set_inactive, reveal, no new card) and the round continues; the round-end check stays at turn start.

**User answer:** Draw the widow in this case

**Status:** open

**Notes:** Introduces the widow pile as the Prince-redraw fallback in the variant. Need the empty-widow fallback and confirmation that turn-start drawing still comes only from the family.

### 9. Which burn/widow count does the variant use (doc says burn 1; engine uses widow 3 for 2p, 1 for 3-4p)?

**Recommended answer:** Follow the engine's widow counts (3 for 2p, 1 for 3p/4p); matches the doc's '13 remaining' arithmetic for 2p and keeps Deck.prepare() as the burn source.

**User answer:** Engine widow: 3 for 2p, 1 for 3p/4p (doc 'no burn' for 4p ignored)

**Status:** resolved

**Notes:** With families 5/4/3 the main pile ends at 0/0/1 cards for 2/3/4 players.

### 10. Who can see whose family?

**Recommended answer:** Own family face-up at all times; opponents' families face-down with a visible card count.

**User answer:** Own face-up; opponents' families fully hidden (no count)

**Status:** resolved

**Notes:** No count badge for AI families; family becomes public only via the elimination reveal.

### 11. How should the human draw-selection interface look in the Main scene?

**Recommended answer:** Modal family panel over the table, built like the TypeSelector overlay, opened when a draw is required, plus a small face-up stack at your seat.

**User answer:** Modal family panel over the table (TypeSelector-style), plus a small face-up stack at your seat

**Status:** resolved

**Notes:** 84x48 viewport has no room for 5-card rows for four seats; reuse the TypeSelector pattern.

### 12. How is the draw choice represented in the AI's move list?

**Recommended answer:** Joint (draw, play) moves: Move gains the drawn family card, find_valid_moves enumerates family pick x played card x target, eval_moves scores the drawn card as the leftover card.

**User answer:** Joint (draw, play) moves enumerated in find_valid_moves

**Status:** resolved

**Notes:** Exact fit for my_type = hand.get_child(1 - m._played_card_idx).

### 13. What draw rule do AI levels 1-4 use?

**Recommended answer:** L1 first valid move, L2 uniform random, L3 cheapest play + cheapest draw, L4 full weighted scoring of joint moves.

**User answer:** L1 first, L2 random, L3 cheapest play + cheapest draw, L4 weighted eval

**Status:** resolved

**Notes:** Preserves each level's existing personality.

### 14. In what order are family cards enumerated (so L1's 'first valid move' is reproducible)?

**Recommended answer:** As-dealt (deck) order, no sorting - no extra state, L1 stays an arbitrary-first-move AI.

**User answer:** As-dealt order (deck order), no sorting

**Status:** resolved

**Notes:** Deterministic under a fixed seed.

### 15. Should eval_moves gain new scoring terms for the variant?

**Recommended answer:** Minimal: the drawn family card is the leftover card only; no new family-templating heuristics, measure later.

**User answer:** Minimal: drawn family card = leftover card, no new scoring terms

**Status:** resolved

**Notes:** Rebalance (keep best family card for last, family-size terms) is deferred to measurement.

### 16. How does the Noble Family entry under Play work on the start page?

**Recommended answer:** Tapping PLAY expands the Play row in place into CLASSIC / NOBLE FAMILY sub-rows.

**User answer:** PLAY leads to a new GameMode scene with CLASSIC, NOBLE FAMILY, BACK options

**Status:** resolved

**Notes:** New scene/node (mode selector) shown from PLAY; BACK returns to the start page. Plumbing details to confirm in round 2.

### 17. Is the selected mode persisted to user://options.cfg?

**Recommended answer:** No: mode resets to Classic on app start / return to menu; explicit choice per game, no config migration.

**User answer:** Not persisted: mode resets to Classic on app start / return to menu

**Status:** resolved

**Notes:** Speedrun and existing config keys stay untouched.

### 18. Should Noble Family rounds feed the Stats page?

**Recommended answer:** Share the existing totals/wins table - variant rounds count as ordinary rounds, zero data-model change.

**User answer:** Separate per-mode stats with a mode switch on the Stats page

**Status:** open

**Notes:** Doubles the counters (24 = 2 modes x 6 levels x 2), needs saved keys per mode, a reset rule, and a mode-switch widget in stats.tscn. Round-2 questions pending.

### 19. Add rules text for the variant to the existing Help pager?

**Recommended answer:** Add 2-3 Noble Family pages to the existing pager (Setup/Turn/Elimination/Round End variants).

**User answer:** Pages shown only while the variant mode is active

**Status:** open

**Notes:** Needs a rule for Help opened from the start page before any mode is chosen and from Pause; round-2 question.

### 20. What test coverage do we add?

**Recommended answer:** Both: a variant smoke suite (all-AI games at 2/3/4 players, rounds/eliminations flow) and a deterministic scripted fake-deck repro suite (family sizes, draw legality, round-end condition).

**User answer:** Variant smoke suite + deterministic scripted-deck repro suite

**Status:** resolved

**Notes:** Mirrors tests/README.md practice (godot --headless --path . tests/<scene>.tscn, exit code).

### 21. Exact implementation of the out-of-round reveal: reveal hand+family, where do the cards go, and how does deck._left accounting react?

**Recommended answer:** Reveal face-up, then animate them to the discard pile (no effects) and decrement _deck._left - the doc's 'not discarded' read as 'no discard effect, never in the pile before'.

**User answer:** Reveal face-up, then move to the discard pile and decrement _deck._left, no effects

**Status:** resolved

**Notes:** Resolves the doc conflict explicitly; Main.discard() reused; Level 4's _left stays 'not played and in play'.

### 22. Scope of the widow-draw fallback and the empty-widow case.

**Recommended answer:** Widow = Prince-redraw fallback only (like deal_card(tp, true)); turn-start draws come only from the family; an empty widow eliminates the Prince target.

**User answer:** Widow = Prince-redraw fallback only; empty widow eliminates the target; turn start is family-only

**Status:** resolved

**Notes:** Round-end condition stays a single check at turn start.

### 23. How is the widow pile shown in the variant?

**Recommended answer:** Classic Deck.gd behaviour: face-down pile visible while non-empty, no card count (hidden information).

**User answer:** Visible face-down pile, no card count (classic behaviour)

**Status:** resolved

**Notes:** Keeps left_cards_sim.py's hidden-widow finding valid.

### 24. Where does the new GameMode scene live and how does Main learn the mode?

**Recommended answer:** New GameMode node in application.tscn (hidden by default, like LevelSelector/Stats/Pause); PLAY shows it, BACK returns to Start; application.gd sets Main.noble_family before init_players, exactly like it assigns ai_level today.

**User answer:** New GameMode node in application.tscn; application.gd sets Main.noble_family before init_players

**Status:** resolved

**Notes:** No autoload/singleton; Start.play_pressed now opens the mode selector instead of starting a game.

### 25. Does speed_run / the headless export flags reach the variant?

**Recommended answer:** No: speed_run stays classic-only; variant tests instantiate Main directly and set the noble_family flag (tests/smoke_games.gd pattern).

**User answer:** speed_run stays classic; variant only from the menu and from tests

**Status:** resolved

**Notes:** Existing measured speedrun numbers are untouched.

### 26. Family data model: where do family cards live?

**Recommended answer:** Plain Array[Deck.CardType] per seat (dealt by Deck, flow owned by Main); Card nodes materialized only for the human's stack and the modal; AI draws instantiate the card in AnimationLayer and slide it from the seat.

**User answer:** Type arrays per seat; Card nodes only for the human's stack/modal

**Status:** resolved

**Notes:** AI never gets Card nodes for family; Main keeps state changes central (design.md guideline).

### 27. Where does the human's face-up family stack sit, given the 84x48 geometry?

**Recommended answer:** Cascading face-up row in seat 0's free bottom strip (x5..52, y31..48), rank corners visible; AI families are hidden so the top seats need nothing.

**User answer:** Cascading face-up row in seat 0's free bottom strip (all ranks readable)

**Status:** resolved

**Notes:** Only seat 0 has a face-up stack; top seats collide with Marker0's played-card area.

### 28. How is 'you may look at your noble family at any time' honoured for the human?

**Recommended answer:** The always face-up cascade stack is enough; the modal opens only when a draw is required.

**User answer:** The always face-up stack is enough; the modal opens only when a draw is required

**Status:** resolved

**Notes:** No browse mode, no extra button.

### 29. How should the 10-12 family cards be dealt on screen each round?

**Recommended answer:** First-hand card animated normally; family cards appear instantly in the stack with a single deal sound.

**User answer:** First hand animated; family cards appear instantly

**Status:** resolved

**Notes:** Keeps round setup under ~1s on mobile.

### 30. What does Deck.gd show in the variant (main pile ends at 1/0/? cards)?

**Recommended answer:** Hide the main pile sprite in the variant, keep the widow pile visible as the Prince fallback.

**User answer:** Hide main pile in the variant; show the widow pile

**Status:** resolved

**Notes:** Avoids a misleading 1-card pile in some counts.

### 31. Per-mode Stats: what is the switch mechanism and data layout?

**Recommended answer:** Left/right digit-button tabs (SpeedLevel pattern) flipping one 6-row table between Classic and Noble Family; tab defaults to the mode just played; saved as two ConfigFile keys, 12 counters each.

**User answer:** Left/right tab buttons over one table; per-mode keys in options.cfg

**Status:** resolved

**Notes:** Doubled table (24 chars/line) does not fit 84px; digit_button.tscn is reused.

### 32. What does the Stats Reset button clear with per-mode tables?

**Recommended answer:** Only the visible mode's table; the stale-data drop check in load_config() moves to a per-table size check.

**User answer:** Reset clears only the currently visible mode's table

**Status:** resolved

**Notes:** Tab-local reset.

### 33. Variant-only Help pages: what shows where, given Help is reachable from Start (no mode chosen) and from Pause (mode known)?

**Recommended answer:** Append variant pages tagged variant_only; hidden on the Start page, shown in Pause during a variant game.

**User answer:** variant_only pages appended; hidden on the Start page, shown in Pause during a variant game

**Status:** resolved

**Notes:** Existing pages stay untouched.

### 34. What belongs in _deck._left in the variant (Level 4's Guard/Prince counting reads it)?

**Recommended answer:** Everything not yet played and in play: deck leftovers + widow + every live seat's family; decrement on play and on elimination reveal; family draws do not change it.

**User answer:** Deck leftovers + widow + all live families (decrement on play and on elimination reveal)

**Status:** resolved

**Notes:** Keeps P(target holds t) = _left[t]/sum(_left) valid; family cards are hidden info, not out of play.

### 35. How is the 4-player deal resolved (4 first-hand + 3 family each needs 16 cards, so the engine's 1-card widow burn cannot coexist with 3-card families)?

**Recommended answer:** 4p burns nothing (the doc's own 'do not burn' line): families 3 each, main pile empty, no widow pile in 4p, so a Prince target with an empty family in 4p is eliminated; 2p/3p keep the widow fallback.

**User answer:** 4p: burn 0, families 3 each, no widow pile in 4p

**Status:** resolved

**Notes:** Final deal table (16 cards): burn 3/1/0, first hand 1/1/1, family 5/4/3, main pile left 1/0/0, widow pile 3/1/0 for 2p/3p/4p.

### 36. What happens when a forced family draw lands on the human mid-effect (his own Prince)?

**Recommended answer:** Open the draw modal at that moment and let the human pick - one interface for every human draw.

**User answer:** The draw modal opens at that moment and the human picks

**Status:** resolved

**Notes:** The modal is the only human draw interface; no auto-draw, no move suppression.

### 37. Are families re-dealt every round or kept for the whole game?

**Recommended answer:** Re-deal every round from a fresh shuffle (matches _new_round() -> Deck.prepare(); scores persist, families do not).

**User answer:** Re-deal families every round (fresh shuffle)

**Status:** resolved

**Notes:** No family persistence across rounds.

### 38. How many variant_only Help pages and what do they say?

**Recommended answer:** 4 short pages reusing card_help_page.tscn (show_card = false): Family Setup (burn + 5/4/3 deal), Family Turn (draw from family, widow for Prince only), Family Out (reveal everything, cards leave play), Family Round End (round ends when the seat to act cannot draw).

**User answer:** 4 pages: Setup / Turn / Out / Round End

**Status:** resolved

**Notes:** Text must state the resolved deal table and the widow-fallback rule.

### 39. Draw modal placement and flow?

**Recommended answer:** TypeSelector pattern: modal Node2D at z_index 10 centered over the Table, family cards in one row with the selection sprite; tap = animate to hand and close; no cancel button because the draw is mandatory.

**User answer:** Centered over the table, tap to draw, no cancel button

**Status:** resolved

**Notes:** Opened at turn start and at mid-effect forced draws.

### 40. How are the resolved rules documented?

**Recommended answer:** New docs/noble-family-implementation.md (deal table, flow, find_valid_moves/eval_moves extension, stats/help/menu plumbing, test commands); docs/Noble family variant.md stays the untouched source spec.

**User answer:** New docs/noble-family-implementation.md; source spec stays pristine

**Status:** resolved

**Notes:** The two spec contradictions are recorded in the implementation doc, not by editing the spec.

## Agreed Decisions

- Rules - deal table (16 cards): burn/widow 3/1/0 for 2p/3p/4p; 1 first-hand card per seat is separate from the family; family = 5/4/3 drawable cards per seat; main pile ends 1/0/0 and is hidden in the variant. The doc's 'exactly 4 cards remain' is arithmetically impossible with its own per-player numbers and is not implemented.
- Rules - 4 players: burn 0 (doc's 'do not burn' line), so 4p has no widow pile; a Prince target with an empty family in 4p is eliminated. 2p/3p keep the widow fallback.
- Rules - turn flow: draw from family first (mandatory), then play 1 of 2; the leftover card is the active card. Hand is 2 cards at decision time, so Countess stays unchanged (Countess + Prince/King in hand forces the Countess play).
- Rules - widow scope: fallback pile for Prince redraws only (mirrors deal_card(tp, true)); never drawable at turn start; an empty widow means the Prince target cannot draw and is eliminated.
- Rules - round end: single check at turn start - if the seat to act has an empty family, round_over(). No mid-effect round-end rule.
- Rules - elimination: reveal hand + all family cards face-up, update/clear memories as set_inactive does today, then animate them to the discard pile with no card effects and decrement _deck._left for each. The doc's 'not considered discarded' is resolved as 'no discard effect'.
- Rules - card accounting: _deck._left = deck leftovers + widow + every live seat's family; decremented on plays and on elimination reveals, unchanged by family draws. Keeps P(target holds t) = _left[t]/sum(_left) valid for Level 4.
- Rules - families are per-round: re-dealt from a fresh shuffle every _new_round(); scores persist, families do not.
- Information: own family face-up at all times; opponents' families fully hidden, with no count badge; family contents become public only through the elimination reveal.
- Human UI - family stack: cascading face-up row in seat 0's free bottom strip (x~5..52, y31..48), all rank corners visible, display-only (satisfies 'look at your family at any time'; no browse mode, no extra button).
- Human UI - draw selection: modal panel reusing the TypeSelector pattern (Node2D, z_index 10, one spread row, selection sprite), centered over the Table, opened at turn start and at mid-effect forced draws (e.g. self-Prince); tap = that card animates to the hand and the modal closes; no cancel/BACK because the draw is mandatory.
- Round setup animation: first-hand card dealt with the normal deal animation; family cards appear instantly in the stack (one deal sound) to keep setup under ~1s.
- Deck rendering in the variant: main pile sprite hidden, widow pile shown face-down with no card count (classic behaviour, hidden information).
- Mode entry: PLAY opens a new GameMode node in application.tscn (hidden by default like LevelSelector/Stats/Pause) with CLASSIC / NOBLE FAMILY / BACK; BACK returns to Start; application.gd sets Main.noble_family before init_players (same pattern as assigning ai_level). No autoload/singleton.
- Mode persistence: not saved - mode resets to Classic on app start and on return to the menu; options.cfg keys (AI_Level, Gameplay/speed, totals_and_wins) keep working.
- Speedrun/exports: speed_run stays classic-only; variant is reached from the menu and from tests that instantiate Main and set the flag.
- AI: find_valid_moves enumerates joint (draw, play, target) moves for levels 1-4; Move carries the drawn family card; family enumeration uses as-dealt (deck) order with no sorting. L1 = first valid move, L2 = uniform random, L3 = cheapest play + cheapest draw, L4 = existing weighted eval with the drawn family card as the leftover card and no new scoring terms (family-templating heuristics deferred to measurement).
- Data model: family = plain Array[Deck.CardType] per seat, dealt by Deck, flow owned by Main (design.md central-manager guideline); Card nodes are materialized only for the human's stack and modal; AI family draws instantiate the card in AnimationLayer and slide from the seat.
- Stats: per-mode tables (12 counters each) shown through left/right digit-button tabs over the existing 6-row page, tab defaulting to the mode just played; saved under per-mode keys in options.cfg; Reset clears only the visible mode's table.
- Help: 4 variant_only pages appended (Family Setup / Family Turn / Family Out / Family Round End), hidden on the Start page and shown in Pause during a variant game; existing pages untouched.
- Tests: a variant smoke suite (all-AI variant games at 2/3/4 players asserting rounds and eliminations flow, headless, exit code) plus a deterministic scripted fake-deck repro suite asserting family sizes, deal legality, draw-choice legality and the round-end condition.
- Docs: new docs/noble-family-implementation.md capturing the deal table, flow changes, AI extension, stats/help/menu plumbing, test commands and the two spec contradictions; docs/Noble family variant.md is left untouched.

## Open Risks

- Biggest refactor risk: eval_moves()/select_move() Level 3/4 read hand.get_child(0)/get_child(1) and eval_moves asserts hand.get_child_count() == 2, so a joint (draw, play) move must be scorable from types (drawn family card is hypothetical, no Card node). Player.gd needs the leftover type supplied by the Move rather than by hand children; this is where AI regressions will show up and is exactly what the repro suite must pin.
- Level 4 calibration is unmeasured in the new information model: _left now includes hidden family cards and families cap round length. tests/left_cards_sim.py's numbers describe the classic deal, so the Guard-guess baseline must be re-measured after implementation; any rebalance (family-value scoring, keep-the-best-for-last) is deliberately deferred.
- The 4p decision removes the widow fallback entirely in 4-player rounds, so 4p Prince play becomes strictly more lethal than in 2p/3p. If the spec is later edited to 'exactly 4 remain', the whole deal table changes (families 2 each in 4p) - the resolution is a choice, not a fact from the doc.
- Stats schema change: options.cfg gains per-mode tables. A migration/drop rule is needed for existing saves that carry the old 12-counter totals_and_wins (load_config()'s size check becomes per-table); un-migrated saves must not crash or silently mix modes.
- UI fit has to be validated in the editor: the 5-card cascade (~47px) must coexist with seat 0's 2 hand cards, score label and current mark in the y31..48 strip at 672x384, and the modal row (up to 5 cards) must not cover the played-card area at Marker0. Slivers are intentionally not tap targets.
- Modal is mandatory with no cancel: the modal must swallow non-card taps, must not be openable during the play phase, and must close on every path (turn-start draw, mid-effect self-Prince) - a leaked modal deadlocks the human turn.
- Memory semantics rely on 'a memory slot names the seat's hand card': family cards are not hand cards, so reveals at elimination must clear beliefs (as set_inactive does) without introducing beliefs about family contents. The Prince/redraw and King-swap paths need to keep touching hand cards only.
- Revealed-then-discarded cards move _deck._left; any double decrement (discard(p.hand) plus the new family discard path in set_inactive) would break the assert in discard() and poison Level 4 counting.

## Next Decision Needed

None blocking. The first thing to settle in code is the joint Move representation: how a Move carries the hypothetical drawn family card (type + family index + family size) so find_valid_moves can enumerate (draw, play, target) triples and eval_moves/select_move can score them without a Card node - everything else in the plan is pinned by the decisions above.
