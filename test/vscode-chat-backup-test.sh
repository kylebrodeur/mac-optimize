#!/usr/bin/env bash
# Focused fixture for vscode-chat-backup manifest and fingerprint primitives.
# Task 1 only: fingerprint stability, byte-change divergence, golden vector,
# canonical source-path derivation, atomic JSON write mode 0600, interrupted
# recovery, and separate pointer/sidecar schema validation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/vscode-chat-backup"
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"

fail=0

json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"
}

expect_eq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $msg (got='$got' want='$want')"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

expect_ne() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" = "$want" ]; then
    echo "FAIL: $msg (got='$got' unexpectedly equal)"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

# ── golden vector ───────────────────────────────────────────────────────────
WSHASH="0000000000000000000000000000000000000000000000000000000000000000"
WSROOT="$TMP_HOME/Library/Application Support/Code/User/workspaceStorage/$WSHASH"
mkdir -p "$WSROOT"
printf '{"key":"value"}\n' > "$WSROOT/state.vscdb"
printf '{"folder":"file:///tmp"}\n' > "$WSROOT/workspace.json"

GOLDEN="sha256:0a458930869f38088ee31f4793ec15574ffd97632ec94e147d343d3ed122dbeb"
GOT_GOLDEN=$("$CLI" tree-fingerprint "$WSROOT" | json_field fingerprint)
expect_eq "$GOT_GOLDEN" "$GOLDEN" "golden-vector fingerprint matches precomputed value"
expect_eq "$("$CLI" tree-fingerprint "$WSROOT" | json_field regular_file_count)" "2" "golden vector regular_file_count"
expect_eq "$("$CLI" tree-fingerprint "$WSROOT" | json_field regular_bytes)" "41" "golden vector regular_bytes"

# Exact ordered record metadata prevents implementation/test sharing an ordering bug.
RECORDS=$("$CLI" tree-fingerprint "$WSROOT" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["records"], separators=(",", ":")))')
EXPECTED_RECORDS='[{"path":"0000000000000000000000000000000000000000000000000000000000000000/","type":"directory","content_sha256":null},{"path":"0000000000000000000000000000000000000000000000000000000000000000/state.vscdb","type":"file","content_sha256":"cbdea9ab8317fcd1e3b3a8626c735b7dfb3a929eb927b02aeab7e7f67a511d8a"},{"path":"0000000000000000000000000000000000000000000000000000000000000000/workspace.json","type":"file","content_sha256":"9df3d22ac0f6f7b5418a798fb647426145b8660df4f67619767698c403374f41"}]'
expect_eq "$RECORDS" "$EXPECTED_RECORDS" "golden vector ordered records"

# ── identical-tree stability ──────────────────────────────────────────────────
RUN1=$("$CLI" tree-fingerprint "$WSROOT" | json_field fingerprint)
RUN2=$("$CLI" tree-fingerprint "$WSROOT" | json_field fingerprint)
expect_eq "$RUN1" "$RUN2" "identical tree yields identical fingerprint"

# ── byte-change divergence ────────────────────────────────────────────────────
printf '{"key":"value2"}\n' > "$WSROOT/state.vscdb"
MODIFIED=$("$CLI" tree-fingerprint "$WSROOT" | json_field fingerprint)
expect_ne "$MODIFIED" "$RUN1" "single byte change produces divergent fingerprint"

# ── directory vs file sensitivity ───────────────────────────────────────────
# Revert the file and replace it with a directory of the same name; fingerprint
# must change because the record shape changes.
printf '{"key":"value"}\n' > "$WSROOT/state.vscdb"
rm "$WSROOT/state.vscdb"
mkdir "$WSROOT/state.vscdb"
DIR_VERSION=$("$CLI" tree-fingerprint "$WSROOT" | json_field fingerprint)
expect_ne "$DIR_VERSION" "$RUN1" "file replaced by directory changes fingerprint"

