#!/usr/bin/env bash
# Classic regression sweep (docs/noble-family-todo.md step 32): run EVERY suite in a
# process-at-a-time sequence, print exit code / seconds / SCRIPT ERROR / FAIL counts, exit 0 only
# when all of them are clean.
#
#   ./tests/classic_sweep.sh                 # all five classic suites, belief_truth at --rounds=150
#   ./tests/classic_sweep.sh --rounds=50     # the extra arg goes to repro_belief_truth only
#   SWEEP_DIR=/tmp/x SWEEP_TIMEOUT=600 ./tests/classic_sweep.sh
#
# WHY A SCRIPT: step 32 is a gate over five suites, and five hand-typed commands are five ways to
# forget one. ONE AT A TIME is not style: leftover godot processes from a finished batch hide the
# cause of a stalled run (progress.txt step 30), and a scene whose root script FAILS TO LOAD runs
# FOREVER, so every run is timeout-bounded and `Failed to load script` is what separates a parse
# failure from a stall. stdout is block-buffered into a file -> stdbuf -oL.
#
# The classic gate `tests/smoke_games.tscn` ALREADY nests the noble rules suite (step 22), so this
# sweep does not add a second copy of it: a game's round end consumes global RNG and shifts the
# scripted fixtures' measured counts (progress.txt step 31). The two variant suites run here because
# they share main.gd / player.gd / deck.gd with the classic ones.
set -u
cd "$(dirname "$0")/.." || exit 2

BELIEF_ARGS="--rounds=150"
for a in "$@"; do BELIEF_ARGS="$a"; done

DIR="${SWEEP_DIR:-/tmp/classic_sweep}"
TIMEOUT="${SWEEP_TIMEOUT:-1500}"
rm -rf "$DIR"; mkdir -p "$DIR"

log() { printf '%s\n' "[$(date +%H:%M:%S)] $*"; }

printf '%-34s %5s %6s %11s %5s\n' SUITE EXIT SECONDS SCRIPT_ERR FAIL
printf '%s\n' "----------------------------------------------------------------"

total=0; CLASSIC=0; VARIANT=0

# run <classic|variant> <suite path> [godot args after the scene path...]
run() {
	local kind="$1"; shift
	local name="$1"; shift
	local log="$DIR/${name##*/}.log" st="$DIR/${name##*/}.status"
	local start=$SECONDS
	( stdbuf -oL timeout "$TIMEOUT" godot --headless --path . "$@" >"$log" 2>&1; echo $? >"$st" ) &
	local pid=$!
	while kill -0 "$pid" 2>/dev/null; do sleep 5; done
	wait "$pid" 2>/dev/null
	local code; code=$(cat "$st")
	local secs=$((SECONDS - start))
	# `Failed to load script` is the parse failure a timeout shows as 124; SCRIPT ERROR is a runtime one.
	local serr; serr=$(grep -c -e 'SCRIPT ERROR' -e 'Failed to load script' "$log")
	# A CHECK LINE starts with FAIL. The word also occurs INSIDE PASS prose ("a LONGER string in the
	# scene is a FAIL, not a layout choice"); an unanchored grep reported 2 failures on a suite that
	# printed 1433 PASS / 0 FAIL and exit 0.
	local fails; fails=$(grep -cE '^[[:space:]]*FAIL' "$log")
	[ "$kind" = "classic" ] && CLASSIC=$((CLASSIC + 1))
	[ "$kind" = "variant" ] && VARIANT=$((VARIANT + 1))
	printf '%-34s %5s %6s %11s %5s\n' "${name##*/}" "$code" "$secs" "$serr" "$fails"
	log "$name exit=$code secs=$secs script_err=$serr fail=$fails"
	[ "$code" -ne 0 ] && total=$((total + 1))   # 124 == the run hit the ${TIMEOUT}s timeout
	[ "$serr" -ne 0 ] && total=$((total + 1))
	[ "$fails" -ne 0 ] && total=$((total + 1))
}

for s in tests/smoke_games.tscn tests/repro_guard_princess.tscn tests/repro_prince_memory.tscn \
	tests/repro_score_multiplier.tscn; do run classic "$s" "$s"; done
run classic tests/repro_belief_truth.tscn tests/repro_belief_truth.tscn -- "$BELIEF_ARGS"
for s in tests/noble_family_smoke.tscn tests/noble_family_rules.tscn; do run variant "$s" "$s"; done

log "logs: $DIR  suites: $CLASSIC classic + $VARIANT variant  problem lines: $total"
[ "$total" -eq 0 ] && { log "SWEEP OK"; exit 0; }
log "SWEEP FAILED"; exit 1
