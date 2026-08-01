#!/usr/bin/env bash
# Regression test for VS Code workspaceStorage safety in mac-reclaim --deep.
#
# Until an archive-first backup exists, orphaned workspaceStorage directories
# must never be listed as deletion candidates merely because workspace.json
# points to a missing project. Unknown files must force review, and the presence
# of state.vscdb/chatSessions must keep the entry protected.

set -euo pipefail

fail=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"

WSROOT="$TMP_HOME/Library/Application Support/Code/User/workspaceStorage"
mkdir -p "$WSROOT"

# Fake lsof marks one fixture as open while leaving other entries closed.
FAKE_BIN="$TMP_HOME/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *4444444444444444*) exit 0 ;;
  *)
    if [ "${LSOF_FAIL:-0}" = 1 ]; then
      printf 'lsof: simulated traversal failure\n' >&2
      exit 1
    fi
    exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/lsof"

# Keep --yes runs isolated from real cache commands.
for tool in pnpm uv npm pip go cargo-cache brew bun agent-session-kill; do
  cat > "$FAKE_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_BIN/$tool"
done

# Fixture 1: orphan containing live-looking VS Code state (chat sessions).
WS1_ID="1111111111111111"
WS1="$WSROOT/$WS1_ID"
mkdir -p "$WS1/chatSessions"
printf '{"folder":"file:///does/not/exist/project1"}\n' > "$WS1/workspace.json"
touch "$WS1/state.vscdb"
printf '{"messages":[]}\n' > "$WS1/chatSessions/session.json"

# Fixture 2: orphan containing an unrecognized file (no chat dirs).
WS2_ID="2222222222222222"
WS2="$WSROOT/$WS2_ID"
mkdir -p "$WS2"
printf '{"folder":"file:///does/not/exist/project2"}\n' > "$WS2/workspace.json"
printf 'unrecognized data\n' > "$WS2/unknown-file.txt"

# Fixture 3: orphan containing only workspace.json + state.vscdb.
WS3_ID="3333333333333333"
WS3="$WSROOT/$WS3_ID"
mkdir -p "$WS3"
printf '{"folder":"file:///does/not/exist/project3"}\n' > "$WS3/workspace.json"
touch "$WS3/state.vscdb"

WS4_ID="4444444444444444"
WS4="$WSROOT/$WS4_ID"
mkdir -p "$WS4"
printf '{"folder":"file:///does/not/exist/project4"}\n' > "$WS4/workspace.json"
printf 'open orphan data\n' > "$WS4/unknown-file.txt"

REL_WS1="~/Library/Application Support/Code/User/workspaceStorage/$WS1_ID"
REL_WS2="~/Library/Application Support/Code/User/workspaceStorage/$WS2_ID"
REL_WS3="~/Library/Application Support/Code/User/workspaceStorage/$WS3_ID"
REL_WS4="~/Library/Application Support/Code/User/workspaceStorage/$WS4_ID"

OUT=$(PATH="$FAKE_BIN:$PATH" "$REPO_ROOT/bin/mac-reclaim" --deep --dry-run 2>&1)
TOTAL_LINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')

# Section heading: first line whose first significant word is review or protected
# (case-insensitive), possibly preceded by decorative punctuation. Portable
# word boundary: (^|[^[:alnum:]_])(review|protected)([^[:alnum:]_]|$).
MARKER_RE='^[[:space:]]*[-=]*[[:space:]]*(review|protected)([^[:alnum:]_]|$)'
MARKER_LINE=$(printf '%s\n' "$OUT" | grep -n -Ei "$MARKER_RE" | head -n1 | cut -d: -f1) || true
[ -n "$MARKER_LINE" ] || MARKER_LINE=0

# If the marker exists, bound the review/protected section at the next section
# heading. A section heading is a non-indented alpha line ending with a colon,
# or a decorative separator line, that is not itself a review/protected marker.
SECTION_END=$((TOTAL_LINES + 1))
if [ "$MARKER_LINE" -ne 0 ]; then
  NEXT_HEADING=$(printf '%s\n' "$OUT" | tail -n +$((MARKER_LINE + 1)) | \
    grep -n -Ei '^[[:space:]]*[[:alpha:]][^:]*:[[:space:]]*$|^[[:space:]]*[-=]{3,}[[:space:]]*$' | \
    grep -Eiv "$MARKER_RE" | head -n1 | cut -d: -f1) || true
  if [ -n "$NEXT_HEADING" ]; then
    SECTION_END=$((NEXT_HEADING + MARKER_LINE))
  fi
fi

