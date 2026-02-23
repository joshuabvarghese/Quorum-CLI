#!/usr/bin/env bash
# ============================================================================
# cluster_manager.bats — Integration tests for cluster-manager.sh
# ============================================================================

setup() {
    export BATS_TMPDIR
    BATS_TMPDIR=$(mktemp -d)
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
    export DATA_DIR="$BATS_TMPDIR/data"
    export LOG_FILE="$BATS_TMPDIR/cluster.log"
    export JSON_LOG_FILE="$BATS_TMPDIR/cluster.json.log"
    mkdir -p "$DATA_DIR/clusters" "$BATS_TMPDIR/logs/cluster" "$BATS_TMPDIR/config"
    # Provide a minimal cluster.conf
    cat > "$BATS_TMPDIR/config/cluster.conf" << 'EOF'
DEFAULT_CLUSTER_TYPE=cassandra
DEFAULT_REPLICATION_FACTOR=3
DEFAULT_NODE_COUNT=3
BASE_PORT=7000
MAX_NODES_PER_CLUSTER=100
EOF
    CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR"
}

# ─── Strict Mode Compliance ───────────────────────────────────────────────────

@test "cluster-manager: script has strict mode (set -euo pipefail)" {
    run grep -c "set -euo pipefail" "$CLUSTER_MANAGER"
    assert_success
    # Should have exactly one strict-mode line
    assert_equal "$output" "1"
}

@test "cluster-manager: script has safe IFS" {
    run grep -c "IFS=" "$CLUSTER_MANAGER"
    assert_success
}

@test "cluster-manager: script has env bash shebang" {
    run head -1 "$CLUSTER_MANAGER"
    assert_output "#!/usr/bin/env bash"
}

# ─── Initialization ──────────────────────────────────────────────────────────

@test "cluster-manager init: creates required directories" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" init
    assert_success
    assert_dir_exists "$DATA_DIR/clusters"
}

@test "cluster-manager init: creates cluster.conf when missing" {
    local conf="$BATS_TMPDIR/config2/cluster.conf"
    mkdir -p "$(dirname "$conf")"
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        PROJECT_ROOT="$BATS_TMPDIR" bash "$CLUSTER_MANAGER" init
    # Check success message
    assert_output "initialized"
}

# ─── Cluster Creation ─────────────────────────────────────────────────────────

@test "cluster-manager create: creates cluster directory" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name bats-test --nodes 3
    assert_success
    # Extract cluster ID from output
    local cluster_id
    cluster_id=$(echo "$output" | grep "Cluster ID:" | awk '{print $3}')
    assert_dir_exists "$DATA_DIR/clusters/$cluster_id"
}

@test "cluster-manager create: cluster has correct node count" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name count-test --nodes 3 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')
    local node_count
    node_count=$(ls "$DATA_DIR/clusters/$cluster_id/nodes" | wc -l | tr -d ' ')
    assert_equal "$node_count" "3"
}

@test "cluster-manager create: elects a leader" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name leader-test --nodes 3 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')
    assert_file_exists "$DATA_DIR/clusters/$cluster_id/state/leader"
    local leader
    leader=$(cat "$DATA_DIR/clusters/$cluster_id/state/leader")
    assert_equal "$leader" "node-1"
}

@test "cluster-manager create: requires --name flag" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --nodes 3
    assert_failure
    assert_output "name is required"
}

# ─── Force Quorum / Witness ───────────────────────────────────────────────────

@test "cluster-manager create --force-quorum: adds witness for even node count" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name witness-test --nodes 2 --force-quorum 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')
    # Should have 3 nodes total: 2 data + 1 witness
    local node_count
    node_count=$(ls "$DATA_DIR/clusters/$cluster_id/nodes" | wc -l | tr -d ' ')
    assert_equal "$node_count" "3"
    # Witness directory should exist
    assert_dir_exists "$DATA_DIR/clusters/$cluster_id/nodes/witness-3"
}

@test "cluster-manager create --force-quorum: witness metadata marks is_witness=true" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name witness-meta --nodes 2 --force-quorum 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')
    run grep "is_witness" "$DATA_DIR/clusters/$cluster_id/nodes/witness-3/metadata.json"
    assert_output "true"
}

@test "cluster-manager create --force-quorum: not added for odd node count" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name no-witness --nodes 3 --force-quorum 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')
    # Odd cluster should still have exactly 3 nodes (no witness added)
    local node_count
    node_count=$(ls "$DATA_DIR/clusters/$cluster_id/nodes" | wc -l | tr -d ' ')
    assert_equal "$node_count" "3"
}

# ─── Dry Run ─────────────────────────────────────────────────────────────────

@test "cluster-manager --dry-run: does not create any directories" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name dry-test --nodes 3 --dry-run
    assert_success
    assert_output "DRY-RUN"
    # Data directory should still be empty
    local cluster_count
    cluster_count=$(ls "$DATA_DIR/clusters" 2>/dev/null | wc -l | tr -d ' ')
    assert_equal "$cluster_count" "0"
}

@test "cluster-manager --dry-run: prints would-execute messages" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name dry-preview --nodes 2 --dry-run
    assert_output "Would execute"
}

# ─── Status ──────────────────────────────────────────────────────────────────

@test "cluster-manager status: shows HEALTHY for a new cluster" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name status-test --nodes 3 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')

    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" status --cluster-id "$cluster_id"
    assert_success
    assert_output "HEALTHY"
}

@test "cluster-manager status: shows LEADER node" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name leader-show --nodes 3 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')

    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" status --cluster-id "$cluster_id"
    assert_output "LEADER"
}

@test "cluster-manager status: exits 1 for unknown cluster" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" status --cluster-id "cls-does-not-exist"
    assert_failure
    assert_output "not found"
}

# ─── Add Node ────────────────────────────────────────────────────────────────

@test "cluster-manager add-node: increments node count" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" create --name addnode-test --nodes 3 2>&1)
    local cluster_id
    cluster_id=$(echo "$out" | grep "Cluster ID:" | awk '{print $3}')

    env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$CLUSTER_MANAGER" add-node --cluster-id "$cluster_id" > /dev/null 2>&1

    local node_count
    node_count=$(ls "$DATA_DIR/clusters/$cluster_id/nodes" | wc -l | tr -d ' ')
    assert_equal "$node_count" "4"
}