# ── canonical source path ───────────────────────────────────────────────────
VALID_HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
VALID_SRC=$("$CLI" canonical-source-path "$VALID_HASH")
expect_eq "$VALID_SRC" "$HOME/Library/Application Support/Code/User/workspaceStorage/$VALID_HASH" "canonical source path derivation"

if "$CLI" canonical-source-path "../etc/passwd" >/dev/null 2>&1; then
  echo "FAIL: canonical_source_path accepted traversal"
  fail=1
else
  echo "PASS: canonical_source_path rejects traversal"
fi

if "$CLI" canonical-source-path "a/b" >/dev/null 2>&1; then
  echo "FAIL: canonical_source_path accepted multi-component path"
  fail=1
else
  echo "PASS: canonical_source_path rejects multi-component path"
fi

if "$CLI" canonical-source-path ".." >/dev/null 2>&1; then
  echo "FAIL: canonical_source_path accepted parent-directory traversal"
  fail=1
else
  echo "PASS: canonical_source_path rejects parent-directory traversal"
fi

if "$CLI" canonical-source-path "a\\b" >/dev/null 2>&1; then
  echo "FAIL: canonical_source_path accepted backslash"
  fail=1
else
  echo "PASS: canonical_source_path rejects backslash"
fi

SHORT_HASH="abc123"
SHORT_SRC=$("$CLI" canonical-source-path "$SHORT_HASH")
expect_eq "$SHORT_SRC" "$HOME/Library/Application Support/Code/User/workspaceStorage/$SHORT_HASH" "canonical source path accepts single-component hex of any length"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── atomic JSON write mode 0600 ─────────────────────────────────────────────
JSON_DIR="$TMP_HOME/json-write"
mkdir -p "$JSON_DIR"
JSON_PATH="$JSON_DIR/manifest.json"
"$CLI" atomic-json-write "$JSON_PATH" '{"$schema":"vscode-chat-backup-manifest-v1","version":1}'
PERM=$(stat -c '%a' "$JSON_PATH" 2>/dev/null || stat -f '%Lp' "$JSON_PATH")
expect_eq "$PERM" "600" "atomic_json_write creates file mode 0600"

# ── interrupted atomic-write recovery ───────────────────────────────────────
# Simulate a crash that leaves a partial temp artifact next to a valid target.
OLD_VALUE='{"$schema":"vscode-chat-backup-manifest-v1","version":1,"workspace_hash":"'"$VALID_HASH"'","original_workspace_path":"/old/project","source_path":"'"$HOME/Library/Application Support/Code/User/workspaceStorage/$VALID_HASH"'","archive_name":"'"$VALID_HASH"'-sha256:deadbeef.tar.gz.bin","tree_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","archive_sha256":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","archive_size_bytes":1234,"regular_file_count":2,"regular_bytes":41,"created_at":"'"$NOW"'"}'
"$CLI" atomic-json-write "$JSON_PATH" "$OLD_VALUE"
OLD_PERM=$(stat -c '%a' "$JSON_PATH" 2>/dev/null || stat -f '%Lp' "$JSON_PATH")
expect_eq "$OLD_PERM" "600" "target manifest initially written mode 0600"
expect_eq "$("$CLI" load-sidecar-manifest "$JSON_PATH" | json_field original_workspace_path)" "/old/project" "target manifest initially parses"

TMP_FILE="$JSON_DIR/.manifest.json.tmp.interrupted"
printf 'partial garbage' > "$TMP_FILE"
chmod 0666 "$TMP_FILE"

# Before any recovery write, the old target must remain intact despite the temp artifact.
RECOVERY_PERM=$(stat -c '%a' "$JSON_PATH" 2>/dev/null || stat -f '%Lp' "$JSON_PATH")
expect_eq "$RECOVERY_PERM" "600" "target mode preserved across crash artifact"
expect_eq "$("$CLI" load-sidecar-manifest "$JSON_PATH" | json_field original_workspace_path)" "/old/project" "target value preserved across crash artifact"