# Classify every output line containing the fixture path. The only acceptable
# classification is exactly one dedicated line inside the bounded review/protected
# section. Any occurrence outside that section is a deletion candidate and must
# be rejected; silent omission is also rejected. A dedicated review line that
# still carries the current deletion reason ("orphan: project folder gone") is
# likewise rejected.
classify_fixture() {
  local rel_path="$1" desc="$2"
  local all_lines section_lines outside_lines section_count
  all_lines=$(printf '%s\n' "$OUT" | grep -n -F "$rel_path" || true)

  if [ -z "$all_lines" ]; then
    echo "FAIL: $desc path $rel_path omitted from output entirely"
    fail=1
    return
  fi

  if [ "$MARKER_LINE" -eq 0 ]; then
    echo "FAIL: $desc path $rel_path appears outside any review/protected section (no heading found):"
    printf '%s\n' "$all_lines" | sed 's/^[0-9]*://' | sed 's/^/    /'
    fail=1
    return
  fi

  section_lines=$(printf '%s\n' "$all_lines" | awk -v s="$MARKER_LINE" -v e="$SECTION_END" -F: '$1 >= s && $1 < e {print}')
  outside_lines=$(printf '%s\n' "$all_lines" | awk -v s="$MARKER_LINE" -v e="$SECTION_END" -F: '$1 < s || $1 >= e {print}')

  if [ -n "$outside_lines" ]; then
    echo "FAIL: $desc path $rel_path appears in deletion-candidate output outside the review/protected section:"
    printf '%s\n' "$outside_lines" | sed 's/^[0-9]*://' | sed 's/^/    /'
    fail=1
  fi

  section_count=$(printf '%s\n' "$section_lines" | grep -c . || true)
  if [ "$section_count" -ne 1 ]; then
    echo "FAIL: $desc path $rel_path expected exactly one dedicated review/protected line, found $section_count"
    fail=1
    return
  fi

  review_line=$(printf '%s\n' "$section_lines" | sed 's/^[0-9]*://')
  for other in "$REL_WS1" "$REL_WS2" "$REL_WS3"; do
    [ "$other" = "$rel_path" ] && continue
    if printf '%s\n' "$review_line" | grep -Fq "$other"; then
      echo "FAIL: $desc path $rel_path dedicated line also contains another fixture path ($other):"
      printf '%s\n' "$review_line" | sed 's/^/    /'
      fail=1
      return
    fi
  done

  if printf '%s\n' "$review_line" | grep -Fiq 'orphan: project folder gone'; then
    echo "FAIL: $desc path $rel_path dedicated line still reads as the known deletion-candidate reason:"
    printf '%s\n' "$section_lines" | sed 's/^[0-9]*://' | sed 's/^/    /'
    fail=1
    return
  fi

  echo "PASS: $desc path $rel_path appears exactly once in the review/protected section"
}

classify_fixture "$REL_WS1" "chat-bearing orphan"
classify_fixture "$REL_WS4" "open orphan"
classify_fixture "$REL_WS2" "unknown-file orphan"
classify_fixture "$REL_WS3" "state.vscdb-only orphan"

OPEN_CHECK_FIXTURE="$TMP_HOME/Library/Application Support/Claude/vm_bundles/open-check-unavailable"
REL_OPEN="~/Library/Application Support/Claude/vm_bundles/open-check-unavailable"
mkdir -p "$OPEN_CHECK_FIXTURE"
touch -t 202401010000 "$OPEN_CHECK_FIXTURE"
FAIL_OUT=$(LSOF_FAIL=1 KEEP_DAYS=0 KEEP_RECENT=0 PATH="$FAKE_BIN:$PATH" "$REPO_ROOT/bin/mac-reclaim" --deep --dry-run 2>&1)
DELETE_SECTION=$(printf '%s\n' "$FAIL_OUT" | sed -n '/^Deletion candidates:/,$p')
if ! printf '%s\n' "$FAIL_OUT" | grep -Fq "open-file check unavailable"; then
  echo "FAIL: unavailable lsof check was not reported"
  fail=1
elif printf '%s\n' "$DELETE_SECTION" | grep -Fq "$REL_OPEN"; then
  echo "FAIL: unavailable lsof check exposed an idle deletion candidate"
  printf '%s\n' "$DELETE_SECTION"
  fail=1
else
  echo "PASS: unavailable lsof check protected idle deep-tier state"
fi

FAIL_YES_OUT=$(LSOF_FAIL=1 KEEP_DAYS=0 KEEP_RECENT=0 PATH="$FAKE_BIN:$PATH" "$REPO_ROOT/bin/mac-reclaim" --deep --yes 2>&1)
if [ ! -d "$OPEN_CHECK_FIXTURE" ] || ! printf '%s\n' "$FAIL_YES_OUT" | grep -Fq "open-file check unavailable"; then
  echo "FAIL: --yes removed or failed to report unavailable open-check state"
  fail=1
else
  echo "PASS: --yes retained state when open-file check was unavailable"
fi

CONTROL_FIXTURE="$TMP_HOME/Library/Application Support/Claude/vm_bundles/closed-control"
mkdir -p "$CONTROL_FIXTURE"
touch -t 202401010000 "$CONTROL_FIXTURE"
KEEP_DAYS=0 KEEP_RECENT=0 PATH="$FAKE_BIN:$PATH" "$REPO_ROOT/bin/mac-reclaim" --deep --yes >/dev/null 2>&1
if [ -e "$CONTROL_FIXTURE" ] || [ -L "$CONTROL_FIXTURE" ]; then
  echo "FAIL: confirmed-closed control candidate was not removed"
  fail=1
else
  echo "PASS: confirmed-closed control candidate was removed"
fi

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "Captured mac-reclaim --deep --dry-run output:"
  echo "$OUT"
  exit 1
fi

echo ""
echo "All workspaceStorage safety assertions passed."
