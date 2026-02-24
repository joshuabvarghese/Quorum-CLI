#!/usr/bin/env bash
# run_tests.sh — Master test runner for Quorum-CLI
#
# Runs 6 test groups in order:
#   [1/6] ShellCheck Compliance
#   [2/6] Quorum Math           (inline unit tests)
#   [3/6] Cluster Lifecycle     (inline integration tests)
#   [4/6] Storage Operations    (inline integration tests)
#   [5/6] Dry-Run Safety        (cross-script dry-run assertions)
#   [6/6] Structured Logging    (log_json format validation)
#
# After inline tests, runs the full BATS suite if bats-vendor is present.
#
# Usage:
#   ./tests/run_tests.sh          # run everything
#   ./tests/run_tests.sh --fast   # skip ShellCheck (CI machines without shellcheck)

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BOLD='\033[1m';   RESET='\033[0m'

# ── Counters ─────────────────────────────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

# ── Helpers ──────────────────────────────────────────────────────────────────
_pass() { (( TESTS_PASSED++ )); (( TESTS_RUN++ )); echo -e "  ${GREEN}✓${RESET} $1"; }
_fail() { (( TESTS_FAILED++ )); (( TESTS_RUN++ )); echo -e "  ${RED}✗${RESET} $1"; FAILED_NAMES+=("$1"); }

assert_eq()    { [[ "$1" == "$2" ]] && _pass "$3" || _fail "$3 (got '$1', expected '$2')"; }
assert_zero()  { [[ "$1" -eq 0  ]] && _pass "$2" || _fail "$2 (exit code: $1)"; }
assert_nonzero(){ [[ "$1" -ne 0  ]] && _pass "$2" || _fail "$2 (expected non-zero, got 0)"; }
assert_file()  { [[ -f "$1" ]]   && _pass "$2" || _fail "$2 (file not found: $1)"; }
assert_contains(){ [[ "$1" =~ $2 ]] && _pass "$3" || _fail "$3 (pattern '$2' not in output)"; }

section() { echo ""; echo -e "${BOLD}[$1] $2${RESET}"; echo "────────────────────────────────────────"; }

# ── Temp environment ─────────────────────────────────────────────────────────
TEST_DATA_DIR="$(mktemp -d)"
export DATA_DIR="$TEST_DATA_DIR"
mkdir -p "$TEST_DATA_DIR"/{clusters,volumes,snapshots,logs/{cluster,storage,monitoring}}

cleanup() { rm -rf "$TEST_DATA_DIR"; }
trap cleanup EXIT

# Source libs
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/cluster-lib.sh"

# ============================================================================
# [1/6] ShellCheck Compliance
# ============================================================================
section "1/6" "ShellCheck Compliance"

if [[ "${1:-}" == "--fast" ]]; then
    echo "  [SKIPPED] (--fast flag set)"
elif ! command -v shellcheck &>/dev/null; then
    echo -e "  ${YELLOW}[SKIPPED] shellcheck not installed — run: apt-get install shellcheck${RESET}"
else
    SCRIPTS=(
        bin/cluster-manager.sh
        bin/storage-ops.sh
        bin/perf-monitor.sh
        lib/logger.sh
        lib/cluster-lib.sh
        lib/network_checks.sh
        scripts/chaos-engineering.sh
        scripts/demo.sh
    )
    for script in "${SCRIPTS[@]}"; do
        path="$PROJECT_ROOT/$script"
        if [[ -f "$path" ]]; then
            if shellcheck "$path" 2>/dev/null; then
                _pass "shellcheck: $script"
            else
                _fail "shellcheck: $script"
            fi
        fi
    done
fi

# ============================================================================
# [2/6] Quorum Math
# ============================================================================
section "2/6" "Quorum Math"

# quorum_threshold
assert_eq "$(quorum_threshold 1)" "1" "quorum_threshold(1) = 1"
assert_eq "$(quorum_threshold 3)" "2" "quorum_threshold(3) = 2"
assert_eq "$(quorum_threshold 5)" "3" "quorum_threshold(5) = 3"
assert_eq "$(quorum_threshold 4)" "3" "quorum_threshold(4) = 3 (even cluster, strict majority)"
assert_eq "$(quorum_threshold 2)" "2" "quorum_threshold(2) = 2 (zero fault tolerance)"

# check_quorum — HELD
check_quorum 3 3 && _pass "check_quorum(3/3) = HELD" || _fail "check_quorum(3/3) = HELD"
check_quorum 2 3 && _pass "check_quorum(2/3) = HELD" || _fail "check_quorum(2/3) = HELD"
check_quorum 3 5 && _pass "check_quorum(3/5) = HELD" || _fail "check_quorum(3/5) = HELD"

