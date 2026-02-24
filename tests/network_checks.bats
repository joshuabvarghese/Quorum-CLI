#!/usr/bin/env bats
# network_checks.bats — Unit tests for lib/network_checks.sh
#
# These tests mock the network so they run offline with no real hosts.
#
# Run:  ./tests/bats-vendor/bin/bats tests/network_checks.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    source "$PROJECT_ROOT/lib/network_checks.sh"

    # Create a mock `nc` that we can control per-test.
    # Tests override NC_MOCK_EXIT to simulate reachable (0) or unreachable (1).
    export NC_MOCK_EXIT=1   # default: unreachable
    export MOCK_BIN
    MOCK_BIN=$(mktemp -d)
    cat > "$MOCK_BIN/nc" <<'MOCK'
#!/bin/sh
exit "${NC_MOCK_EXIT:-1}"
MOCK
    chmod +x "$MOCK_BIN/nc"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    rm -rf "$MOCK_BIN"
}

# ---------------------------------------------------------------------------
# check_ssh_reachable
# ---------------------------------------------------------------------------

@test "check_ssh_reachable: returns 0 when nc succeeds" {
    export NC_MOCK_EXIT=0
    run check_ssh_reachable "192.168.1.101"
    [ "$status" -eq 0 ]
}

@test "check_ssh_reachable: returns 1 when nc fails" {
    export NC_MOCK_EXIT=1
    run check_ssh_reachable "192.168.1.101"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_node_port
# ---------------------------------------------------------------------------

@test "check_node_port: returns 0 when port is open" {
    export NC_MOCK_EXIT=0
    run check_node_port "192.168.1.101" 7000
    [ "$status" -eq 0 ]
}

@test "check_node_port: returns 1 when port is closed" {
    export NC_MOCK_EXIT=1
    run check_node_port "192.168.1.101" 7000
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# wait_for_port
# ---------------------------------------------------------------------------

@test "wait_for_port: returns 0 immediately when port is already open" {
    export NC_MOCK_EXIT=0
    run wait_for_port "192.168.1.101" 7000 10
    [ "$status" -eq 0 ]
}

@test "wait_for_port: returns 1 when port never opens within timeout" {
    export NC_MOCK_EXIT=1
    # Use a very short timeout so the test doesn't take long
    run wait_for_port "192.168.1.101" 7000 2
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# pre_flight_checks
# ---------------------------------------------------------------------------

@test "pre_flight_checks: PREFLIGHT OK when all hosts reachable" {
    export NC_MOCK_EXIT=0
    run pre_flight_checks "192.168.1.101" "192.168.1.102" "192.168.1.103"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PREFLIGHT OK" ]]
}

@test "pre_flight_checks: PREFLIGHT FAILED when a host is unreachable" {
    export NC_MOCK_EXIT=1
    run pre_flight_checks "192.168.1.101" "192.168.1.102"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "PREFLIGHT FAILED" ]]
}

@test "pre_flight_checks: output table contains each host" {
    export NC_MOCK_EXIT=0
    run pre_flight_checks "10.0.0.1" "10.0.0.2"
    [[ "$output" =~ "10.0.0.1" ]]
    [[ "$output" =~ "10.0.0.2" ]]
}

@test "pre_flight_checks: shows UNREACHABLE for a host when nc fails" {
    export NC_MOCK_EXIT=1
    run pre_flight_checks "10.0.0.99"
    [[ "$output" =~ "UNREACHABLE" ]]
}
