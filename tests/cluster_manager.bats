#!/usr/bin/env bats
# cluster_manager.bats — Integration tests for bin/cluster-manager.sh
#
# Run:  ./tests/bats-vendor/bin/bats tests/cluster_manager.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"

setup() {
    # Each test gets its own isolated DATA_DIR so tests can't interfere
    TEST_DATA_DIR="$(mktemp -d)"
    export DATA_DIR="$TEST_DATA_DIR"

    # cluster-manager.sh derives CLUSTER_DATA_DIR from DATA_DIR via PROJECT_ROOT,
    # so we override the whole env to keep everything in the temp dir.
    mkdir -p "$TEST_DATA_DIR/clusters" "$TEST_DATA_DIR/logs/cluster"
    chmod +x "$CLUSTER_MANAGER"
}

teardown() {
    rm -rf "$TEST_DATA_DIR"
}

# Helper: create a cluster and capture its ID
_create_and_get_id() {
    local name="${1:-test-cluster}"
    local nodes="${2:-3}"
    local output
    output=$(DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" \
                create --name "$name" --nodes "$nodes" 2>/dev/null)
    echo "$output" | grep "Cluster ID:" | awk '{print $3}'
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

@test "init: creates directory structure and default config" {
    run bash "$CLUSTER_MANAGER" init
    [ "$status" -eq 0 ]
    [[ "$output" =~ "initialized" ]]
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

@test "create: exits non-zero when --name is missing" {
    run bash "$CLUSTER_MANAGER" create --nodes 3
    [ "$status" -ne 0 ]
}

@test "create: creates cluster with correct node count" {
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    local cluster_id
    cluster_id=$(_create_and_get_id "ci-cluster" 3)
    [ -n "$cluster_id" ]

    local node_count
    node_count=$(ls "$TEST_DATA_DIR/clusters/$cluster_id/nodes" | wc -l | tr -d ' ')
    [ "$node_count" -eq 3 ]
}

@test "create: cluster metadata JSON is valid (has required fields)" {
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    local cluster_id
    cluster_id=$(_create_and_get_id "meta-test" 3)

    local meta="$TEST_DATA_DIR/clusters/$cluster_id/metadata/cluster.json"
    [ -f "$meta" ]
    grep -q '"cluster_id"' "$meta"
    grep -q '"name"' "$meta"
    grep -q '"node_count"' "$meta"
    grep -q '"status"' "$meta"
}

@test "create: leader state file is created" {
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    local cluster_id
    cluster_id=$(_create_and_get_id "leader-test" 3)

    [ -f "$TEST_DATA_DIR/clusters/$cluster_id/state/leader" ]
    local leader
    leader=$(cat "$TEST_DATA_DIR/clusters/$cluster_id/state/leader")
    [ "$leader" = "node-1" ]
}

@test "create: each node has metadata.json with status=up" {
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    local cluster_id
    cluster_id=$(_create_and_get_id "node-meta-test" 3)

    for node_dir in "$TEST_DATA_DIR/clusters/$cluster_id/nodes"/*/; do
        local meta="$node_dir/metadata.json"
        [ -f "$meta" ]
        local status
        status=$(grep -o '"status"[: ]*"[^"]*"' "$meta" | grep -o '"[^"]*"$' | tr -d '"')
        [ "$status" = "up" ]
    done
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

@test "list: shows 'No clusters found' when data dir is empty" {
    run bash "$CLUSTER_MANAGER" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No clusters found" ]]
}

@test "list: shows created cluster after create" {
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    _create_and_get_id "list-test" 3 >/dev/null

    run bash "$CLUSTER_MANAGER" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "list-test" ]]
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

@test "status: exits non-zero for unknown cluster-id" {
    run bash "$CLUSTER_MANAGER" status --cluster-id does-not-exist
    [ "$status" -ne 0 ]
}

@test "status: exits non-zero when --cluster-id is missing" {
    run bash "$CLUSTER_MANAGER" status
    [ "$status" -ne 0 ]
}

@test "status: shows HEALTHY for a freshly created 3-node cluster" {
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    local cluster_id
    cluster_id=$(_create_and_get_id "status-test" 3)

    run bash "$CLUSTER_MANAGER" status --cluster-id "$cluster_id"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "HEALTHY" ]]
}

# ---------------------------------------------------------------------------
# add-node
# ---------------------------------------------------------------------------

@test "add-node: increases node count by 1" {
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    local cluster_id
    cluster_id=$(_create_and_get_id "scale-test" 3)

    bash "$CLUSTER_MANAGER" add-node --cluster-id "$cluster_id" 2>/dev/null

    local node_count
    node_count=$(ls "$TEST_DATA_DIR/clusters/$cluster_id/nodes" | wc -l | tr -d ' ')
    [ "$node_count" -eq 4 ]
}

@test "add-node: exits non-zero for missing cluster" {
    run bash "$CLUSTER_MANAGER" add-node --cluster-id no-such-cluster
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# check_cluster_health (POST-MORTEM regression: single-line JSON parsing)
# ---------------------------------------------------------------------------

@test "check_cluster_health: correctly reads status from single-line JSON" {
    # This is the regression test from the POST-MORTEM.
    # The old grep|cut pattern extracted the wrong field on single-line JSON.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    export DATA_DIR="$tmp_dir"
    local cluster_id="regression-cls"

    mkdir -p "$tmp_dir/clusters/$cluster_id/nodes/node-1"
    # Single-line JSON — the exact format that broke the old parser
    printf '{"node_id":"node-1","cluster_id":"%s","status":"up","role":"leader"}\n' \
           "$cluster_id" > "$tmp_dir/clusters/$cluster_id/nodes/node-1/metadata.json"

    source "$PROJECT_ROOT/lib/cluster-lib.sh"
    run check_cluster_health "$cluster_id"
    [ "$status" -eq 0 ]
    [ "$output" = "healthy" ]

    rm -rf "$tmp_dir"
}

@test "check_cluster_health: 1 of 3 nodes down = DEGRADED (quorum retained)" {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    export DATA_DIR="$tmp_dir"
    local cluster_id="degraded-cls"

    for i in 1 2 3; do
        mkdir -p "$tmp_dir/clusters/$cluster_id/nodes/node-$i"
        local st="up"
        [[ $i -eq 3 ]] && st="down"
        printf '{"node_id":"node-%s","status":"%s"}\n' "$i" "$st" \
            > "$tmp_dir/clusters/$cluster_id/nodes/node-$i/metadata.json"
    done

    source "$PROJECT_ROOT/lib/cluster-lib.sh"
    run check_cluster_health "$cluster_id"
    [ "$status" -eq 0 ]
    [ "$output" = "degraded" ]

    rm -rf "$tmp_dir"
}

@test "check_cluster_health: 2 of 3 nodes down = UNHEALTHY (quorum lost)" {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    export DATA_DIR="$tmp_dir"
    local cluster_id="unhealthy-cls"

    for i in 1 2 3; do
        mkdir -p "$tmp_dir/clusters/$cluster_id/nodes/node-$i"
        local st="down"
        [[ $i -eq 1 ]] && st="up"
        printf '{"node_id":"node-%s","status":"%s"}\n' "$i" "$st" \
            > "$tmp_dir/clusters/$cluster_id/nodes/node-$i/metadata.json"
    done

    source "$PROJECT_ROOT/lib/cluster-lib.sh"
    run check_cluster_health "$cluster_id"
    [ "$output" = "unhealthy" ]

    rm -rf "$tmp_dir"
}