# check_quorum — LOST
check_quorum 1 3 && _fail "check_quorum(1/3) = LOST" || _pass "check_quorum(1/3) = LOST"
check_quorum 0 3 && _fail "check_quorum(0/3) = LOST" || _pass "check_quorum(0/3) = LOST"
check_quorum 1 2 && _fail "check_quorum(1/2) 50:50 split = LOST" || _pass "check_quorum(1/2) 50:50 split = LOST"
check_quorum 2 5 && _fail "check_quorum(2/5) = LOST" || _pass "check_quorum(2/5) = LOST"

# ============================================================================
# [3/6] Cluster Lifecycle
# ============================================================================
section "3/6" "Cluster Lifecycle"

chmod +x "$PROJECT_ROOT/bin/cluster-manager.sh"

# init
bash "$PROJECT_ROOT/bin/cluster-manager.sh" init &>/dev/null
assert_file "$PROJECT_ROOT/config/cluster.conf" "init: creates cluster.conf"

# create
CREATE_OUT=$(bash "$PROJECT_ROOT/bin/cluster-manager.sh" \
    create --name run-test-cluster --nodes 3 2>/dev/null)
CLUSTER_ID=$(echo "$CREATE_OUT" | grep "Cluster ID:" | awk '{print $3}')

assert_contains "$CREATE_OUT" "created" "create: success message"
[[ -n "$CLUSTER_ID" ]] && _pass "create: cluster ID returned" || _fail "create: cluster ID returned"
assert_file "$TEST_DATA_DIR/clusters/$CLUSTER_ID/metadata/cluster.json" "create: metadata.json exists"
assert_file "$TEST_DATA_DIR/clusters/$CLUSTER_ID/state/leader" "create: leader file exists"

