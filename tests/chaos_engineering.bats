#!/usr/bin/env bats
# chaos_engineering.bats — Tests for scripts/chaos-engineering.sh
#
# Key assertions:
#   - Dry-run mode makes zero filesystem modifications
#   - kill-node actually sets status=down on the target node
#   - auto-recover brings the node back to status=up
#
# Run:  ./tests/bats-vendor/bin/bats tests/chaos_engineering.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHAOS="$PROJECT_ROOT/scripts/chaos-engineering.sh"
CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"

setup() {
    TEST_DATA_DIR="$(mktemp -d)"
    export DATA_DIR="$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"/{clusters,logs/cluster,logs/storage,logs/monitoring}
    chmod +x "$CHAOS" "$CLUSTER_MANAGER"

    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    TEST_CLUSTER_ID=$(bash "$CLUSTER_MANAGER" \
        create --name chaos-test --nodes 3 2>/dev/null \
        | grep "Cluster ID:" | awk '{print $3}')
    export TEST_CLUSTER_ID
}

teardown() {
    rm -rf "$TEST_DATA_DIR"
}

_node_status() {
    local node_id="$1"
    grep -o '"status"[: ]*"[^"]*"' \
        "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/$node_id/metadata.json" \
        | grep -o '"[^"]*"$' | tr -d '"'
}

# ---------------------------------------------------------------------------
# kill-node --dry-run: must NOT modify node metadata
# ---------------------------------------------------------------------------

@test "chaos kill-node --dry-run: does NOT modify node metadata" {
    # Capture node-2 metadata checksum before
    local before_md5
    before_md5=$(md5sum "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/node-2/metadata.json" \
                 | awk '{print $1}')

    run bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-2 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Dd]ry ]] || [[ "$output" =~ "DRY" ]]

    # Metadata must be identical — dry-run must be truly non-destructive
    local after_md5
    after_md5=$(md5sum "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/node-2/metadata.json" \
                | awk '{print $1}')
    [ "$before_md5" = "$after_md5" ]
}

# ---------------------------------------------------------------------------
# kill-node: sets status=down
# ---------------------------------------------------------------------------

@test "chaos kill-node: sets target node status to DOWN" {
    local before_status
    before_status=$(_node_status "node-2")
    [ "$before_status" = "up" ]

    run bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-2
    [ "$status" -eq 0 ]

    local after_status
    after_status=$(_node_status "node-2")
    [ "$after_status" = "down" ]
}

@test "chaos kill-node: only affects the targeted node (node-1 stays up)" {
    bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-2 2>/dev/null

    local node1_status
    node1_status=$(_node_status "node-1")
    [ "$node1_status" = "up" ]
}

# ---------------------------------------------------------------------------
# kill-node --auto-recover: status returns to up
# ---------------------------------------------------------------------------

@test "chaos kill-node --auto-recover: node returns to UP" {
    bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-3 2>/dev/null

    # Confirm it's down first
    [ "$(_node_status node-3)" = "down" ]

    run bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-3 --auto-recover
    [ "$status" -eq 0 ]

    [ "$(_node_status node-3)" = "up" ]
}

# ---------------------------------------------------------------------------
# network-partition (simulated, local state only)
# ---------------------------------------------------------------------------

@test "chaos network-partition --dry-run: no state files modified" {
    local before_count
    before_count=$(find "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID" -type f | wc -l)

    run bash "$CHAOS" network-partition \
        --cluster-id "$TEST_CLUSTER_ID" --partition "1,2" "3" --dry-run
    [ "$status" -eq 0 ]

    local after_count
    after_count=$(find "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID" -type f | wc -l)
    [ "$before_count" -eq "$after_count" ]
}

# ---------------------------------------------------------------------------
# high-load
# ---------------------------------------------------------------------------

@test "chaos high-load: exits zero with valid args" {
    run bash "$CHAOS" high-load \
        --cluster-id "$TEST_CLUSTER_ID" --duration 1
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "chaos kill-node: exits non-zero for missing cluster" {
    run bash "$CHAOS" kill-node \
        --cluster-id does-not-exist --node-id node-1
    [ "$status" -ne 0 ]
}

@test "chaos kill-node: exits non-zero for missing node" {
    run bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-99
    [ "$status" -ne 0 ]
}
