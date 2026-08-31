#!/usr/bin/env bash
# mac-safemode-test.sh — regression tests for the guided Safe Mode benchmark.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../bin/mac-safemode"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1   [$2]"; fi; }

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX/home"
export MAC_SAFEMODE_STATE_DIR="$SANDBOX/state"
export MAC_SAFEMODE_REPORT_DIR="$SANDBOX/reports"
export MAC_SAFEMODE_DATA_ROOT="$SANDBOX/data"
export MAC_SAFEMODE_SKIP_DU=1
export NO_COLOR=1
mkdir -p "$HOME" "$MAC_SAFEMODE_DATA_ROOT" "$SANDBOX/fake-bin"
trap 'rm -rf "$SANDBOX"' EXIT

cat > "$SANDBOX/fake-bin/system_profiler" <<'EOF'
#!/bin/sh
printf 'Software:\n\n    System Software Overview:\n\n        Boot Mode: %s\n' "${FAKE_BOOT_MODE:-Normal}"
EOF
chmod +x "$SANDBOX/fake-bin/system_profiler"
cat > "$SANDBOX/fake-bin/ps" <<'EOF'
#!/bin/sh
case "$*" in
  *"pid=,comm="*)
    printf '  42 /System/Library/PrivateFrameworks/IntelligencePlatformCompute.framework/Versions/A/XPCServices/IntelligencePlatformComputeService.xpc/Contents/MacOS/IntelligencePlatformComputeService\n'
    printf '  43 /Users/test/.local/bin/omp\n'
    ;;
  *"pid=,args="*)
    printf '  42 /System/Library/PrivateFrameworks/IntelligencePlatformCompute.framework/Versions/A/XPCServices/IntelligencePlatformComputeService.xpc/Contents/MacOS/IntelligencePlatformComputeService\n'
    printf '  43 /Users/test/.local/bin/omp __omp_worker_daemon_broker\n'
    ;;
esac
EOF
chmod +x "$SANDBOX/fake-bin/ps"

export PATH="$SANDBOX/fake-bin:$PATH"

printf 'before\n' > "$HOME/before.txt"

printf '%s\n' '== prepare =='
PREPARE_RC=0
PREPARE="$(FAKE_BOOT_MODE=Normal "$TOOL" prepare 2>&1)" || PREPARE_RC=$?
printf '%s\n' "$PREPARE"
check "prepare exits successfully" "[ $PREPARE_RC -eq 0 ]"
check "prepare prints Safe Mode instructions" "echo \"\$PREPARE\" | grep -q 'Continue in Safe Mode'"
check "prepare detects real OMP process" "echo \"\$PREPARE\" | grep -q 'PID 43.*OMP'"
check "prepare omits raw process arguments" "! echo \"\$PREPARE\" | grep -q '__omp_worker_daemon_broker'"
check "prepare ignores compute process as OMP" "! echo \"\$PREPARE\" | grep -q 'PID 42'"
check "prepare writes active state" "[ -f '$MAC_SAFEMODE_STATE_DIR/active-run.json' ]"
check "prepare writes before benchmark" "[ -f '$MAC_SAFEMODE_STATE_DIR/'*/before.json ]"

printf '%s\n' '== safe-mode capture =='
SAFE_RC=0
SAFE="$(FAKE_BOOT_MODE=Safe "$TOOL" finish 2>&1)" || SAFE_RC=$?
printf '%s\n' "$SAFE"
check "safe-mode finish exits successfully" "[ $SAFE_RC -eq 0 ]"
check "safe-mode finish confirms Safe Mode" "echo \"\$SAFE\" | grep -q 'Safe Mode benchmark saved'"
check "safe-mode state is awaiting normal boot" "python3 -c \"import json,glob; p=glob.glob('$MAC_SAFEMODE_STATE_DIR/active-run.json')[0]; assert json.load(open(p))['phase']=='safe-captured'\""
check "safe-mode benchmark exists" "[ -f '$MAC_SAFEMODE_STATE_DIR/'*/safe-mode.json ]"

printf '%s\n' '== normal comparison =='
NORMAL_RC=0
NORMAL="$(FAKE_BOOT_MODE=Normal "$TOOL" finish 2>&1)" || NORMAL_RC=$?
printf '%s\n' "$NORMAL"
check "normal finish exits successfully" "[ $NORMAL_RC -eq 0 ]"
check "normal finish writes comparison report" "echo \"\$NORMAL\" | grep -q 'comparison report saved'"
check "report contains all phases" "grep -q 'Before.*Safe Mode.*Normal' '$MAC_SAFEMODE_REPORT_DIR/'*.md"
check "active state is cleared" "[ ! -e '$MAC_SAFEMODE_STATE_DIR/active-run.json' ]"

printf '%s\n' '== invalid finish =='
INVALID_RC=0
INVALID="$(FAKE_BOOT_MODE=Normal "$TOOL" finish 2>&1)" || INVALID_RC=$?
check "finish without active run fails" "[ $INVALID_RC -ne 0 ]"
check "invalid finish explains missing run" "echo \"\$INVALID\" | grep -qi 'no active'"

printf '\nmac-safemode: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
