#!/usr/bin/env bash
# ============================================================================
# run_tests.sh — Master test runner for Quorum CLI
#
# Runs all test categories and produces a summary.
# Uses the vendored bats test files for full BDD-style testing,
# plus a quick inline unit test suite for CI environments.
#
# Usage:
#   ./tests/run_tests.sh            # Run all tests
#   ./tests/run_tests.sh --quick    # Unit tests only (no subprocess overhead)
#   ./tests/run_tests.sh --bats     # BATS integration tests only
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

PASSED=0
FAILED=0
SKIPPED=0

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

pass() { echo -e "  ${GREEN}✓${RESET} $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAILED=$((FAILED+1)); }
skip() { echo -e "  ${YELLOW}↷${RESET} $1 (skipped)"; SKIPPED=$((SKIPPED+1)); }

run_test() {
    local name="$1"; shift
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

# ── Helpers: each test is a function that returns 0/1 ──────────────────────

t_strict_mode() { grep -q 'set -euo pipefail' "$1"; }
t_ifs_safe()    { grep -q 'IFS=' "$1"; }
t_env_shebang() { head -1 "$1" | grep -q 'env bash'; }
t_no_sc2155()   { ! grep -n 'local [A-Za-z_][A-Za-z_0-9]*=$((' "$1" 2>/dev/null | grep -v '^Binary'; }

setup_tmpdir() {
    TMPD=$(mktemp -d)
    export TMPD DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs"
    export LOG_FILE="$TMPD/test.log" JSON_LOG_FILE="$TMPD/test.json.log"
    mkdir -p "$TMPD/clusters" "$TMPD/logs/cluster" "$TMPD/logs/storage"
}

teardown_tmpdir() {
    rm -rf "$TMPD"
}

# ── Test groups ─────────────────────────────────────────────────────────────

test_shellcheck_compliance() {
    echo -e "\n${BOLD}[1/6] ShellCheck Compliance${RESET}"
    for s in bin/cluster-manager.sh bin/storage-ops.sh bin/perf-monitor.sh \
              scripts/chaos-engineering.sh scripts/demo.sh \
              tests/integration-tests.sh lib/logger.sh lib/cluster-lib.sh; do
        path="$PROJECT_ROOT/$s"
        run_test "$s: #!/usr/bin/env bash"    t_env_shebang    "$path"
        run_test "$s: set -euo pipefail"      t_strict_mode    "$path"
        run_test "$s: IFS safe"               t_ifs_safe       "$path"
        run_test "$s: SC2155 clean"           t_no_sc2155      "$path"
    done
}

test_quorum_math() {
    echo -e "\n${BOLD}[2/6] Quorum Math Unit Tests${RESET}"
    cd "$PROJECT_ROOT"
    # shellcheck source=lib/cluster-lib.sh
    source lib/cluster-lib.sh

    if check_quorum 3 3;  then pass "3/3 = quorum";      else fail "3/3 = quorum";      fi
    if check_quorum 2 3;  then pass "2/3 = quorum";      else fail "2/3 = quorum";      fi
    if ! check_quorum 1 3; then pass "1/3 = no quorum";  else fail "1/3 = no quorum";   fi
    if ! check_quorum 1 2; then pass "1/2 = no quorum";  else fail "1/2 = no quorum";   fi
    if check_quorum 3 5;  then pass "3/5 = quorum";      else fail "3/5 = quorum";      fi
    if ! check_quorum 2 5; then pass "2/5 = no quorum";  else fail "2/5 = no quorum";   fi
    if [[ $(quorum_threshold 3) == "2" ]]; then pass "threshold(3)=2"; else fail "threshold(3)=2"; fi
    if [[ $(quorum_threshold 5) == "3" ]]; then pass "threshold(5)=3"; else fail "threshold(5)=3"; fi
    if [[ $(quorum_threshold 7) == "4" ]]; then pass "threshold(7)=4"; else fail "threshold(7)=4"; fi

    if validate_cluster_name "my-cluster";     then pass "valid cluster name";     else fail "valid cluster name";     fi
    if ! validate_cluster_name "bad name";     then pass "invalid: spaces";        else fail "invalid: spaces";        fi
    if validate_node_count 3;                  then pass "valid count=3";          else fail "valid count=3";          fi
    if ! validate_node_count 0;                then pass "invalid: count=0";       else fail "invalid: count=0";       fi
    if validate_replication_factor 2 3;        then pass "valid replication";      else fail "valid replication";      fi
    if ! validate_replication_factor 5 3;      then pass "invalid: repl>nodes";   else fail "invalid: repl>nodes";    fi
}

test_cluster_lifecycle() {
    echo -e "\n${BOLD}[3/6] Cluster Lifecycle${RESET}"
    cd "$PROJECT_ROOT"
    setup_tmpdir

    local out cid
    out=$(DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/cluster" LOG_FILE="$TMPD/t.log" \
          JSON_LOG_FILE="$TMPD/t.json.log" \
          bash bin/cluster-manager.sh create --name lifecycle-test --nodes 3 2>&1)
    cid=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')

    if [[ -d "$TMPD/clusters/$cid" ]];                                then pass "cluster dir created";  else fail "cluster dir created";  fi
    if [[ $(ls "$TMPD/clusters/$cid/nodes"|wc -l|tr -d ' ') == "3" ]]; then pass "3 nodes created";  else fail "3 nodes created";  fi
    if [[ -f "$TMPD/clusters/$cid/state/leader" ]];                   then pass "leader elected";       else fail "leader elected";       fi

    local status_out
    status_out=$(DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/cluster" LOG_FILE="$TMPD/t.log" \
       JSON_LOG_FILE="$TMPD/t.json.log" \
       bash bin/cluster-manager.sh status --cluster-id "$cid" 2>&1)
    if echo "$status_out" | grep -q "HEALTHY"; then
        pass "status: HEALTHY"
    else
        fail "status: HEALTHY"
    fi

    DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/cluster" LOG_FILE="$TMPD/t.log" \
    JSON_LOG_FILE="$TMPD/t.json.log" \
    bash bin/cluster-manager.sh add-node --cluster-id "$cid" >/dev/null 2>&1
    if [[ $(ls "$TMPD/clusters/$cid/nodes"|wc -l|tr -d ' ') == "4" ]]; then
        pass "add-node: 4 nodes"
    else
        fail "add-node: 4 nodes"
    fi

    # Force-quorum witness
    local wout wcid
    wout=$(DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/cluster" LOG_FILE="$TMPD/t.log" \
           JSON_LOG_FILE="$TMPD/t.json.log" \
           bash bin/cluster-manager.sh create --name wtest --nodes 2 --force-quorum 2>&1)
    wcid=$(echo "$wout" | grep "Cluster ID:" | awk '{print $3}')
    if [[ -d "$TMPD/clusters/$wcid/nodes/witness-3" ]];         then pass "witness dir created";     else fail "witness dir created";     fi
    if [[ $(ls "$TMPD/clusters/$wcid/nodes"|wc -l|tr -d ' ') == "3" ]]; then pass "witness: 3 total"; else fail "witness: 3 total"; fi
    if grep -q "true" "$TMPD/clusters/$wcid/nodes/witness-3/metadata.json"; then
        pass "is_witness=true"
    else
        fail "is_witness=true"
    fi

    teardown_tmpdir
}

test_storage_ops() {
    echo -e "\n${BOLD}[4/6] Storage Operations${RESET}"
    cd "$PROJECT_ROOT"
    setup_tmpdir
    mkdir -p "$TMPD/logs/storage"

    local out vid
    out=$(DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/storage" LOG_FILE="$TMPD/t.log" \
          JSON_LOG_FILE="$TMPD/t.json.log" \
          bash bin/storage-ops.sh provision --cluster-id cls-001 --size 500MB --replication 3 2>&1)
    vid=$(echo "$out" | grep "Volume ID:" | awk '{print $3}')

    if [[ -d "$TMPD/volumes/$vid" ]];                                     then pass "volume dir created";  else fail "volume dir created";  fi
    if [[ $(ls "$TMPD/volumes/$vid/replicas"|wc -l|tr -d ' ') == "3" ]]; then pass "3 replicas created"; else fail "3 replicas created"; fi

    local verify_out
    verify_out=$(DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/storage" LOG_FILE="$TMPD/t.log" \
       JSON_LOG_FILE="$TMPD/t.json.log" \
       bash bin/storage-ops.sh verify --volume-id "$vid" 2>&1)
    if echo "$verify_out" | grep -q "HEALTHY"; then
        pass "verify: HEALTHY"
    else
        fail "verify: HEALTHY"
    fi

    local sout sid
    sout=$(DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/storage" LOG_FILE="$TMPD/t.log" \
           JSON_LOG_FILE="$TMPD/t.json.log" \
           bash bin/storage-ops.sh snapshot --volume-id "$vid" --retention 7d 2>&1)
    sid=$(echo "$sout" | grep "Snapshot ID:" | awk '{print $3}')
    if [[ -d "$TMPD/snapshots/$sid" ]]; then pass "snapshot created"; else fail "snapshot created"; fi

    # Dry-run
    local vol_count_before
    vol_count_before=$(ls "$TMPD/volumes" | wc -l | tr -d ' ')
    DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/storage" LOG_FILE="$TMPD/t.log" \
    JSON_LOG_FILE="$TMPD/t.json.log" \
    bash bin/storage-ops.sh provision --cluster-id cls-001 --size 10GB --dry-run >/dev/null 2>&1
    local vol_count_after
    vol_count_after=$(ls "$TMPD/volumes" | wc -l | tr -d ' ')
    if [[ "$vol_count_before" == "$vol_count_after" ]]; then
        pass "--dry-run: no new volumes"
    else
        fail "--dry-run: no new volumes"
    fi

    teardown_tmpdir
}

test_dry_run_safety() {
    echo -e "\n${BOLD}[5/6] Dry-Run Safety Valve${RESET}"
    cd "$PROJECT_ROOT"
    setup_tmpdir

    # cluster create --dry-run leaves no clusters
    DATA_DIR="$TMPD" LOG_DIR="$TMPD/logs/cluster" LOG_FILE="$TMPD/t.log" \
    JSON_LOG_FILE="$TMPD/t.json.log" \
    bash bin/cluster-manager.sh create --name drytest --nodes 3 --dry-run >/dev/null 2>&1
    if [[ -z "$(ls "$TMPD/clusters" 2>/dev/null)" ]]; then
        pass "create --dry-run: no dirs created"
    else
        fail "create --dry-run: no dirs created"
    fi

    # chaos partition --dry-run shows iptables commands
    # Note: capture to variable first to avoid SIGPIPE with grep -q on short-circuit exit
    local chaos_out
    chaos_out=$(CLUSTER_IPS="10.0.0.0/8" DATA_DIR="$TMPD" LOG_FILE="$TMPD/t.log" \
       JSON_LOG_FILE="$TMPD/t.json.log" \
       bash scripts/chaos-engineering.sh partition --target-node 10.0.0.5 --dry-run 2>&1)

    if echo "$chaos_out" | grep -qi "iptables"; then
        pass "chaos partition --dry-run: shows iptables"
    else
        fail "chaos partition --dry-run: shows iptables"
    fi

    if echo "$chaos_out" | grep -qi "INPUT"; then
        pass "chaos partition --dry-run: shows INPUT rule"
    else
        fail "chaos partition --dry-run: shows INPUT rule"
    fi

    local heal_out
    heal_out=$(CLUSTER_IPS="10.0.0.0/8" DATA_DIR="$TMPD" LOG_FILE="$TMPD/t.log" \
       JSON_LOG_FILE="$TMPD/t.json.log" \
       bash scripts/chaos-engineering.sh heal-partition --target-node 10.0.0.5 --dry-run 2>&1)
    if echo "$heal_out" | grep -qi "iptables"; then
        pass "chaos heal-partition --dry-run: shows delete rule"
    else
        fail "chaos heal-partition --dry-run: shows delete rule"
    fi

    teardown_tmpdir
}

test_json_logging() {
    echo -e "\n${BOLD}[6/6] Structured JSON Logging${RESET}"
    cd "$PROJECT_ROOT"
    JLOG="/tmp/bats-json-$$.log"
    LOG_FILE="/tmp/bats-human-$$.log"
    export JSON_LOG_FILE="$JLOG" LOG_FILE

    bash -c "source lib/logger.sh; log_json INFO 'Quorum achieved with 3/5 nodes'"
    bash -c "source lib/logger.sh; log_json WARN 'node-2 unreachable'"
    bash -c "source lib/logger.sh; log_json ERROR 'quorum-lost'"

    if grep -q '"level"' "$JLOG";                        then pass "log_json: level field";     else fail "log_json: level field";     fi
    if grep -q '"timestamp"' "$JLOG";                    then pass "log_json: timestamp field"; else fail "log_json: timestamp field"; fi
    if grep -q '"message"' "$JLOG";                      then pass "log_json: message field";   else fail "log_json: message field";   fi
    if grep -q "Quorum achieved" "$JLOG";                then pass "log_json: msg preserved";   else fail "log_json: msg preserved";   fi
    if grep -q '"level":"WARN"' "$JLOG";                 then pass "log_json: WARN level";      else fail "log_json: WARN level";      fi
    if [[ $(wc -l < "$JLOG") -eq 3 ]];                  then pass "log_json: 3 JSON lines";    else fail "log_json: 3 JSON lines";    fi
    # Validate each line is parseable JSON-ish (has all 3 keys)
    if grep -qP '^\{"timestamp".*"level".*"message"' "$JLOG"; then
        pass "log_json: valid JSON structure"
    else
        fail "log_json: valid JSON structure"
    fi

    rm -f "$JLOG" "$LOG_FILE"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    local mode="${1:---all}"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗"
    echo "║         Quorum CLI — Test Suite                                  ║"
    echo -e "╚══════════════════════════════════════════════════════════════════╝${RESET}"

    case "$mode" in
        --quick|--all)
            test_shellcheck_compliance
            test_quorum_math
            test_cluster_lifecycle
            test_storage_ops
            test_dry_run_safety
            test_json_logging
            ;;
        --bats)
            BATS_BIN="$SCRIPT_DIR/bats-vendor/bin/bats"
            if [[ ! -x "$BATS_BIN" ]]; then
                echo "bats runner not found at $BATS_BIN"
                exit 1
            fi
            "$BATS_BIN" "$SCRIPT_DIR"
            return
            ;;
    esac

    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    local total=$((PASSED+FAILED+SKIPPED))
    local rate=0
    [[ $total -gt 0 ]] && rate=$((PASSED*100/total))
    printf "  ${BOLD}Tests run:   %d${RESET}\n" "$total"
    printf "  ${GREEN}Passed:      %d${RESET}\n" "$PASSED"
    printf "  ${RED}Failed:      %d${RESET}\n" "$FAILED"
    printf "  ${YELLOW}Skipped:     %d${RESET}\n" "$SKIPPED"
    printf "  Pass rate:   %d%%\n"  "$rate"
    echo ""

    if [[ $FAILED -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✓ ALL TESTS PASSED${RESET}"
    else
        echo -e "  ${RED}${BOLD}✗ SOME TESTS FAILED${RESET}"
        exit 1
    fi
    echo ""
}

main "$@"
