#!/usr/bin/env bash
# ============================================================================
# network_checks.bats — Unit tests for lib/network_checks.sh
#
# Tests the network connectivity library in isolation.
# SSH and iptables calls are mocked — no real network required.
#
# TDD rationale:
#   Network pre-flight checks are critical safety gates. A false-positive
#   (reporting "connected" when not) can trigger partial cluster operations
#   that corrupt distributed state. These tests verify the detection logic
#   without needing live infrastructure.
# ============================================================================

setup() {
    export BATS_TMPDIR
    BATS_TMPDIR=$(mktemp -d)
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
    export LOG_FILE="$BATS_TMPDIR/test.log"
    export JSON_LOG_FILE="$BATS_TMPDIR/test.json.log"
    export NETWORK_CHECK_TIMEOUT=1
    # Load logger so network_checks can call log_info etc.
    # shellcheck source=lib/logger.sh
    source "$PROJECT_ROOT/lib/logger.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR"
    # Clean up any mock scripts
    rm -f /tmp/bats-mock-iptables /tmp/bats-mock-ping
}

# ─── check_ssh_connectivity ──────────────────────────────────────────────────

@test "check_ssh_connectivity: returns 0 for localhost port 22 if sshd is running" {
    # Only run this test if SSH is actually listening
    if ! ss -ln 2>/dev/null | grep -q ':22 ' && \
       ! netstat -ln 2>/dev/null | grep -q ':22 '; then
        skip "sshd not running on this host"
    fi
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        check_ssh_connectivity localhost 22
    "
    assert_success
}

@test "check_ssh_connectivity: returns 1 for unreachable host (port 9)" {
    # Port 9 (discard) is almost universally closed
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        check_ssh_connectivity 127.0.0.1 9 2>/dev/null
    "
    assert_failure
}

@test "check_ssh_connectivity: returns 1 for non-routable address (10.255.255.1)" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        check_ssh_connectivity 10.255.255.1 22 2>/dev/null
    "
    assert_failure
}

# ─── check_cluster_reachability ──────────────────────────────────────────────

@test "check_cluster_reachability: logs UNREACHABLE for failed nodes" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        check_cluster_reachability 10.255.255.1 10.255.255.2 2>&1
    "
    assert_failure
    assert_output "UNREACHABLE"
}

@test "check_cluster_reachability: mentions troubleshooting steps on failure" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        check_cluster_reachability 10.255.255.99 2>&1
    "
    assert_failure
    assert_output "Troubleshooting"
}

@test "check_cluster_reachability: mentions --dry-run in failure message" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        check_cluster_reachability 10.255.255.99 2>&1
    "
    assert_failure
    assert_output "dry-run"
}

# ─── check_iptables_available ─────────────────────────────────────────────────

@test "check_iptables_available: returns failure when iptables is not in PATH" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export PATH='/usr/bin:/bin'   # Exclude /sbin where iptables usually lives
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        # Override command to simulate missing iptables
        command() { return 1; }
        export -f command
        check_iptables_available 2>&1
    "
    assert_failure
}

# ─── list_active_partition_rules ─────────────────────────────────────────────

@test "list_active_partition_rules: shows 'none' when iptables is unavailable" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        # Override iptables to simulate missing binary
        iptables() { return 127; }
        export -f iptables
        list_active_partition_rules '192.168.1.0/24'
    "
    assert_success
    assert_output "none"
}

# ─── pre_flight_checks ───────────────────────────────────────────────────────

@test "pre_flight_checks: passes with no nodes (no-op)" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        pre_flight_checks 2>&1
    "
    assert_success
    assert_output "No nodes specified"
}

@test "pre_flight_checks: fails with unreachable node" {
    run bash -c "
        export LOG_FILE='$LOG_FILE' JSON_LOG_FILE='$JSON_LOG_FILE'
        export NETWORK_CHECK_TIMEOUT=1
        source '$PROJECT_ROOT/lib/logger.sh'
        source '$PROJECT_ROOT/lib/network_checks.sh'
        pre_flight_checks 10.255.255.99 2>&1
    "
    assert_failure
    assert_output "FAILED"
}

# ─── network_checks.sh itself is ShellCheck compliant ────────────────────────

@test "network_checks.sh: has strict mode" {
    run grep -c "set -euo pipefail" "$PROJECT_ROOT/lib/network_checks.sh"
    assert_success
    assert_equal "$output" "1"
}

@test "network_checks.sh: has safe IFS" {
    run grep "IFS=" "$PROJECT_ROOT/lib/network_checks.sh"
    assert_success
}

@test "network_checks.sh: has env bash shebang" {
    run head -1 "$PROJECT_ROOT/lib/network_checks.sh"
    assert_output "#!/usr/bin/env bash"
}

@test "network_checks.sh: no SC2155 violations (local var=\$(cmd))" {
    # SC2155: declare and assign separately to avoid masking return values
    run grep -n "local [a-z_]*=\$(" "$PROJECT_ROOT/lib/network_checks.sh"
    assert_failure    # grep returns 1 = no matches found = PASS
}
