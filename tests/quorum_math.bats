#!/usr/bin/env bash
# ============================================================================
# quorum_math.bats — Unit tests for quorum math and consensus logic
#
# The "Interview Test": Prove that our quorum calculations are correct by
# mocking node states and asserting the cluster correctly loses/retains quorum.
#
# Why this matters (TDD for SRE):
#   Any script that makes availability decisions based on node counts MUST be
#   tested. A bug in quorum math can cause:
#     - False "healthy" status while a majority of data is unreachable
#     - Unnecessary write lockouts when a minority fails
#     - Split-brain acceptance when a partition is 50/50
# ============================================================================

setup() {
    # Create an isolated temp environment per test
    export BATS_TMPDIR
    BATS_TMPDIR=$(mktemp -d)
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
    export DATA_DIR="$BATS_TMPDIR/data"
    export LOG_DIR="$BATS_TMPDIR/logs"
    export LOG_FILE="$BATS_TMPDIR/test.log"
    export JSON_LOG_FILE="$BATS_TMPDIR/test.json.log"
    mkdir -p "$DATA_DIR/clusters" "$LOG_DIR"
    # shellcheck source=lib/cluster-lib.sh
    source "$PROJECT_ROOT/lib/cluster-lib.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR"
}

# ─── Quorum Math Unit Tests ──────────────────────────────────────────────────

@test "quorum: 3 nodes all up = quorum achieved" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_quorum 3 3 && echo 'QUORUM_OK'
    "
    assert_success
    assert_output "QUORUM_OK"
}

@test "quorum: 2 of 3 nodes up = quorum achieved (strict majority)" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_quorum 2 3 && echo 'QUORUM_OK'
    "
    assert_success
    assert_output "QUORUM_OK"
}

@test "quorum: 1 of 3 nodes up = quorum LOST (minority cannot proceed)" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_quorum 1 3 && echo 'QUORUM_OK' || echo 'QUORUM_LOST'
    "
    assert_output "QUORUM_LOST"
}

@test "quorum: 3 of 5 nodes up = quorum achieved" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_quorum 3 5 && echo 'QUORUM_OK'
    "
    assert_success
    assert_output "QUORUM_OK"
}

@test "quorum: 2 of 5 nodes up = quorum LOST" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_quorum 2 5 && echo 'QUORUM_OK' || echo 'QUORUM_LOST'
    "
    assert_output "QUORUM_LOST"
}

@test "quorum: 2 node cluster 50/50 split = quorum LOST (the dangerous case)" {
    # This is the core test: proves why even-sized clusters without a witness
    # are dangerous. A 50% split should NEVER be treated as quorum.
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_quorum 1 2 && echo 'QUORUM_OK' || echo 'QUORUM_LOST'
    "
    assert_output "QUORUM_LOST"
}

@test "quorum: 2 nodes + 1 witness (force-quorum), 2 of 3 up = quorum achieved" {
    # Proves the --force-quorum / witness tie-breaker works correctly:
    # 2 data nodes + 1 witness = 3 total. If one data node fails, we still
    # have 2/3 = majority.
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_quorum 2 3 && echo 'QUORUM_OK'
    "
    assert_success
    assert_output "QUORUM_OK"
}

@test "quorum_threshold: 3 node cluster needs 2 votes" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        quorum_threshold 3
    "
    assert_success
    assert_output "2"
}

@test "quorum_threshold: 5 node cluster needs 3 votes" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        quorum_threshold 5
    "
    assert_success
    assert_output "3"
}

@test "quorum_threshold: 7 node cluster needs 4 votes" {
    run bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        quorum_threshold 7
    "
    assert_success
    assert_output "4"
}

# ─── Cluster Health Status Tests ─────────────────────────────────────────────

@test "check_cluster_health: all nodes up = HEALTHY" {
    # Mock a 3-node cluster on disk
    local cluster_id="cls-test-health-all"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"
    mkdir -p "$cluster_dir/nodes/node-1" "$cluster_dir/nodes/node-2" "$cluster_dir/nodes/node-3"
    mkdir -p "$cluster_dir/metadata" "$cluster_dir/state"
    for i in 1 2 3; do
        cat > "$cluster_dir/nodes/node-$i/metadata.json" << EOF
{"node_id":"node-$i","status":"up","load_percent":30,"data_size_mb":0}
EOF
    done
    cat > "$cluster_dir/metadata/cluster.json" << 'EOF'
{"cluster_id":"cls-test-health-all","name":"test","replication_factor":3,"node_count":3,"status":"healthy"}
EOF

    run bash -c "
        export DATA_DIR='$DATA_DIR'
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_cluster_health '$cluster_id'
    "
    assert_success
    assert_output "healthy"
}

@test "check_cluster_health: 1 of 3 nodes down = DEGRADED (quorum retained)" {
    local cluster_id="cls-test-health-deg"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"
    mkdir -p "$cluster_dir/nodes/node-1" "$cluster_dir/nodes/node-2" "$cluster_dir/nodes/node-3"
    mkdir -p "$cluster_dir/metadata" "$cluster_dir/state"
    for status in up up down; do
        i=$((${#status} % 3 + 1))
    done
    cat > "$cluster_dir/nodes/node-1/metadata.json" << 'EOF'
{"node_id":"node-1","status":"up","load_percent":35,"data_size_mb":0}
EOF
    cat > "$cluster_dir/nodes/node-2/metadata.json" << 'EOF'
{"node_id":"node-2","status":"up","load_percent":40,"data_size_mb":0}
EOF
    cat > "$cluster_dir/nodes/node-3/metadata.json" << 'EOF'
{"node_id":"node-3","status":"down","load_percent":0,"data_size_mb":0}
EOF
    cat > "$cluster_dir/metadata/cluster.json" << 'EOF'
{"cluster_id":"cls-test-health-deg","name":"test","replication_factor":3,"node_count":3}
EOF

    run bash -c "
        export DATA_DIR='$DATA_DIR'
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_cluster_health '$cluster_id'
    "
    assert_success
    assert_output "degraded"
}

@test "check_cluster_health: 2 of 3 nodes down = UNHEALTHY (quorum lost)" {
    local cluster_id="cls-test-health-sick"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"
    mkdir -p "$cluster_dir/nodes/node-1" "$cluster_dir/nodes/node-2" "$cluster_dir/nodes/node-3"
    mkdir -p "$cluster_dir/metadata" "$cluster_dir/state"
    cat > "$cluster_dir/nodes/node-1/metadata.json" << 'EOF'
{"node_id":"node-1","status":"up","load_percent":90,"data_size_mb":0}
EOF
    cat > "$cluster_dir/nodes/node-2/metadata.json" << 'EOF'
{"node_id":"node-2","status":"down","load_percent":0,"data_size_mb":0}
EOF
    cat > "$cluster_dir/nodes/node-3/metadata.json" << 'EOF'
{"node_id":"node-3","status":"down","load_percent":0,"data_size_mb":0}
EOF
    cat > "$cluster_dir/metadata/cluster.json" << 'EOF'
{"cluster_id":"cls-test-health-sick","name":"test","replication_factor":3,"node_count":3}
EOF

    run bash -c "
        export DATA_DIR='$DATA_DIR'
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_cluster_health '$cluster_id'
    "
    # Should still exit 0 (function completes) but output UNHEALTHY
    assert_output "unhealthy"
}
