right now, to estimate power of strategies, speed run mode is used where players are of level 1, 2, 3, 4, and I count number of won games for every level. But player order is never changed, as well as random seed. How to improve strength evaluation?

Good question. Your current methodology has several systematic biases that will skew results. Let me outline the issues and concrete improvements.

## Problems with Current Approach

### 1. Fixed Player Order = Positional Bias
Player 0 (first to act) has a **significant advantage** in Love Letter — they see the full game state and act before anyone else. Player 3 (last) is disadvantaged. By always placing L1 at position 0, L2 at position 1, etc., you're conflating **AI strength** with **turn order advantage**.

### 2. Fixed Seed = Non-Representative Games
A single seed produces one specific distribution of cards. Some distributions heavily favor or disadvantage specific positions/strategies. One seed is a **sample size of 1** — statistically meaningless.

### 3. Counting "Won Games" Is Too Coarse
"Round won" counts don't distinguish between:
- Eliminating the Princess (the most common win condition) vs. holding the highest card
- A decisive blow vs. barely surviving
- You can't detect marginal skill differences

### 4. No Normalization
With different numbers of active players (e.g., 1 human + 3 AI), the total games per seed varies.

---

## Concrete Improvements (Ranked by Impact)

### 1. Randomize Player Order (Highest Impact)

Each game should permute which AI level sits at which position. With 4 levels, that's 24 possible orderings. You need to sample across them.

```gdscript
# In main.gd or a test harness
func _new_game() -> void:
    if game_counter == 0 or game_counter % 24 == 0:
        # New permutation of player order
        var order = [0, 1, 2, 3]
        order.shuffle()  # permute the AI levels across positions
        for i in range(4):
            _players[i].ai_level = ai_levels_permuted[i]
```

### 2. Iterate Through Seeds (Second Highest Impact)

Cycle through a sequence of seeds. With 1000 games and 24 orderings, use `seed = game_counter // 24`, so each ordering gets a different seed.

```gdscript
# Each game gets a unique seed, ensuring every ordering hits every seed
var seed_index = game_counter % 24
var seed = base_seed + (game_counter / 24)
```

### 3. Track More Granular Metrics

Instead of just "won games", track:

| Metric | Why |
|---|---|
| **Average round score** | Better than win count; captures partial progress |
| **Elimination rate** (Princess discard) | Shows proactive play vs. passive survival |
| **Average hand rank at round end** | Quality of card holding |
| **Cards played by type** | Strategy preference (aggressive vs. passive) |
| **Guard hit rate** | For L4, measures how well it guesses |

### 4. Use Paired/Matched Comparisons

The gold standard: **each pair of AI levels plays each other in both positions**. For 4 levels, that's C(4,2) × 2 = 12 pairwise matchups.

```
L1 vs L2: L1 at pos 0, L2 at pos 1, then swap
L1 vs L3: same
L2 vs L3: same
...etc
```

This **cancels out position bias** because each AI gets each position equally against its opponent.

### 5. Use Elo or TrueSkill Rating

Rather than raw win counts, maintain an Elo rating. After each game, update:

```
R_new = R_old + K × (actual_score - expected_score)
```

Where `expected_score = 1 / (1 + 10^((R_opponent - R_self) / 400))`

This converges on a true strength ranking regardless of game length variance.

---

## Minimal Viable Fix

If you want the quickest improvement with minimal code changes:

```gdscript
# In init_players or _new_game, before assigning levels:
var permutation = [0, 1, 2, 3]
permutation.shuffle()
var ai_levels = [Player.AI_Level.Level_1,
                  Player.AI_Level.Level_2,
                  Player.AI_Level.Level_3,
                  Player.AI_Level.Level_4]
for i in range(4):
    _players[i].ai_level = ai_levels[permutation[i]]
```

And in your stats tracking, change from:

```
"Player X won N games"
```

To:

```
"Level Y (at position X): N wins, avg_score Z, eliminated M times"
```

Then aggregate across all orderings. With 1000 games spread over 24 orderings, you'd get ~41 games per ordering — enough to start seeing real differences emerge.

---

## Summary Priority

1. **Randomize player order** each game (kills positional bias)
2. **Vary seeds** — one per game, not fixed (kills sample bias)
3. **Track average round score** instead of just wins (finer granularity)
4. **Run enough games** — 1000 is fine, but ensure each level-ordering combo appears ~40+ times
5. **Compute Elo ratings** for a clean "strength ranking" (optional but cleanest output)

The biggest single error right likely is **fixed player order** — in Love Letter, going first can be a substantial advantage, enough to make a weaker AI appear stronger just by always going first.
