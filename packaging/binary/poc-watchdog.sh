#!/usr/bin/env bash
# Watch an emulated build container and kill it if it has stopped doing work.
#
#   packaging/binary/poc-watchdog.sh breeze-poc-aarch64 [percent] [minutes]
#
# ── Why this exists ─────────────────────────────────────────────────────────
# A QEMU build that has deadlocked is indistinguishable from a slow one by
# eye: no error, no output, the container still "Up". The only tell is CPU
# usage — qemu-user's futex handling wedges under a parallel cargo build and
# every guest thread parks in state S at ~0.0% forever. Waiting on that costs
# hours; killing it costs a restart.
#
# So: sample CPU, and if it stays under `percent` for `minutes` straight,
# declare it stalled and kill the container so the build exits with an error
# instead of hanging. Exits 0 when the container finishes on its own, 2 when it
# killed a stall.
#
# The threshold is deliberately low. Even single-crate compiles hold one core
# at ~100%, and the emulated idle floor is ~0.0-0.2%, so 1% cleanly separates
# "working" from "wedged" without needing to know how fast the target is.
set -uo pipefail

NAME="${1:?container name}"
PCT="${2:-1}"          # below this counts as idle
MINS="${3:-5}"         # this many consecutive idle minutes = stalled
EVERY=20               # seconds between samples
NEEDED=$(( MINS * 60 / EVERY ))

echo "watchdog: $NAME — stall = under ${PCT}% for ${MINS}m ($NEEDED samples of ${EVERY}s)"

idle=0
# Give the container a moment to exist; a build that hasn't started yet isn't
# stalled, and neither is one already finished.
for _ in $(seq 1 30); do
  docker inspect -f '{{.State.Running}}' "$NAME" >/dev/null 2>&1 && break
  sleep 2
done

while true; do
  running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo gone)"
  case "$running" in
    true) : ;;
    *)    echo "watchdog: $NAME finished on its own — nothing to do"; exit 0 ;;
  esac

  # "12.34%" -> 12 (integer compare keeps this dependency-free)
  raw="$(docker stats --no-stream --format '{{.CPUPerc}}' "$NAME" 2>/dev/null | tr -d ' %')"
  cpu="${raw%%.*}"
  [ -z "$cpu" ] && cpu=0

  if [ "$cpu" -lt "$PCT" ] 2>/dev/null; then
    idle=$(( idle + 1 ))
    echo "watchdog: ${raw:-?}% idle ($idle/$NEEDED)"
    if [ "$idle" -ge "$NEEDED" ]; then
      echo "watchdog: STALLED for ${MINS}m at under ${PCT}% — killing $NAME"
      # Snapshot what the guest threads were doing; this is the evidence that
      # says "deadlock" rather than "slow", and it's gone once the container is.
      docker exec "$NAME" sh -c 'for d in /proc/[0-9]*; do
          s=$(awk "{print \$3}" "$d/stat" 2>/dev/null)
          c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null | cut -c1-60)
          [ -n "$c" ] && echo "  pid ${d#/proc/} [$s] $c"
        done' 2>/dev/null | tail -12
      docker kill "$NAME" >/dev/null 2>&1
      exit 2
    fi
  else
    [ "$idle" -gt 0 ] && echo "watchdog: back to ${raw}% — idle counter reset"
    idle=0
  fi
  sleep "$EVERY"
done