# A new atomic write must succeed and replace the target with mode 0600.
NEW_VALUE='{"$schema":"vscode-chat-backup-manifest-v1","version":1,"workspace_hash":"'"$VALID_HASH"'","original_workspace_path":"/new/project","source_path":"'"$HOME/Library/Application Support/Code/User/workspaceStorage/$VALID_HASH"'","archive_name":"'"$VALID_HASH"'-sha256:cafebabe.tar.gz.bin","tree_fingerprint":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","archive_sha256":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","archive_size_bytes":5678,"regular_file_count":3,"regular_bytes":99,"created_at":"'"$NOW"'"}'
"$CLI" atomic-json-write "$JSON_PATH" "$NEW_VALUE"
NEW_PERM=$(stat -c '%a' "$JSON_PATH" 2>/dev/null || stat -f '%Lp' "$JSON_PATH")
expect_eq "$NEW_PERM" "600" "atomic_json_write recovers with target mode 0600"
expect_eq "$("$CLI" load-sidecar-manifest "$JSON_PATH" | json_field original_workspace_path)" "/new/project" "atomic_json_write replaced target after crash artifact"

# ── separate manifest schema validation ──────────────────────────────────────
IMMUTABLE='{
  "$schema": "vscode-chat-backup-manifest-v1",
  "version": 1,
  "workspace_hash": "'"$VALID_HASH"'",
  "original_workspace_path": "/old/project",
  "source_path": "'"$HOME/Library/Application Support/Code/User/workspaceStorage/$VALID_HASH"'",
  "archive_name": "'"$VALID_HASH"'-sha256:deadbeef.tar.gz.bin",
  "tree_fingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "archive_sha256": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "archive_size_bytes": 1234,
  "regular_file_count": 2,
  "regular_bytes": 41,
  "created_at": "'"$NOW"'"
}'

printf '%s\n' "$IMMUTABLE" > "$JSON_DIR/sidecar.json"
expect_eq "$("$CLI" load-sidecar-manifest "$JSON_DIR/sidecar.json" | json_field version)" "1" "sidecar manifest loads with valid immutable fields"

# Pointer must include lifecycle fields plus immutable fields.
POINTER=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"updated_at":"'"$NOW"'","generation":1,"state":"uploaded","restore":None,"pruned":None,"history":[]}); print(json.dumps(d))')
printf '%s\n' "$POINTER" > "$JSON_DIR/pointer.json"
expect_eq "$("$CLI" load-pointer-manifest "$JSON_DIR/pointer.json" | json_field state)" "uploaded" "pointer manifest loads with lifecycle fields"

# Sidecar must not contain lifecycle fields.
BAD_SIDECAR=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["state"]="uploaded"; print(json.dumps(d))')
printf '%s\n' "$BAD_SIDECAR" > "$JSON_DIR/bad-sidecar.json"
if "$CLI" load-sidecar-manifest "$JSON_DIR/bad-sidecar.json" >/dev/null 2>&1; then
  echo "FAIL: sidecar manifest accepted lifecycle field"
  fail=1
else
  echo "PASS: sidecar manifest rejects lifecycle field"
fi

# Manifest must reject a source_path that is not the canonical workspaceStorage path.
BAD_SOURCE=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["source_path"]="/tmp/evil"; print(json.dumps(d))')
printf '%s\n' "$BAD_SOURCE" > "$JSON_DIR/bad-source.json"
if "$CLI" load-sidecar-manifest "$JSON_DIR/bad-source.json" >/dev/null 2>&1; then
  echo "FAIL: sidecar manifest accepted noncanonical source_path"
  fail=1
else
  echo "PASS: sidecar manifest rejects noncanonical source_path"
fi

# Pointer/sidecar immutable-field mismatch must be rejected.
BAD_POINTER=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["archive_size_bytes"]=9999; d.update({"updated_at":"'"$NOW"'","generation":1,"state":"uploaded","restore":None,"pruned":None,"history":[]}); print(json.dumps(d))')
printf '%s\n' "$BAD_POINTER" > "$JSON_DIR/bad-pointer.json"
if "$CLI" validate-pointer-sidecar "$(cat "$JSON_DIR/bad-pointer.json")" "$(cat "$JSON_DIR/sidecar.json")" >/dev/null 2>&1; then
  echo "FAIL: validate_pointer_sidecar accepted immutable-field mismatch"
  fail=1
