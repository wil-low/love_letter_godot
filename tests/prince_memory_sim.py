#!/usr/bin/env python3
"""
tests/prince_memory_sim.py - quantifies issue 4 of ai_memory_open_issues.md
(Prince clears the wrong memory slot; eliminations clear nothing).

It replays full Love Letter rounds with the rules of main/main.gd + player/player.gd
(level 4 scoring, level 4 weighted move selection, the shipped find_valid_moves
ordering, the shipped scoring bugs 1/2/3 left in place on purpose) and compares three
memory-update policies for the Prince branch / set_inactive:

  shipped  : `for pl != cur: mem[pl][cur] = Unknown`, eliminations touch nothing
  doc_fix  : section 4 fix as drafted: also `mem[*][tp] = Unknown`, eliminations
             clear the dead player's slot in everybody
  fix_plus : doc_fix minus the destructive part - the Prince player's own slot is
             left alone (his remaining card never changed)

Only the memory rules vary; the move scoring is identical in all three, so every
difference measured below comes from memory bookkeeping alone.

Run:  python3 tests/prince_memory_sim.py            # 20000 rounds x 3 player counts
      python3 tests/prince_memory_sim.py 5000
"""
import random
import sys
from collections import Counter

GUARD, PRIEST, BARON, HANDMAID, PRINCE, KING, COUNTESS, PRINCESS, UNKNOWN = range(9)
COUNTS = [5, 2, 2, 2, 2, 1, 1, 1]
GOOD, BAD, WEAK, MODERATE, LOSE = 50, 5, 10, 20, 0
NAMES = ["Guard", "Priest", "Baron", "Handmaid", "Prince", "King",
         "Countess", "Princess", "Unknown"]

# ---------------------------------------------------------------- rules


def countess_restricted(hand):
    """mirror of Player.countess_restricted()"""
    if len(hand) != 2:
        return -1
    has_countess = COUNTESS in hand
    has_men = PRINCE in hand or KING in hand
    if has_countess and has_men:
        return 0 if hand[0] == COUNTESS else 1
    return -1


def find_valid_moves(hand, cur, n, active, protected, other_protected):
    """mirror of Main.find_valid_moves(), same generation order.
    a move is (played_type, played_idx, target, target_type)"""
    moves = []
    ci = countess_restricted(hand)
    if ci != -1:
        return [(hand[ci], ci, -1, UNKNOWN)]
    for i, t in enumerate(hand):
        if t == GUARD:
            for p in range(n):
                if p != cur and active[p] and (not protected[p] or other_protected):
                    for tt in range(PRIEST, UNKNOWN):
                        moves.append((t, i, p, tt))
        elif t in (PRIEST, BARON, KING):
            for p in range(n):
                if p != cur and active[p] and (not protected[p] or other_protected):
                    moves.append((t, i, p, UNKNOWN))
        elif t in (HANDMAID, COUNTESS):
            moves.append((t, i, -1, UNKNOWN))
        elif t == PRINCE:
            for p in range(n):
                if active[p] and not protected[p]:
                    moves.append((t, i, p, UNKNOWN))
        # PRINCESS: find_valid_moves has no branch -> the AI is never offered it
    return moves