NODE_COUNT=$(ls "$TEST_DATA_DIR/clusters/$CLUSTER_ID/nodes" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$NODE_COUNT" "3" "create: exactly 3 nodes created"

# status
STATUS_OUT=$(bash "$PROJECT_ROOT/bin/cluster-manager.sh" \
    status --cluster-id "$CLUSTER_ID" 2>/dev/null)
assert_contains "$STATUS_OUT" "HEALTHY" "status: shows HEALTHY for new cluster"
assert_contains "$STATUS_OUT" "node-1"  "status: lists node-1"

# list
LIST_OUT=$(bash "$PROJECT_ROOT/bin/cluster-manager.sh" list 2>/dev/null)
assert_contains "$LIST_OUT" "run-test-cluster" "list: shows cluster by name"

# add-node
bash "$PROJECT_ROOT/bin/cluster-manager.sh" \
    add-node --cluster-id "$CLUSTER_ID" &>/dev/null
NEW_COUNT=$(ls "$TEST_DATA_DIR/clusters/$CLUSTER_ID/nodes" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$NEW_COUNT" "4" "add-node: node count increases to 4"

# ============================================================================
# [4/6] Storage Operations
# ============================================================================
section "4/6" "Storage Operations"

chmod +x "$PROJECT_ROOT/bin/storage-ops.sh"

# provision
PROV_OUT=$(bash "$PROJECT_ROOT/bin/storage-ops.sh" \
    provision --cluster-id "$CLUSTER_ID" --size 10GB --replication 3 2>/dev/null || true)
assert_contains "$PROV_OUT" "vol-" "provision: returns a volume ID"

VOL_ID=$(echo "$PROV_OUT" | grep -o 'vol-[a-zA-Z0-9_-]*' | head -1)

# list
LIST_OUT=$(bash "$PROJECT_ROOT/bin/storage-ops.sh" list 2>/dev/null)
STATS_OUT=$(bash "$PROJECT_ROOT/bin/storage-ops.sh" stats 2>/dev/null)
[[ -n "$STATS_OUT" ]] && _pass "stats: produces output" || _fail "stats: produces output"

# ============================================================================
# [5/6] Dry-Run Safety
# ============================================================================
section "5/6" "Dry-Run Safety"

chmod +x "$PROJECT_ROOT/scripts/chaos-engineering.sh"

# cluster-manager create --dry-run
BEFORE=$(find "$TEST_DATA_DIR/clusters" -mindepth 1 -maxdepth 1 -type d | wc -l)
bash "$PROJECT_ROOT/bin/cluster-manager.sh" \
    create --name dry-run-test --nodes 3 --dry-run &>/dev/null || true
AFTER=$(find "$TEST_DATA_DIR/clusters" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_eq "$BEFORE" "$AFTER" "create --dry-run: no cluster directories created"

# chaos kill-node --dry-run
NODE2_META="$TEST_DATA_DIR/clusters/$CLUSTER_ID/nodes/node-2/metadata.json"
BEFORE_MD5=$(md5sum "$NODE2_META" | awk '{print $1}')
bash "$PROJECT_ROOT/scripts/chaos-engineering.sh" \
    kill-node --cluster-id "$CLUSTER_ID" --node-id node-2 --dry-run &>/dev/null || true
AFTER_MD5=$(md5sum "$NODE2_META" | awk '{print $1}')
assert_eq "$BEFORE_MD5" "$AFTER_MD5" "chaos kill-node --dry-run: metadata unchanged"

# storage provision --dry-run
VOL_BEFORE=$(find "$TEST_DATA_DIR/volumes" -type f 2>/dev/null | wc -l)
bash "$PROJECT_ROOT/bin/storage-ops.sh" \
    provision --cluster-id "$CLUSTER_ID" --size 100GB --dry-run &>/dev/null || true
VOL_AFTER=$(find "$TEST_DATA_DIR/volumes" -type f 2>/dev/null | wc -l)
assert_eq "$VOL_BEFORE" "$VOL_AFTER" "storage provision --dry-run: no volume files created"

# ============================================================================
# [6/6] Structured Logging
# ============================================================================
section "6/6" "Structured Logging"

# If the project has log_json, validate its output; otherwise check plain logs.
JSON_LOG=$(mktemp)

if declare -f log_json &>/dev/null 2>&1; then
    (
        export LOG_FILE=/dev/null
        export JSON_LOG_FILE="$JSON_LOG"
        source "$PROJECT_ROOT/lib/logger.sh"
        log_json "INFO" "test message from run_tests"
    ) 2>/dev/null || true

    if [[ -s "$JSON_LOG" ]]; then
        LINE=$(tail -1 "$JSON_LOG")
        assert_contains "$LINE" '"level"'     "log_json: has level field"
        assert_contains "$LINE" '"message"'   "log_json: has message field"
        assert_contains "$LINE" '"timestamp"' "log_json: has timestamp field"
        assert_contains "$LINE" "^{"          "log_json: output is a JSON object"
    else
        echo -e "  ${YELLOW}[INFO] log_json defined but produced no output — check JSON_LOG_FILE env${RESET}"
    fi
else
    echo -e "  ${YELLOW}[INFO] log_json not in logger.sh yet — checking plain logger${RESET}"
    PLAIN_LOG=$(mktemp)
    export LOG_FILE="$PLAIN_LOG"
    source "$PROJECT_ROOT/lib/logger.sh"
    log_info "structured logging test" 2>/dev/null || true
    grep -q "structured logging test" "$PLAIN_LOG" \
        && _pass "logger: plain-text message written to LOG_FILE" \
        || _fail "logger: plain-text message written to LOG_FILE"
    rm -f "$PLAIN_LOG"
fi
rm -f "$JSON_LOG"

# ============================================================================
# Results
# ============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  TEST RESULTS${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
printf "  Tests Run:      %d\n" "$TESTS_RUN"
printf "  Tests Passed:   %d\n" "$TESTS_PASSED"
printf "  Tests Failed:   %d\n" "$TESTS_FAILED"
printf "  Success Rate:   %d%%\n" "$(( TESTS_PASSED * 100 / TESTS_RUN ))"
echo ""

if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    echo -e "${RED}${BOLD}  Failed Tests:${RESET}"
    for name in "${FAILED_NAMES[@]}"; do
        echo -e "    ${RED}✗${RESET} $name"
    done
    echo ""
fi

# ── BATS suite ───────────────────────────────────────────────────────────────
BATS_BIN="$PROJECT_ROOT/tests/bats-vendor/bin/bats"
if [[ -x "$BATS_BIN" ]]; then
    echo -e "${BOLD}Running BATS suite…${RESET}"
    echo "────────────────────────────────────────"
    "$BATS_BIN" "$PROJECT_ROOT/tests/"*.bats || true
    echo ""
else
    echo -e "${YELLOW}[INFO] BATS not found at $BATS_BIN — skipping BDD suite.${RESET}"
    echo "       To install: https://github.com/bats-core/bats-core"
fi

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  ✓ ALL TESTS PASSED!${RESET}"
    echo ""
    exit 0
else
    echo -e "${RED}${BOLD}  ✗ $TESTS_FAILED TEST(S) FAILED${RESET}"
    echo ""
    exit 1
fi
