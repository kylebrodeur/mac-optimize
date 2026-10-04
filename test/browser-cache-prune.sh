#!/usr/bin/env bash
# Regression: the SAFE reclaim tier must never delete a pinned browser.
#
# This is the bug that motivated the whole change: mac-reclaim's safe tier did
# `rm -rf ~/Library/Caches/ms-playwright`, and since a Playwright browser is a
# pinned ~560MB binary rather than a rebuildable cache, the next test run
# re-downloaded every byte the reclaim had just freed. Caught in the act — the
# weekly launchd run freed 1010MB and the browser dirs came back minutes later.
#
# This runs against the VENDORED lib (lib/common.sh), so it also proves the
# consumer actually shipped the fix.
#
# Run: bash test/browser-cache-prune.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

AM_TOOL=mac-reclaim
# shellcheck source=/dev/null
. "$REPO/lib/common.sh"

FAILS=0
pass(){ printf '  ok   %s\n' "$1"; }
fail(){ printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# A cache shaped like a real ms-playwright: a live .links pointer at an
# installed playwright-core, plus pinned and superseded revision dirs.
mkdir -p "$FIX/.links" "$FIX/pw-core"
cat > "$FIX/pw-core/browsers.json" <<'JSON'
{"browsers":[
 {"name":"chromium","revision":"1243","installByDefault":true},
 {"name":"chromium-headless-shell","revision":"1243","installByDefault":true}
]}
JSON
printf '%s\n' "$FIX/pw-core" > "$FIX/.links/abc123"

mkdir -p "$FIX/chromium-1243" "$FIX/chromium_headless_shell-1243" "$FIX/chromium-900"
head -c 4096 /dev/zero > "$FIX/chromium-1243/blob"
head -c 4096 /dev/zero > "$FIX/chromium_headless_shell-1243/blob"
head -c 4096 /dev/zero > "$FIX/chromium-900/blob"
touch -t 202001010000 "$FIX/chromium-900"   # the superseded one

out="$(BROWSER_KEEP_NEWEST=0 am_browser_cache_prune "$FIX" 0 am_default_emit)"

[ -d "$FIX/chromium-1243" ] && pass "pinned chromium survived the safe tier" \
                           || fail "pinned chromium was deleted by the safe tier"
[ -d "$FIX/chromium_headless_shell-1243" ] && pass "pinned headless shell survived" \
                                           || fail "pinned headless shell was deleted"
[ -d "$FIX/chromium-900" ] && fail "superseded revision should have been reaped" \
                          || pass "superseded revision still reaped (reclaim kept working)"
case "$out" in
  *"chromium r1243 kept — pinned"*) pass "pinned revision reported as kept" ;;
  *) fail "pinned revision not reported as kept"; printf '%s\n' "$out" ;;
esac

# The vendored lib must not carry the old destructive line either.
if grep -qE '(^|[[:space:]])(d|dir)=.*ms-playwright.*(&&|;).*(rm -rf|rm -r )' "$REPO/lib/common.sh"; then
  fail "vendored lib still rm -rf's the Playwright cache"
else
  pass "vendored lib has no blind Playwright cache delete"
fi

printf '\n%s\n' "$([ "$FAILS" -eq 0 ] && echo 'safe-tier browser guard passed' || echo "$FAILS check(s) failed")"
exit "$([ "$FAILS" -eq 0 ] && echo 0 || echo 1)"