else
  echo "PASS: validate_pointer_sidecar rejects immutable-field mismatch"
fi

# Pointer state evidence must be durable: restored without restore object is invalid.
BAD_RESTORED=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"updated_at":"'"$NOW"'","generation":1,"state":"restored","restore":None,"pruned":None,"history":[]}); print(json.dumps(d))')
printf '%s\n' "$BAD_RESTORED" > "$JSON_DIR/bad-restored.json"
if "$CLI" load-pointer-manifest "$JSON_DIR/bad-restored.json" >/dev/null 2>&1; then
  echo "FAIL: pointer manifest accepted state=restored without restore object"
  fail=1
else
  echo "PASS: pointer manifest rejects state=restored without restore object"
fi

# Pruned without pruned object is invalid.
BAD_PRUNED=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"updated_at":"'"$NOW"'","generation":1,"state":"pruned","restore":{"verified_fingerprint":d["tree_fingerprint"],"destination":"/tmp/restore","restored_at":"'"$NOW"'"},"pruned":None,"history":[]}); print(json.dumps(d))')
printf '%s\n' "$BAD_PRUNED" > "$JSON_DIR/bad-pruned.json"
if "$CLI" load-pointer-manifest "$JSON_DIR/bad-pruned.json" >/dev/null 2>&1; then
  echo "FAIL: pointer manifest accepted state=pruned without pruned object"
  fail=1
else
  echo "PASS: pointer manifest rejects state=pruned without pruned object"
fi

# History entries must have valid state and timestamp.
BAD_HISTORY=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"updated_at":"'"$NOW"'","generation":1,"state":"uploaded","restore":None,"pruned":None,"history":[{"state":"bad","at":"'"$NOW"'"}]}); print(json.dumps(d))')
printf '%s\n' "$BAD_HISTORY" > "$JSON_DIR/bad-history.json"
if "$CLI" load-pointer-manifest "$JSON_DIR/bad-history.json" >/dev/null 2>&1; then
  echo "FAIL: pointer manifest accepted invalid history state"
  fail=1
else
  echo "PASS: pointer manifest rejects invalid history state"
fi

# ── reconcile pointer ─────────────────────────────────────────────────────────
P1=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"updated_at":"'"$NOW"'","generation":1,"state":"uploaded","restore":None,"pruned":None,"history":[]}); print(json.dumps(d))')
P2=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"updated_at":"'"$NOW"'","generation":2,"state":"verified","restore":None,"pruned":None,"history":[{"state":"uploaded","at":"'"$NOW"'"}]}); print(json.dumps(d))')
RECON=$("$CLI" reconcile-pointer "$P1" "$P2" | json_field generation)
expect_eq "$RECON" "2" "reconcile_pointer selects higher generation"

if "$CLI" reconcile-pointer "$P1" "$P1" >/dev/null 2>&1; then
  echo "PASS: reconcile_pointer accepts equal content at equal generation"
else
  echo "FAIL: reconcile_pointer rejected equal content at equal generation"
  fail=1
fi

P_CONFLICT=$(printf '%s' "$IMMUTABLE" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"updated_at":"'"$NOW"'","generation":1,"state":"verified","restore":None,"pruned":None,"history":[]}); print(json.dumps(d))')
if "$CLI" reconcile-pointer "$P1" "$P_CONFLICT" >/dev/null 2>&1; then
  echo "FAIL: reconcile_pointer accepted equal-generation unequal content"
  fail=1
else
  echo "PASS: reconcile_pointer rejects equal-generation unequal content as conflict"
fi

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "Focused fixture FAILED."
  exit 1
fi

echo ""
echo "All focused fixture assertions passed."