def score_move(m, hand, cur, mem, left, n, scoring="shipped", active=None):
    """scoring == "shipped": mirror of Player.eval_moves() as it stands in the tree.
       scoring == "fixed13": the drafted fixes of issues 1 and 3 -
         Guard: trust a belief only while copies of that type can still be somewhere
                (deck accounting + the copies pinned in other known hands),
         Baron/Prince: multiply by the rank of the *known* card, +1 so it never zeroes.
       Move selection, the Priest/King/Countess branches and the `valid_moves[-1]`
       tie-break (issue 2) are left untouched, so the comparison isolates 1+3."""
    card, idx, target, tgt_type = m
    my_type = hand[1 - idx]
    # player.gd: `_memory[m._target_player]`; for Handmaid/Countess _target_player == -1
    # -> GDScript negative index = last slot. Reproduced, it is unused by those branches.
    mem_t = mem[cur][target] if target != -1 else mem[cur][-1]
    score = LOSE
    if card == GUARD:
        if scoring == "fixed13":
            free = left[tgt_type] - hand.count(tgt_type)
            pinned = sum(1 for j in range(n)
                         if j != cur and j != target and mem[cur][j] == tgt_type
                         and (active is None or active[j]))
            free = max(0, free - pinned)
            if free <= 0:
                score = LOSE                      # cannot be anywhere else -> certain miss
            elif mem_t == tgt_type:
                score = GOOD * (1 + tgt_type)      # a certain hit
            else:
                score = BAD * free
        elif mem_t != UNKNOWN and mem_t != GUARD:
            if mem_t == tgt_type:
                score = GOOD * tgt_type
        else:
            l = left[tgt_type]
            if hand[0] == tgt_type:
                l -= 1
            if hand[1] == tgt_type:
                l -= 1
            score = BAD * l
    elif card == PRIEST:
        if mem_t == UNKNOWN:
            score = MODERATE
    elif card == BARON:
        if mem_t != UNKNOWN:
            if my_type > mem_t:
                # tgt_type == Unknown == 0 in the shipped code -> 0 (issue 3)
                score = GOOD * (1 + mem_t) if scoring == "fixed13" else GOOD * tgt_type
            elif my_type == mem_t:
                score = WEAK
        else:
            score = MODERATE if my_type > HANDMAID else BAD
    elif card == HANDMAID:
        score = MODERATE
    elif card == PRINCE:
        if target == cur:
            if my_type != PRINCESS:
                score = BAD if my_type > HANDMAID else WEAK
        else:
            if mem_t != UNKNOWN:
                if mem_t == PRINCESS:
                    score = GOOD * (1 + mem_t) if scoring == "fixed13" else GOOD * tgt_type
                elif mem_t > HANDMAID:
                    score = WEAK
            else:
                score = WEAK
    elif card == KING:
        if my_type == mem_t:
            score = WEAK
        elif mem_t != UNKNOWN:
            score = MODERATE if my_type < mem_t else BAD
        else:
            score = BAD
    elif card == COUNTESS:
        score = BAD
    return score


def select_move(moves, scores, rng):
    """mirror of Player.select_move() level 4 branch, fallback included"""
    s = sum(scores)
    if s == 0:
        s = 1
    r = rng.randrange(s)
    acc = 0
    for m, sc in zip(moves, scores):
        acc += sc
        if acc > r:
            return m
    return moves[-1]


# ---------------------------------------------------------------- game


