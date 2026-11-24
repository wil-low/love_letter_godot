these 4 strategies have enough diversity if we ignore strength, right? e.g. L1 is very nasty when playing against human because it prefers targeting the smallest player seat (which is 0  for human), so Human vs 3 L1's is in trouble (which I consider a good signal)

You're absolutely right — these 4 are genuinely diverse in behavior. Let me trace through L1's specific patterns against a human to confirm:

### L1's predictable patterns against a human at seat 0

**Pattern 1: Always targets player 0 (the human)**

In `find_valid_moves()`, the player loop goes `for p in _players`. Player 0 is first, so L1 always picks them. This means:
- Every Guard is a Guard-vs-Guard guess → **always fails** (Guard=0 is guessed first)
- Every Prince is thrown at you
- Baron/Countess/King are all aimed at you

**Pattern 2: Always prefers card index 0**

If human has [Guard, Princess] in hand, L1 will always play Guard (index 0), never Princess. Even if Princess is the only card that doesn't lose.

**Pattern 3: Guard guesses are fixed**

The Guard type loop goes `range(Deck.CardType.Priest, Deck.CardType.Unknown)`, so Guard=Guard is always the first guess. Against a human, this means L1's Guards are completely useless — they just burn your Guard and waste a turn.

**Pattern 4: Countess restriction works against L1**

If L1 holds Countess+Prince, L1 is forced to play Countess (can't Prince itself). That's a free turn for the human. If L1 holds Countess+King, same thing — forced pass. The same applies to Countess+Princess (rank 5+): L1 keeps the Princess and passes.

### What this means for "Human vs 3 L1s"

It's actually a **good** test case. The human gets to:
1. Exploit L1's predictable targeting — know every move before it happens
2. See 3 bots with identical (and exploitable) logic, making the game feel like a puzzle
3. L1's Guards are completely wasted, so the real pressure comes from Baron/Prince

But the human still struggles because:
- 3 opponents is a lot of pressure, even predictable pressure
- L1's Baron attacks are real — if L1 has Baron>Human's card, the human dies
- L1 still has Prince, which is devastating regardless of predictability

### Diversity verdict: Yes, they're distinct enough

| | Playstyle feel | Exploitable? | Human can learn? |
|---|---|---|---|
| **L1** | Robotic, relentless | Extremely | "Oh, it always attacks me with Guard" |
| **L2** | Chaotic, unhinged | N/A (random) | "I can't read it, but it's harmless" |
| **L3** | Conservative, stingy | Moderately | "It's saving that King for later..." |
| **L4** | Thoughtful, analytical | Difficult | "It's reading my hand, I need to mislead" |

They cover four quadrants: predictable, random, cost-aware, and information-aware. That's a solid spread. I wouldn't add more levels unless you want a "perfect play" (minimax/search) level as a boss battle.
