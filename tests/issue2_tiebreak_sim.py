"""Issue 2 probe: what does the `valid_moves[-1]` tie-break in select_move() actually cost?

Reuses tests/prince_memory_sim.py - same rules, same deck, same memory bookkeeping, same
eval_moves scoring, same weighted select_move - and changes **only** the branch that is taken
when every move in the list scores 0:

    last     -> shipped:  return valid_moves[-1]
    uniform -> drafted:   return valid_moves[randi() % len(valid_moves)]
    first  -> control:   return valid_moves[0]

Three things are counted at every such decision:

  * `fell_through_loop` - how often the weighted prefix-sum loop runs out and reaches
    `valid_moves[-1]` from a *non*-zero sum. EvalScore's floor is `LOSE = 0` and no branch of
    eval_moves can go negative, so the answer must be "never"; the counter is the assertion.
  * `len == 1` - how often the zero-score list has a single legal move, i.e. there is no tie
    to break and all three policies are the same policy.
  * what the last generated move *is*, since "the last move is the Princess declaration" is
    only true for the slice of turns where a Guard happens to be the last card in hand.

Win rates use paired seeds, so the three policies see the same 3 x rounds deals.

    python3 tests/issue2_tiebreak_sim.py                 # 10 000 4-player rounds x 3 seeds
    python3 tests/issue2_tiebreak_sim.py 3000 4 fixed13  # issue 1+3 scoring
    python3 tests/issue2_tiebreak_sim.py 2000 3          # 3-player games

Modes: `shipped` is eval_moves as it stands; `fixed13` is the section 1 (+ 3) guardrail, where
a Guard guess on a type that cannot be in any unknown hand scores LOSE. `fixed13` is the
knock-on measurement: does issue 1's guardrail feed the zero-score fallback?
"""
import importlib.util
import math
import os
import random
import sys
from collections import Counter

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "sim", os.path.join(_HERE, "prince_memory_sim.py"))
sim = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sim)

NAME = {sim.GUARD: "Guard", sim.PRIEST: "Priest", sim.BARON: "Baron", sim.HANDMAID: "Handmaid",
        sim.PRINCE: "Prince", sim.KING: "King", sim.COUNTESS: "Countess",
        sim.PRINCESS: "Princess", sim.UNKNOWN: "-"}

MODE = ["last"]
Z = Counter()          # counters measured at zero-score decisions
T = Counter()          # counters measured at every decision


def select_move(moves, scores, rng):
    """mirror of Player.select_move() level 4 branch, with the tie-break swapped"""
    s = sum(scores)
    if s == 0:
        T["decisions_zero"] += 1
        Z["moves_offered"] += len(moves)
        Z["len1"] += (len(moves) == 1)
        Z["all_moves_are_guard_probes"] += all(c == sim.GUARD for c, _, _, _ in moves)
        last = moves[-1]
        Z["last:" + NAME[last[0]]] += 1
        if last[0] == sim.GUARD:
            Z["last_guess:" + NAME[last[3]]] += 1
        first = moves[0]
        Z["first:" + NAME[first[0]]] += 1
        return {"last": moves[-1], "uniform": rng.choice(moves), "first": moves[0]}[MODE[0]]
    r = rng.randrange(s)
    acc = 0
    for m, sc in zip(moves, scores):
        acc += sc
        if acc > r:
            return m
    T["fell_through_loop"] += 1
    return moves[-1]


sim.select_move = select_move


def run(n, scoring, policy, rounds, seed0):
    st = Counter()
    wins = 0
    for k in range(rounds):
        rng = random.Random(seed0 + k)
        r = sim.Round(n, rng, policy, st)
        r.scoring = scoring
        r.play_round()
        best = max([r.hand[i][0] for i in range(n) if r.active[i]])
        w = [i for i in range(n) if r.active[i] and r.hand[i][0] == best]
        st["rounds"] += 1
        wins += (0 in w)
    return st, wins / rounds


def report(n, rounds, scoring, seeds):
    print("=" * 100)
    print(f"issue 2 tie-break probe: {n} players, {rounds} rounds x {len(seeds)} paired seeds "
          f"({seeds}), scoring = {scoring}")
    print("=" * 100)
    out = {}
    for mode in ("last", "uniform", "first"):
        MODE[0] = mode
        Z.clear()
        T.clear()
        tot = Counter()
        wrs = []
        for sd in seeds:
            st, wr = run(n, scoring, "shipped", rounds, sd)
            tot += st
            wrs.append(100.0 * wr)
        out[mode] = (tot, wrs)
        d = tot["decisions"]
        print(f"\n--- tie-break: {mode} " + "-" * (78 - len(mode)))
        print(f"decisions                                     {d:>12}")
        print(f"zero-score decisions (fallback fires)         {T['decisions_zero']:>12}"
              f"  ({100.0 * T['decisions_zero'] / d:.3f}% of decisions)")
        print(f"weighted loop fell through on a nonzero sum   {T['fell_through_loop']:>12}"
              f"   <- must be 0: LOSE = 0 is the floor of the table")
        z = T["decisions_zero"]
        print(f"  ... the move list had exactly 1 move        {Z['len1']:>12}"
              f"  ({100.0 * Z['len1'] / z:.1f}% - no tie to break)")
        print(f"  ... every legal move is a Guard probe       "
              f"{Z['all_moves_are_guard_probes']:>12}"
              f"  ({100.0 * Z['all_moves_are_guard_probes'] / z:.1f}%)")
        print(f"  ... moves offered per zero-score turn       "
              f"{Z['moves_offered'] / z:>12.1f}")
        print("  last generated move:",
              "  ".join(f"{k[5:]} {v}" for k, v in sorted(Z.items(), key=lambda kv: -kv[1])
                        if k.startswith("last:")))
        print("  first generated move:",
              "  ".join(f"{k[6:]} {v}" for k, v in sorted(Z.items(), key=lambda kv: -kv[1])
                        if k.startswith("first:")))
        print("  last generated Guard guess:",
              "  ".join(f"{k[11:]} {v}" for k, v in sorted(Z.items(), key=lambda kv: -kv[1])
                        if k.startswith("last_guess:")))
        print(f"guard plays                                   {tot['guard_plays']:>12}"
              f"   hit {100.0 * tot['guard_hit'] / tot['guard_plays']:.2f}%"
              f"   certain miss {tot['guard_certain_miss']}")
        print(f"'Princess' declared while holding the Princess"
              f"  {tot['guard_princess_declaration_with_princess_in_hand']:>12}")
        print(f"eliminations                                  {tot['eliminations']:>12}")
        print(f"seat 0 round win rate                         "
              + " ".join(f"{w:>6.2f}" for w in wrs)
              + f"   mean {sum(wrs) / len(wrs):.2f}")
    d0 = out["last"][1]
    print("\n" + "-" * 100)
    sd = 100.0 * math.sqrt(0.25 * 0.75 / (rounds * len(seeds)))
    print("seat 0 win rate, mean over seeds: "
          + "  ".join(f"{m} {sum(v[1]) / len(v[1]):.2f}" for m, v in out.items())
          + f"   (Monte-Carlo sd over {rounds * len(seeds)} rounds ~ {sd:.2f}pp)")
    print("the last-move columns are measured inside each block, so they differ slightly between")
    print("policies - a different pick changes the rest of the round (and with it the deals).")


if __name__ == "__main__":
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    scoring = sys.argv[3] if len(sys.argv) > 3 else "shipped"
    report(n, rounds, scoring, [1234, 777, 4242])
