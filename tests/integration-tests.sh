#!/bin/bash

################################################################################
# Integration Tests - Test suite for distributed storage platform
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$PROJECT_ROOT/bin"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

################################################################################
# Test Framework
################################################################################

test_passed() {
    ((TESTS_PASSED++))
    echo "$(tput setaf 2)✓ PASS$(tput sgr0): $1"
}

test_failed() {
    ((TESTS_FAILED++))
    echo "$(tput setaf 1)✗ FAIL$(tput sgr0): $1"
}

run_test() {
    ((TESTS_RUN++))
    local test_name="$1"
    shift
    
    echo ""
    echo "$(tput bold)Running: $test_name$(tput sgr0)"
    echo "────────────────────────────────────────────────────────────────"
    
    if "$@"; then
        test_passed "$test_name"
        return 0
    else
        test_failed "$test_name"
        return 1
    fi
}

################################################################################
# Test Cases
################################################################################

test_system_initialization() {
    "$BIN_DIR/cluster-manager.sh" init > /dev/null 2>&1
    
    # Check if directories were created
    [[ -d "$PROJECT_ROOT/data/clusters" ]] && \
    [[ -d "$PROJECT_ROOT/logs/cluster" ]] && \
    [[ -f "$PROJECT_ROOT/config/cluster.conf" ]]
}

test_cluster_creation() {
    local output
    output=$("$BIN_DIR/cluster-manager.sh" create \
        --name test-cluster \
        --nodes 3 \
        --type cassandra \
        --replication-factor 3 2>&1)
    
    # Extract cluster ID
    CLUSTER_ID=$(echo "$output" | grep "Cluster ID:" | awk '{print $3}')
    
    # Verify cluster was created
    [[ -n "$CLUSTER_ID" ]] && [[ -d "$PROJECT_ROOT/data/clusters/$CLUSTER_ID" ]]
}

test_cluster_status() {
    [[ -z "$CLUSTER_ID" ]] && return 1
    
    local output
    output=$("$BIN_DIR/cluster-manager.sh" status --cluster-id "$CLUSTER_ID" 2>&1)
    
    # Check if status shows correct info
    echo "$output" | grep -q "HEALTHY" && \
    echo "$output" | grep -q "node-1" && \
    echo "$output" | grep -q "LEADER"
}

test_node_addition() {
    [[ -z "$CLUSTER_ID" ]] && return 1
    
    "$BIN_DIR/cluster-manager.sh" add-node --cluster-id "$CLUSTER_ID" > /dev/null 2>&1
    
    # Verify node was added
    local node_count
    node_count=$(ls -1 "$PROJECT_ROOT/data/clusters/$CLUSTER_ID/nodes" | wc -l | tr -d ' ')
    
    [[ $node_count -eq 4 ]]
}

test_volume_provisioning() {
    [[ -z "$CLUSTER_ID" ]] && return 1
    
    local output
    output=$("$BIN_DIR/storage-ops.sh" provision \
        --cluster-id "$CLUSTER_ID" \
        --size 100MB \
        --replication 3 2>&1)
    
    # Extract volume ID
    VOLUME_ID=$(echo "$output" | grep "Volume ID:" | awk '{print $3}')
    
    # Verify volume was created
    [[ -n "$VOLUME_ID" ]] && [[ -d "$PROJECT_ROOT/data/volumes/$VOLUME_ID" ]]
}

test_snapshot_creation() {
    [[ -z "$VOLUME_ID" ]] && return 1
    
    local output
    output=$("$BIN_DIR/storage-ops.sh" snapshot \
        --volume-id "$VOLUME_ID" \
        --retention 7d 2>&1)
    
    # Extract snapshot ID
    SNAPSHOT_ID=$(echo "$output" | grep "Snapshot ID:" | awk '{print $3}')
    
    # Verify snapshot was created
    [[ -n "$SNAPSHOT_ID" ]] && [[ -d "$PROJECT_ROOT/data/snapshots/$SNAPSHOT_ID" ]]
}

