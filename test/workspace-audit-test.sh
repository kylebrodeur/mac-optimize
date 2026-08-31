#!/usr/bin/env bash
# workspace-audit-test.sh — regression harness for the full workspace Git audit.
# Builds disposable repositories and verifies discovery, risk classification,
# generated-size buckets, private report writes, and worktree-engine delegation.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../bin/workspace-audit"
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX/home"
ROOT="$SANDBOX/workspace"
REPORT="$SANDBOX/reports"
ENGINE_LOG="$SANDBOX/engine.log"
FAKE_ENGINE="$SANDBOX/fake-worktree-audit"
PASS=0; FAIL=0
trap 'rm -rf "$SANDBOX"' EXIT

ok(){ PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

mkdir -p "$ROOT/clean-repo" \
  "$ROOT/dirty-repo/node_modules/nested-repo/.git" \
  "$ROOT/dirty-repo/.venv/nested-venv/.git" \
  "$ROOT/dirty-repo/out/nested-out/.git" \
  "$REPORT"

init_repo(){
  local repo="$1"
  git -C "$repo" init -q
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  printf 'initial\n' > "$repo/README.txt"
  git -C "$repo" add README.txt
  git -C "$repo" commit -qm initial
}

init_repo "$ROOT/clean-repo"
init_repo "$ROOT/dirty-repo"
printf 'changed\n' > "$ROOT/dirty-repo/README.txt"
printf 'untracked\n' > "$ROOT/dirty-repo/notes.txt"
printf 'dependency\n' > "$ROOT/dirty-repo/node_modules/package.txt"
printf '.venv/\nout/\n' > "$ROOT/dirty-repo/.git/info/exclude"
git -C "$ROOT/dirty-repo/node_modules/nested-repo" init -q

cat > "$FAKE_ENGINE" <<'ENGINE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ENGINE_LOG"
printf 'FAKE WORKTREE ENGINE: read-only\n'
ENGINE
chmod +x "$FAKE_ENGINE"
export WORKTREE_AUDIT_BIN="$FAKE_ENGINE"
export FAKE_ENGINE_LOG="$ENGINE_LOG"

if OUT="$($TOOL "$ROOT" --save --output-dir "$REPORT")"; then
  ok "workspace-audit command ran"
else
  no "workspace-audit command ran"
  OUT=""
fi

python3 - "$REPORT" "$ROOT" "$ENGINE_LOG" <<'PY'
import json
import pathlib
import stat
import sys

report_dir = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2]).resolve()
engine_log = pathlib.Path(sys.argv[3])
json_files = list(report_dir.glob("*.json"))
md_files = list(report_dir.glob("*.md"))
if len(json_files) != 1:
    raise SystemExit(f"expected one JSON report, found {len(json_files)}")
if len(md_files) != 1:
    raise SystemExit(f"expected one Markdown report, found {len(md_files)}")
assert stat.S_IMODE(report_dir.stat().st_mode) == 0o700
assert stat.S_IMODE(json_files[0].stat().st_mode) == 0o600
assert stat.S_IMODE(md_files[0].stat().st_mode) == 0o600
report = json.loads(json_files[0].read_text())
assert report["schema_version"] == 1
assert report["root"] == str(root)
assert report["repository_count"] == 2
by_path = {item["path"]: item for item in report["repositories"]}
dirty = by_path[str(root / "dirty-repo")]
clean = by_path[str(root / "clean-repo")]
assert dirty["tracked_changes"] == 1
assert dirty["untracked"] == 3
assert dirty["verdict"] == "BACKUP_NOW"
assert dirty["size_buckets_kb"]["dependencies"] > 0
assert clean["verdict"] == "COLD_ARCHIVE"

assert engine_log.read_text().strip() == str(root)
assert "FAKE WORKTREE ENGINE" in report["worktree_engine"]["output"]
assert "No automatic move/delete/prune" in md_files[0].read_text()
PY
if [ "$?" -eq 0 ]; then ok "report model and privacy output"; else no "report model and privacy output"; fi
mkdir -p "$HOME/.local/bin" "$SANDBOX/fake-bin"
touch "$HOME/.local/bin/workspace-audit"
cat > "$SANDBOX/fake-bin/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
exit 0
LAUNCHCTL
chmod +x "$SANDBOX/fake-bin/launchctl"
if PATH="$SANDBOX/fake-bin:$PATH" HOME="$HOME" bash "$HERE/../uninstall.sh" >/dev/null; then
  if [ ! -e "$HOME/.local/bin/workspace-audit" ]; then
    ok "uninstall removes workspace-audit"
  else
    no "uninstall removes workspace-audit"
  fi
else
  no "uninstall script ran in disposable HOME"
fi

printf '\nworkspace-audit: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