class Round:
    def __init__(self, n, rng, policy, stats):
        self.n, self.rng, self.policy, self.st = n, rng, policy, stats
        self.scoring = "shipped"
        cards = [t for t, c in enumerate(COUNTS) for _ in range(c)]
        rng.shuffle(cards)
        self.widow = cards[:3 if n == 2 else 1]
        self.pile = cards[3 if n == 2 else 1:]
        self.left = COUNTS[:]
        self.hand = [[] for _ in range(n)]
        self.active = [True] * n
        self.protected = [False] * n
        self.mem = [[UNKNOWN] * n for _ in range(n)]
        for i in range(n):
            self.hand[i].append(self.pile.pop(0))
        self.cur = rng.randrange(n)

    # ------------------------------------------------ helpers
    def draw(self, p, allow_widow=False):
        if self.pile:
            self.hand[p].append(self.pile.pop(0))
        elif allow_widow and self.widow:
            self.hand[p].append(self.widow.pop(0))

    def discard_hand(self, p):
        for c in self.hand[p]:
            self.left[c] -= 1
            assert self.left[c] >= 0
        self.hand[p] = []

    def eliminate(self, p):
        self.discard_hand(p)
        self.active[p] = False
        self.st["eliminations"] += 1
        if self.policy in ("doc_fix", "fix_plus"):
            # section 4, second half: a dead player has no hand to believe in
            for pl in range(self.n):
                if self.mem[pl][p] != UNKNOWN:
                    self.st["zombie_cleared"] += 1
                self.mem[pl][p] = UNKNOWN

    def active_count(self):
        return sum(self.active)

    # ------------------------------------------------ turn
    def turn(self):
        n, cur, rng = self.n, self.cur, self.rng
        if not self.pile:
            return False                      # Main: `else: round_over()`
        self.protected[cur] = False
        self.draw(cur)
        assert len(self.hand[cur]) == 2
        other_protected = all((self.protected[p] or p == cur or not self.active[p])
                              for p in range(n))
        moves = find_valid_moves(self.hand[cur], cur, n, self.active,
                                 self.protected, other_protected)
        if not moves:
            self.st["no_legal_move"] += 1
            return False
        scores = [score_move(m, self.hand[cur], cur, self.mem, self.left, n,
                             scoring=self.scoring, active=self.active)
                  for m in moves]
        card, idx, target, tgt_type = select_move(moves, scores, rng)
        self.measure(card, target, tgt_type, scores)
        self.play(card, idx, target, tgt_type)
        return True

    def measure(self, card, target, tgt_type, scores):
        """judge the move the AI is about to play against the truth of the matter"""
        cur, st = self.cur, self.st
        st["decisions"] += 1
        # beliefs about players who are already out, visible at decision time.
        # eval_moves never reads them (targets are filtered by is_active()), so the only
        # consumer today is the Baron-tie propagation loop, which writes into dead slots.
        for j in range(self.n):
            if not self.active[j] and self.mem[cur][j] != UNKNOWN:
                st["zombie_slots_at_decision"] += 1
        if card == GUARD:
            st["guard_plays"] += 1
            t = target
            mem_t = self.mem[cur][t]
            known = mem_t not in (UNKNOWN, GUARD)
            real = self.hand[t][0]
            own = self.hand[cur].count(tgt_type)
            free = self.left[tgt_type] - own
            # copies the AI itself has pinned in other *live* hands (issue 1 extension),
            # and the copies pinned by slots that belong to players who are out (zombies)
            pin_live = sum(1 for j in range(self.n)
                           if j != cur and j != t and self.active[j]
                           and self.mem[cur][j] == tgt_type)
            pin_dead = sum(1 for j in range(self.n)
                           if j != cur and j != t and not self.active[j]
                           and self.mem[cur][j] == tgt_type)
            st["guard_hit"] += (real == tgt_type)
            st["guard_certain_miss"] += (free <= 0)
            if known and tgt_type == mem_t:
                st["guard_belief_driven"] += 1
                st["guard_belief_true"] += (real == tgt_type)
                st["guard_belief_false"] += (real != tgt_type)
                st["guard_belief_impossible"] += (free <= 0)
            elif not known:
                st["guard_count_driven"] += 1
                st["guard_count_hit"] += (real == tgt_type)
            if tgt_type == PRINCESS and PRINCESS in self.hand[cur]:
                st["guard_princess_declaration_with_princess_in_hand"] += 1
            # the issue 1 guardrail, with the drafted pinned subtraction: does it drop a
            # legal guess to zero only because a dead player's slot claims a copy?
            st["guardrail_silences_guess"] += (free - pin_live <= 0)
            if free - pin_live - pin_dead <= 0 < free - pin_live:
                st["guardrail_silenced_by_zombies"] += 1
        elif card == BARON:
            st["baron_plays"] += 1
            mem_t = self.mem[cur][target]
            real = self.hand[target][0]
            mine = self.hand[cur][0]
            st["baron_self_eliminated"] += (mine < real)
            if mem_t not in (UNKNOWN, GUARD):
                st["baron_belief_driven"] += 1
                st["baron_belief_false"] += (mem_t != real)
                if mem_t != real:
                    # the AI barons a player whose real card beats it - a suicide it
                    # committed *because of the belief*
                    st["baron_false_belief_self_kill"] += (mine < real)
                    st["baron_false_belief_miss"] += (mine > real)
        elif card == PRINCE and target != cur:
            mem_t = self.mem[cur][target]
            if mem_t == PRINCESS:
                st["prince_on_believed_princess"] += 1
                st["prince_wasted_on_no_princess"] += (self.hand[target][0] != PRINCESS)
            st["prince_plays"] += 1

    def play(self, card, idx, target, tgt_type):
        n, cur, st = self.n, self.cur, self.st
        # _on_card_played: the played card leaves the hand, beliefs that pointed at it clear
        self.hand[cur].pop(idx)
        played = card
        for pl in range(n):
            if pl != cur and self.mem[pl][cur] == played:
                # main.gd clears on card type. The observer only sees WHICH CARD was
                # played, never which slot it came from, so the referent is ambiguous:
                # idx == 0 -> the card the belief named left the hand, the belief is
                # false and must go; idx == 1 -> the player held two copies of the
                # believed type and the belief is still true.
                st["type_match_clears"] += 1
                st["type_match_clears_true"] += (idx == 1)
                st["type_match_clears_false"] += (idx == 0)
                self.mem[pl][cur] = UNKNOWN
        tp = target
        if tp != -1 and self.protected[tp]:
            self.left[played] -= 1            # discard(_table)
            return
        if played == GUARD:
            if self.hand[tp] and self.hand[tp][0] == tgt_type:
                self.eliminate(tp)
        elif played == PRIEST:
            self.mem[cur][tp] = self.hand[tp][0]
            st["priest_reveals"] += 1
        elif played == BARON:
            mine, theirs = self.hand[cur][0], self.hand[tp][0]
            if mine > theirs:
                self.eliminate(tp)
            elif mine < theirs:
                self.eliminate(cur)
            else:
                self.mem[cur][tp] = theirs
                self.mem[tp][cur] = mine
                st["baron_ties"] += 1
                for pl in range(n):
                    if pl != cur and pl != tp:
                        if self.mem[pl][cur] != UNKNOWN:
                            st["baron_tie_propagations"] += 1
                            self.mem[pl][tp] = self.mem[pl][cur]
                        elif self.mem[pl][tp] != UNKNOWN:
                            st["baron_tie_propagations"] += 1
                            self.mem[pl][cur] = self.mem[pl][tp]
        elif played == HANDMAID:
            self.protected[cur] = True
        elif played == PRINCE:
            typ = self.hand[tp][0]
            self.discard_hand(tp)
            if typ == PRINCESS:
                self.eliminate(tp)
            else:
                self.draw(tp, allow_widow=True)
                # ---- the issue 4 variants ----
                if tp != cur:
                    st["prince_on_other"] += 1
                    st["stale_slots_created"] += sum(
                        1 for pl in range(n) if self.mem[pl][tp] != UNKNOWN)
                    st["valid_slots_wiped"] += sum(
                        1 for pl in range(n)
                        if pl != cur and self.mem[pl][cur] != UNKNOWN)
                if self.policy in ("doc_fix", "fix_plus"):
                    for pl in range(n):                 # tp's new hand is unknown
                        self.mem[pl][tp] = UNKNOWN
                if self.policy != "fix_plus":
                    for pl in range(n):
                        if pl != cur:                   # the Prince player's own slot
                            self.mem[pl][cur] = UNKNOWN
        elif played == KING:
            mine, theirs = self.hand[cur][0], self.hand[tp][0]
            self.hand[cur][0], self.hand[tp][0] = theirs, mine
            self.mem[cur][tp] = mine            # what I gave them
            self.mem[tp][cur] = theirs
            for pl in range(n):
                if pl != cur and pl != tp:
                    self.mem[pl][cur], self.mem[pl][tp] = self.mem[pl][tp], self.mem[pl][cur]
        elif played == PRINCESS:
            self.eliminate(cur)
        self.left[played] -= 1                  # discard(_table)
        for p in range(n):
            if self.active[p]:
                assert len(self.hand[p]) == 1, "active player hand size"

    def play_round(self):
        while True:
            if self.active_count() == 1:
                return
            if not self.turn():
                return
            nxt = self.cur
            while True:
                nxt = (nxt + 1) % self.n
                if self.active[nxt]:
                    break
            self.cur = nxt


