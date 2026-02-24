#!/usr/bin/env bats
# quorum_math.bats — Unit tests for quorum_threshold and check_quorum
# These are the "interview proof" tests: they prove the math is correct
# and that even-sized clusters without a witness are dangerous.
#
# Run:  ./tests/bats-vendor/bin/bats tests/quorum_math.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    # Source only the library under test — no side effects
    export DATA_DIR="$PROJECT_ROOT/data"
    source "$PROJECT_ROOT/lib/cluster-lib.sh"
}

# ---------------------------------------------------------------------------
# quorum_threshold — the math
# ---------------------------------------------------------------------------

@test "quorum_threshold: 1-node cluster needs 1 vote" {
    run quorum_threshold 1
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "quorum_threshold: 3-node cluster needs 2 votes" {
    run quorum_threshold 3
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

@test "quorum_threshold: 5-node cluster needs 3 votes" {
    run quorum_threshold 5
    [ "$status" -eq 0 ]
    [ "$output" -eq 3 ]
}

@test "quorum_threshold: even 4-node cluster needs 3 votes (not 2)" {
    # Critical: floor(4/2)+1 = 3, NOT 2
    # A 50/50 split on a 4-node cluster means NEITHER partition has quorum.
    run quorum_threshold 4
    [ "$status" -eq 0 ]
    [ "$output" -eq 3 ]
}

@test "quorum_threshold: 2-node cluster needs 2 votes (both up = no fault tolerance)" {
    run quorum_threshold 2
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

# ---------------------------------------------------------------------------
# check_quorum — pass/fail decisions
# ---------------------------------------------------------------------------

@test "check_quorum: 3/3 nodes up = quorum HELD" {
    run check_quorum 3 3
    [ "$status" -eq 0 ]
}

@test "check_quorum: 2/3 nodes up = quorum HELD (can tolerate 1 failure)" {
    run check_quorum 2 3
    [ "$status" -eq 0 ]
}

@test "check_quorum: 1/3 nodes up = quorum LOST" {
    run check_quorum 1 3
    [ "$status" -eq 1 ]
}

@test "check_quorum: 0/3 nodes up = quorum LOST" {
    run check_quorum 0 3
    [ "$status" -eq 1 ]
}

@test "check_quorum: 3/5 nodes up = quorum HELD" {
    run check_quorum 3 5
    [ "$status" -eq 0 ]
}

@test "check_quorum: 2/5 nodes up = quorum LOST" {
    run check_quorum 2 5
    [ "$status" -eq 1 ]
}

@test "check_quorum: 2-node cluster 50/50 split = quorum LOST (THE DANGEROUS CASE)" {
    # This is why even-sized clusters without a Witness are unsafe.
    # 1 node up, 1 node down: neither partition can achieve floor(2/2)+1 = 2 votes.
    run check_quorum 1 2
    [ "$status" -eq 1 ]
}

@test "check_quorum: 2-node cluster + 1 witness (treated as 3-node) = quorum HELD with 2 votes" {
    # --force-quorum adds a Witness node, making it effectively a 3-node cluster.
    # Now 2/3 = quorum held even when one data node is down.
    run check_quorum 2 3
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Cluster-state integration: count helpers
# ---------------------------------------------------------------------------

@test "count_up_nodes: returns 0 for cluster with all nodes down" {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    export DATA_DIR="$tmp_dir"
    local cluster_id="test-quorum-cls"
    mkdir -p "$tmp_dir/clusters/$cluster_id/nodes/node-1"

    cat > "$tmp_dir/clusters/$cluster_id/nodes/node-1/metadata.json" <<'EOF'
{"node_id":"node-1","status":"down","role":"leader"}
EOF

    run count_up_nodes "$cluster_id"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]

    rm -rf "$tmp_dir"
}

@test "count_up_nodes: returns 2 when 2 of 3 nodes are up" {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    export DATA_DIR="$tmp_dir"
    local cluster_id="test-quorum-cls2"

    for i in 1 2 3; do
        mkdir -p "$tmp_dir/clusters/$cluster_id/nodes/node-$i"
        local st="up"
        [[ $i -eq 3 ]] && st="down"
        cat > "$tmp_dir/clusters/$cluster_id/nodes/node-$i/metadata.json" \
            <<EOF
{"node_id":"node-$i","status":"$st","role":"follower"}
EOF
    done

    run count_up_nodes "$cluster_id"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]

    rm -rf "$tmp_dir"
}
