#!/usr/bin/env bash
# Regression: am_in_use must detect a process using a directory.
#
# The bug this guards: the guard used only `lsof +D`, which MISSED a running
# Chrome — measured 14 live Chrome processes out of a browser dir while
# `lsof +D` returned exit 1 ("not in use"). A prune relying on it could delete
# a browser out from under a running test.
#
# Run: bash test/in-use-guard.bash

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AM_TOOL=in-use-test
# shellcheck source=/dev/null
. "$REPO/lib/common.sh"

FAILS=0
pass(){ printf '  ok   %s\n' "$1"; }
fail(){ printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

FIX="$(mktemp -d)"
PIDS=()
cleanup(){ for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$FIX"; }
trap cleanup EXIT
mkdir -p "$FIX/browser-dir"
printf 'x' > "$FIX/browser-dir/executable"

# 1. Open file descriptor — caught by lsof, the original detector. Establish the
#    baseline that lsof does work for the case it covers.
exec 9< "$FIX/browser-dir/executable"
am_in_use "$FIX/browser-dir" && pass "detects an open file descriptor (lsof path)" \
                             || fail "missed an open file descriptor"
exec 9<&-

# 2. A live process whose argv names the dir — the case lsof +D got WRONG.
#    `tail -f` on a file inside is exactly this shape.
tail -f "$FIX/browser-dir/executable" >/dev/null 2>&1 &
TF=$!; PIDS+=("$TF")
sleep 0.4
am_in_use "$FIX/browser-dir" && pass "detects a live process whose argv names the dir" \
                             || fail "MISSED a live process naming the dir (the lsof +D blind spot)"
kill "$TF" 2>/dev/null; wait "$TF" 2>/dev/null

# 3. Nothing running: must read free. This also proves no self-match — the
#    caller's own argv contains "$FIX/browser-dir".
sleep 0.4
am_in_use "$FIX/browser-dir" && fail "false positive once idle (self-match on own argv?)" \
                             || pass "free once idle (no self-match on own argv)"

# 4. A nonexistent path is never in use.
am_in_use "$FIX/definitely-not-here" && fail "nonexistent path reported in use" \
                                     || pass "nonexistent path is not in use"

printf '\n%s\n' "$([ "$FAILS" -eq 0 ] && echo 'in-use guard tests passed' || echo "$FAILS check(s) failed")"
exit "$([ "$FAILS" -eq 0 ] && echo 0 || echo 1)"