test_integrity_verification() {
    [[ -z "$VOLUME_ID" ]] && return 1
    
    local output
    output=$("$BIN_DIR/storage-ops.sh" verify --volume-id "$VOLUME_ID" 2>&1)
    
    # Check for healthy status
    echo "$output" | grep -q "HEALTHY"
}

test_storage_stats() {
    local output
    output=$("$BIN_DIR/storage-ops.sh" stats 2>&1)
    
    # Check if stats are displayed
    echo "$output" | grep -q "Total Volumes:" && \
    echo "$output" | grep -q "Total Capacity:"
}

test_performance_report() {
    [[ -z "$CLUSTER_ID" ]] && return 1
    
    local report_file="/tmp/test-report.txt"
    "$BIN_DIR/perf-monitor.sh" report \
        --cluster-id "$CLUSTER_ID" \
        --output "$report_file" > /dev/null 2>&1
    
    # Verify report was created
    [[ -f "$report_file" ]] && grep -q "PERFORMANCE REPORT" "$report_file"
}

test_performance_analysis() {
    [[ -z "$CLUSTER_ID" ]] && return 1
    
    local output
    output=$("$BIN_DIR/perf-monitor.sh" analyze --cluster-id "$CLUSTER_ID" 2>&1)
    
    # Check if analysis includes recommendations
    echo "$output" | grep -q "Performance Analysis:"
}

################################################################################
# Main Test Runner
################################################################################

print_header() {
    echo ""
    echo "$(tput bold)╔════════════════════════════════════════════════════════════════╗$(tput sgr0)"
    echo "$(tput bold)║         INTEGRATION TEST SUITE - Distributed Storage          ║$(tput sgr0)"
    echo "$(tput bold)╚════════════════════════════════════════════════════════════════╝$(tput sgr0)"
    echo ""
}

print_summary() {
    echo ""
    echo "$(tput bold)═══════════════════════════════════════════════════════════════$(tput sgr0)"
    echo "$(tput bold)                       TEST SUMMARY                              $(tput sgr0)"
    echo "$(tput bold)═══════════════════════════════════════════════════════════════$(tput sgr0)"
    echo ""
    
    printf "%-20s %d\n" "Tests Run:" "$TESTS_RUN"
    printf "%-20s $(tput setaf 2)%d$(tput sgr0)\n" "Tests Passed:" "$TESTS_PASSED"
    printf "%-20s $(tput setaf 1)%d$(tput sgr0)\n" "Tests Failed:" "$TESTS_FAILED"
    
    local success_rate=0
    if [[ $TESTS_RUN -gt 0 ]]; then
        success_rate=$((TESTS_PASSED * 100 / TESTS_RUN))
    fi
    printf "%-20s %d%%\n" "Success Rate:" "$success_rate"
    
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "$(tput setaf 2)$(tput bold)ALL TESTS PASSED!$(tput sgr0)"
    else
        echo "$(tput setaf 1)$(tput bold)SOME TESTS FAILED$(tput sgr0)"
    fi
    echo ""
}

main() {
    print_header
    
    echo "Starting integration tests..."
    echo ""
    
    # Run tests
    run_test "System Initialization" test_system_initialization
    run_test "Cluster Creation" test_cluster_creation
    run_test "Cluster Status" test_cluster_status
    run_test "Node Addition" test_node_addition
    run_test "Volume Provisioning" test_volume_provisioning
    run_test "Snapshot Creation" test_snapshot_creation
    run_test "Integrity Verification" test_integrity_verification
    run_test "Storage Statistics" test_storage_stats
    run_test "Performance Report" test_performance_report
    run_test "Performance Analysis" test_performance_analysis
    
    # Print summary
    print_summary
    
    # Exit with appropriate code
    [[ $TESTS_FAILED -eq 0 ]]
}

main "$@"
