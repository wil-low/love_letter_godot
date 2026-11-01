#!/usr/bin/env python3
"""Measurements for section 5 of ai_memory_open_issues.md: is `_left` the right pool for
the level 4 Guard-count heuristic (`EvalScore.BAD * left_cards[t]`, player.gd:232-237)?

Deck model mirrors deck/deck.gd: counts [5,2,2,2,2,1,1,1], widow = 1 card (3-4 players)
or 3 cards (2 players). `_left[t]` in main.gd = copies of t not in the discard
= draw pile + widow + every player's hand.

Estimators compared (all pick the argmax = the Guard guess the heuristic would make):

  raw        COUNTS - own - discard                      (the current code, player.gd:232)
  widow_sub  raw - widow                                 (the rejected "fix 1": needs _widow_cards)
  pinned_sub raw - the copy pinned in one Priest-revealed hand (issue 1's guardrail)
  ideal      realized copies in the opponents' hands     (oracle, unattainable)

Run:  python3 tests/left_cards_sim.py [iters]
"""
import random
import sys
from collections import Counter

COUNTS = [5, 2, 2, 2, 2, 1, 1, 1]  # Guard, Priest, Baron, Handmaid, Prince, King, Countess, Princess


def deal(n_players, k_discard, rng):
    """Random legal partition of the 16 cards: discard, widow, my 2, one per opponent, rest pile."""
    cards = [t for t, c in enumerate(COUNTS) for _ in range(c)]
    rng.shuffle(cards)
    discard, cards = cards[:k_discard], cards[k_discard:]
    widow_n = 1 if n_players != 2 else 3
    widow, cards = cards[:widow_n], cards[widow_n:]
    me, cards = cards[:2], cards[2:]
    hands = []
    for _ in range(n_players - 1):
        hands.append(cards[0])
        cards = cards[1:]
    return Counter(me), Counter(discard), Counter(widow), hands


def argmax(est, rng):
    return max(range(len(est)), key=lambda t: (est[t], rng.random()))


def experiment(n_players, k_discard, reveal, iters, seed):
    rng = random.Random(seed)
    hits, zero, picks = Counter(), Counter(), Counter()
    scored = Counter()
    for _ in range(iters):
        own, disc, widow, hands = deal(n_players, k_discard, rng)
        opponents = len(hands)
        base = [COUNTS[t] - own[t] - disc[t] for t in range(8)]
        ests = {
            "raw": base,
            "widow_sub": [base[t] - widow[t] for t in range(8)],
            "ideal": [sum(1 for c in hands if c == t) for t in range(8)],
        }
        # a Priest reveal pins one opponent's card; guess on a *different*, unknown player,
        # so the count branch (not the memory branch) is the one being exercised
        knower = rng.randrange(opponents)
        pinned = hands[knower]
        cands = [i for i in range(opponents) if i != knower]
        if reveal and cands:
            ests["pinned_sub"] = [base[t] - (1 if t == pinned else 0) for t in range(8)]
            target = rng.choice(cands)
        else:
            target = rng.randrange(opponents)
        actual = hands[target]
        for name, est in ests.items():
            best = argmax(est, rng)
            hits[name] += best == actual
            zero[name] += all(c != best for c in hands)  # the type is in NO hand: certain miss
            picks[name] += best == pinned
            scored[name] += 5 * est[best]  # EvalScore.BAD * left
    return hits, zero, picks, scored, {"raw": 1, "widow_sub": 1, "pinned_sub": 1, "ideal": 1}


def report(title, n_players, depths, reveal):
    print(f"\n{title}")
    names = ["raw", "widow_sub", "pinned_sub", "ideal"] if reveal else ["raw", "widow_sub", "ideal"]
    print(f"{'discards':>8}  " + "".join(f"{n:>26}" for n in names))
    for k in depths:
        hits, zero, picks, scored, _ = experiment(n_players, k, reveal, ITERS, 11 + k)
        cells = []
        for n in names:
            cells.append(
                f"hit={hits[n] / ITERS:.4f} zero={zero[n] / ITERS:.2f} avg={scored[n] / ITERS:5.2f}"
            )
        print(f"{k:>8}  " + "".join(f"{c:>26}" for c in cells))
        if reveal:
            print(f"{'':>8}  picks the pinned (known elsewhere) type: " +
                  "  ".join(f"{n}={picks[n] / ITERS:.3f}" for n in names))


ITERS = int(sys.argv[1]) if len(sys.argv) > 1 else 200000

print(f"deck counts {COUNTS}, EvalScore.BAD = 5, iterations = {ITERS}")
print("theoretical ceiling of `raw` in a fresh 4-player round (argmax is always Guard):")
print(f"  (5 - 2*5/16) / 14 = {(5 - 2 * 5 / 16) / 14:.4f}")

report("4 players (widow 1), one Priest reveal, guess on an unknown player", 4, [0, 2, 4, 6, 8, 10], True)
report("2 players (widow 3), no memory - count branch always used", 2, [0, 4, 8, 10], False)
report("3 players (widow 1), one Priest reveal, guess on an unknown player", 3, [0, 4, 8, 10], True)

print(
    "\nreading: `raw` == the shipped heuristic. At 0 discards its hit rate matches the exact\n"
    "Bayes posterior (the widow is in the denominator, where it belongs), so `widow_sub` can\n"
    "only differ by using _widow_cards - hidden information; in a 2-player game at 10 discards\n"
    "it solves the last guess outright (see section 5). `pinned_sub` is the legitimate gap."
)