# ---------------------------------------------------------------- experiment


def run(n, scoring, policy, rounds, seed0):
    """The whole table uses the same (scoring, memory) pair, so the numbers describe a
    population of AIs, not a single seat."""
    st = Counter()
    wins = 0
    for k in range(rounds):
        rng = random.Random(seed0 + k)
        r = Round(n, rng, policy, st)
        r.scoring = scoring
        r.play_round()
        best = max([r.hand[i][0] for i in range(n) if r.active[i]])
        w = [i for i in range(n) if r.active[i] and r.hand[i][0] == best]
        st["rounds"] += 1
        wins += (0 in w)
    return st, wins / rounds


def rate(st, num, den):
    return "  -  " if not st[den] else f"{100.0 * st[num] / st[den]:.2f}"


PER100 = 100.0


def report(n, rounds, seed0=1234):
    print("\n" + "=" * 96)
    print(f"{n} players, {rounds} rounds per cell.  columns: memory policy "
          f"(shipped / doc_fix = section 4 as drafted / fix_plus = doc_fix without the")
    print(f"destructive clear of the Prince player's own slot).  rows: move scoring "
          f"(shipped / fixed13 = issues 1+3 fixed).")
    print("=" * 96)
    cells = {}
    for scoring in ("shipped", "fixed13"):
        for policy in ("shipped", "doc_fix", "fix_plus"):
            cells[(scoring, policy)] = run(n, scoring, policy, rounds, seed0)
    policies = ("shipped", "doc_fix", "fix_plus")
    hdr = f"{'metric':<52}" + "".join(f"{p:>13}" for p in policies)
    for scoring in ("shipped", "fixed13"):
        print(f"\n--- move scoring: {scoring} ---")
        print(f"{'memory policy ->':<52}" + "".join(f"{p:>13}" for p in policies))
        print("-" * len(hdr))
        st0 = cells[(scoring, "shipped")][0]
        rows = [
            ("rounds played", st0["rounds"]),
        ]
        for label, key in (
                ("AI decisions", "decisions"),
                ("Guard plays", "guard_plays"),
                ("  driven by a belief", "guard_belief_driven"),
                ("    belief TRUE  -> a real hit", "guard_belief_true"),
                ("    belief FALSE -> a certain miss", "guard_belief_false"),
                ("    belief names a card already out of play", "guard_belief_impossible"),
                ("  driven by the card count", "guard_count_driven"),
                ("Guard hit rate %", None),
                ("Guard plays that were a certain miss %", None),
                ("'Princess' declared while holding the Princess",
                 "guard_princess_declaration_with_princess_in_hand"),
                ("Baron plays", "baron_plays"),
                ("  driven by a belief", "baron_belief_driven"),
                ("    belief FALSE", "baron_belief_false"),
                ("    -> AI eliminated itself on a false belief", "baron_false_belief_self_kill"),
                ("Prince plays on others", "prince_plays"),
                ("  aimed at a believed Princess", "prince_on_believed_princess"),
                ("    wasted (nothing there)", "prince_wasted_on_no_princess"),
                ("Priest reveals (knowledge gained)", "priest_reveals"),
                ("Baron ties / propagations", "baron_ties"),
                ("stale slots created per 100 rounds", None),
                ("valid slots destroyed per 100 rounds", None),
                ("plays matching a belief (main.gd clears)", "type_match_clears"),
                ("  played card WAS the hand card: clear required", "type_match_clears_false"),
                ("  player held a duplicate: belief stayed true", "type_match_clears_true"),
                ("  % of true beliefs destroyed by the clear", None),
                ("beliefs about dead players, at decisions", "zombie_slots_at_decision"),
                ("issue 1 guardrail: guesses it zeroes", "guardrail_silences_guess"),
                ("  ... only because of a dead player's slot", "guardrail_silenced_by_zombies"),
                ("eliminations", "eliminations"),
                ("round win rate for seat 0 (1/{} = even)".format(n), None)):
            if label == "Guard hit rate %":
                vals = [rate(cells[(scoring, p)][0], "guard_hit", "guard_plays")
                        for p in policies]
            elif label == "Guard plays that were a certain miss %":
                vals = [rate(cells[(scoring, p)][0], "guard_certain_miss", "guard_plays")
                        for p in policies]
            elif label == "round win rate for seat 0 (1/{} = even)".format(n):
                vals = [f"{100.0 * cells[(scoring, p)][1]:.2f}" for p in policies]
            elif label == "stale slots created per 100 rounds":
                vals = [f"{PER100 * cells[(scoring, p)][0]['stale_slots_created'] / rounds:.2f}"
                        for p in policies]
            elif label == "valid slots destroyed per 100 rounds":
                vals = [f"{PER100 * cells[(scoring, p)][0]['valid_slots_wiped'] / rounds:.2f}"
                        for p in policies]
            elif label == "  % of true beliefs destroyed by the clear":
                vals = [rate(cells[(scoring, p)][0], "type_match_clears_true",
                             "type_match_clears") for p in policies]
            else:
                vals = [str(cells[(scoring, p)][0][key]) for p in policies]
            print(f"{label:<52}" + "".join(f"{v:>13}" for v in vals))


if __name__ == "__main__":
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    for n in (2, 3, 4):
        report(n, rounds)
