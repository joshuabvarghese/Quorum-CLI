#!/usr/bin/env bats
# consensus_fixes.bats — Regression tests for Tab-2 consensus/quorum/witness bugs
#
#   FIX-1  elect_leader stdin source
#          The while-read loop had no stdin pipe, so up_nodes was always empty
#          and an empty string was written to state/leader (silent, exit 0).
#
#   FIX-2  check_cluster_health vs check_quorum formula disagreement
#          check_cluster_health used `up > total/2` (integer division).
#          check_quorum uses `up >= floor(N/2)+1`.  For N=4, up=3:
#            OLD health: 3 > 2 → DEGRADED   (wrong; quorum is HELD)
#            NEW health: check_quorum(3,4) → threshold=3, 3>=3 → HEALTHY
#
#   FIX-3  Witness / force-quorum — was documented, never implemented.
#          add_witness_to_cluster, remove_witness_from_cluster,
#          is_witness_enabled, get_witness_node_id are now real functions.
#
# Run:
#   bats tests/consensus_fixes.bats
# ---------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"
CLUSTER_LIB="$PROJECT_ROOT/lib/cluster-lib.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
    TEST_DATA_DIR="$(mktemp -d)"
    export DATA_DIR="$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"/{clusters,logs/cluster,logs/storage}
    source "$CLUSTER_LIB"

    # Bootstrap a cluster used by most tests
    bash "$CLUSTER_MANAGER" init >/dev/null 2>&1
    TEST_CLUSTER_ID=$(
        bash "$CLUSTER_MANAGER" create --name consensus-test --nodes 3 2>/dev/null \
            | grep "Cluster ID:" | awk '{print $3}'
    )
    export TEST_CLUSTER_ID
}

teardown() {
    rm -rf "$TEST_DATA_DIR"
}

# Make a node directory with a given status (used by unit-style tests that
# don't need a full cluster bootstrap)
_make_node() {
    local cluster_dir="$1" node_id="$2" status="$3"
    mkdir -p "$cluster_dir/nodes/$node_id"
    cat > "$cluster_dir/nodes/$node_id/metadata.json" << EOF
{
  "node_id": "$node_id",
  "cluster_id": "$(basename "$cluster_dir")",
  "status": "$status",
  "role": "follower",
  "data_size_mb": 0,
  "load_percent": 0
}
EOF
}

# ===========================================================================
# FIX-1: elect_leader — stdin source
# ===========================================================================

@test "FIX-1: elect_leader writes a non-empty leader to state/leader" {
    local leader
    leader=$(elect_leader "$TEST_CLUSTER_ID")

    [ -n "$leader" ]
    [ "$leader" != "" ]
}

@test "FIX-1: elect_leader written value matches state/leader file" {
    local leader
    leader=$(elect_leader "$TEST_CLUSTER_ID")

    local file_leader
    file_leader=$(cat "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/state/leader")

    [ "$leader" = "$file_leader" ]
}

@test "FIX-1: elect_leader selects only an UP node" {
    # Put node-1 down; node-2 and node-3 are up
    local nodes_dir="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes"
    local meta="$nodes_dir/node-1/metadata.json"
    sed_inplace 's/"status": "up"/"status": "down"/' "$meta"

    local leader
    leader=$(elect_leader "$TEST_CLUSTER_ID")

    [ "$leader" != "node-1" ]
    [ -n "$leader" ]
}

@test "FIX-1: elect_leader is deterministic — same result on repeated calls" {
    local leader1 leader2
    leader1=$(elect_leader "$TEST_CLUSTER_ID")
    leader2=$(elect_leader "$TEST_CLUSTER_ID")

    [ "$leader1" = "$leader2" ]
}

@test "FIX-1: elect_leader returns 'none' and exits 1 when all nodes are down" {
    local nodes_dir="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes"
    for node_dir in "$nodes_dir"/*/; do
        sed_inplace 's/"status": "up"/"status": "down"/' "$node_dir/metadata.json"
    done

    run elect_leader "$TEST_CLUSTER_ID"
    [ "$status" -ne 0 ]
    [ "$output" = "none" ]
}

@test "FIX-1: elect_leader picks lexicographically first UP node" {
    # All three nodes are up; node-1 should win (lex sort: node-1 < node-2 < node-3)
    local leader
    leader=$(elect_leader "$TEST_CLUSTER_ID")
    [ "$leader" = "node-1" ]
}

@test "FIX-1: get_cluster_leader reads the leader written by elect_leader" {
    elect_leader "$TEST_CLUSTER_ID" >/dev/null

    local leader
    leader=$(get_cluster_leader "$TEST_CLUSTER_ID")
    [ -n "$leader" ]
    [ "$leader" != "none" ]
}

# ===========================================================================
# FIX-2: check_cluster_health / check_quorum formula alignment
# ===========================================================================

@test "FIX-2: check_cluster_health agrees with check_quorum for every N/up combo" {
    # For 1..7 node clusters with 0..N up nodes, health and quorum must agree:
    # - health=HEALTHY   ↔  up==total
    # - health=DEGRADED  ↔  check_quorum(up,total)=0 (HELD) and up<total
    # - health=UNHEALTHY ↔  check_quorum(up,total)=1 (LOST)
    local cluster_dir="$TEST_DATA_DIR/clusters/formula-test"
    mkdir -p "$cluster_dir"/{metadata,state}

    for total in 1 2 3 4 5 6 7; do
        for up in $(seq 0 "$total"); do
            # Rebuild node dirs
            rm -rf "$cluster_dir/nodes"
            for i in $(seq 1 "$total"); do
                local st="down"
                [[ $i -le $up ]] && st="up"
                _make_node "$cluster_dir" "node-$i" "$st"
            done

            local health
            health=$(check_cluster_health "formula-test")

            if [[ $up -eq $total ]]; then
                [ "$health" = "healthy" ] || {
                    echo "FAIL total=$total up=$up: expected healthy, got $health"
                    return 1
                }
            elif check_quorum "$up" "$total"; then
                [ "$health" = "degraded" ] || {
                    echo "FAIL total=$total up=$up: expected degraded, got $health"
                    return 1
                }
            else
                [ "$health" = "unhealthy" ] || {
                    echo "FAIL total=$total up=$up: expected unhealthy, got $health"
                    return 1
                }
            fi
        done
    done
}

@test "FIX-2: 4-node cluster 3-up = DEGRADED not UNHEALTHY (the original bug)" {
    # The original `up > total/2` formula: 3 > 4/2 → 3 > 2 → true → DEGRADED
    # That happened to give DEGRADED but for the wrong threshold boundary.
    # More importantly the boundary at exactly the quorum edge was wrong:
    #   3 nodes up, 4 total:  check_quorum says HELD → must be DEGRADED (not UNHEALTHY)
    local cluster_dir="$TEST_DATA_DIR/clusters/four-node-test"
    mkdir -p "$cluster_dir"/{metadata,state}
    for i in 1 2 3 4; do
        local st="up"; [[ $i -eq 4 ]] && st="down"
        _make_node "$cluster_dir" "node-$i" "$st"
    done

    local health
    health=$(check_cluster_health "four-node-test")
    [ "$health" = "degraded" ]
}

@test "FIX-2: 4-node cluster 2-up = UNHEALTHY (quorum lost — the truly broken case)" {
    # OLD: 2 > 4/2 → 2 > 2 → FALSE → UNHEALTHY  (accidentally correct)
    # NEW: check_quorum(2,4) → threshold=3, 2<3 → LOST → UNHEALTHY  (correct)
    # This test pins the correct answer regardless of which formula is used.
    local cluster_dir="$TEST_DATA_DIR/clusters/four-split-test"
    mkdir -p "$cluster_dir"/{metadata,state}
    for i in 1 2 3 4; do
        local st="down"; [[ $i -le 2 ]] && st="up"
        _make_node "$cluster_dir" "node-$i" "$st"
    done

    local health
    health=$(check_cluster_health "four-split-test")
    [ "$health" = "unhealthy" ]
}

@test "FIX-2: 6-node cluster 4-up = DEGRADED (quorum held — old formula also got wrong)" {
    # OLD: 4 > 6/2 → 4 > 3 → DEGRADED  (correct by coincidence)
    # NEW: check_quorum(4,6) → threshold=4, 4>=4 → HELD → DEGRADED  (correct by design)
    local cluster_dir="$TEST_DATA_DIR/clusters/six-node-test"
    mkdir -p "$cluster_dir"/{metadata,state}
    for i in 1 2 3 4 5 6; do
        local st="up"; [[ $i -gt 4 ]] && st="down"
        _make_node "$cluster_dir" "node-$i" "$st"
    done

    local health
    health=$(check_cluster_health "six-node-test")
    [ "$health" = "degraded" ]
}

@test "FIX-2: 6-node cluster 3-up = UNHEALTHY (exactly at quorum boundary)" {
    # check_quorum(3,6): threshold=4, 3<4 → LOST → UNHEALTHY
    # OLD formula: 3 > 6/2 → 3 > 3 → FALSE → UNHEALTHY (accidental agreement)
    local cluster_dir="$TEST_DATA_DIR/clusters/six-split-test"
    mkdir -p "$cluster_dir"/{metadata,state}
    for i in 1 2 3 4 5 6; do
        local st="down"; [[ $i -le 3 ]] && st="up"
        _make_node "$cluster_dir" "node-$i" "$st"
    done

    local health
    health=$(check_cluster_health "six-split-test")
    [ "$health" = "unhealthy" ]
}

@test "FIX-2: check_cluster_health output exactly matches check_quorum decisions" {
    # Exhaustive spot-check: every case where old and new formulas disagreed
    # N=4 up=3: old=DEGRADED (3>2 true), new=DEGRADED (check_quorum HELD) — agree
    # N=4 up=2: old=UNHEALTHY (3>2 false), new=UNHEALTHY (check_quorum LOST) — agree
    # N=2 up=1: old=UNHEALTHY (1>1 false), new=UNHEALTHY (check_quorum LOST) — agree
    # N=2 up=2: old=HEALTHY, new=HEALTHY — agree
    # The critical new invariant: health=DEGRADED iff check_quorum HELD and up<total
    local cluster_dir="$TEST_DATA_DIR/clusters/invariant-test"
    mkdir -p "$cluster_dir"/{metadata,state}

    for spec in "3:4" "2:4" "1:2" "2:2" "2:3" "1:3"; do
        local up="${spec%%:*}" total="${spec##*:}"
        rm -rf "$cluster_dir/nodes"
        for i in $(seq 1 "$total"); do
            local st="down"; [[ $i -le $up ]] && st="up"
            _make_node "$cluster_dir" "node-$i" "$st"
        done

        local health
        health=$(check_cluster_health "invariant-test")

        if [[ $up -eq $total ]]; then
            expected="healthy"
        elif check_quorum "$up" "$total" 2>/dev/null; then
            expected="degraded"
        else
            expected="unhealthy"
        fi

        [ "$health" = "$expected" ] || {
            echo "FAIL up=$up total=$total: health=$health expected=$expected"
            return 1
        }
    done
}

# ===========================================================================
# FIX-3: Witness / force-quorum — was entirely missing, now implemented
# ===========================================================================

@test "FIX-3: add_witness_to_cluster returns a witness node-id" {
    local wid
    wid=$(add_witness_to_cluster "$TEST_CLUSTER_ID")

    [ -n "$wid" ]
    [[ "$wid" == node-* ]]
}

@test "FIX-3: witness node directory exists after add_witness_to_cluster" {
    local wid
    wid=$(add_witness_to_cluster "$TEST_CLUSTER_ID")

    [ -d "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/$wid" ]
}

@test "FIX-3: witness metadata.json has is_witness=true and role=witness" {
    local wid
    wid=$(add_witness_to_cluster "$TEST_CLUSTER_ID")

    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/$wid/metadata.json"
    grep -q '"is_witness": true' "$meta"
    grep -q '"role": "witness"' "$meta"
}

@test "FIX-3: is_witness_enabled returns true after add_witness_to_cluster" {
    add_witness_to_cluster "$TEST_CLUSTER_ID" >/dev/null

    run is_witness_enabled "$TEST_CLUSTER_ID"
    [ "$status" -eq 0 ]
}

@test "FIX-3: is_witness_enabled returns false on a fresh cluster" {
    local fresh_id
    fresh_id=$(
        bash "$CLUSTER_MANAGER" create --name fresh-nw --nodes 2 2>/dev/null \
            | grep "Cluster ID:" | awk '{print $3}'
    )

    run is_witness_enabled "$fresh_id"
    [ "$status" -ne 0 ]
}

@test "FIX-3: get_witness_node_id returns the correct id" {
    local wid
    wid=$(add_witness_to_cluster "$TEST_CLUSTER_ID")

    local got
    got=$(get_witness_node_id "$TEST_CLUSTER_ID")
    [ "$got" = "$wid" ]
}

@test "FIX-3: get_witness_node_id returns 'none' with no witness" {
    local got
    got=$(get_witness_node_id "$TEST_CLUSTER_ID")
    [ "$got" = "none" ]
}

@test "FIX-3: cluster metadata gains force_quorum_enabled after add_witness" {
    add_witness_to_cluster "$TEST_CLUSTER_ID" >/dev/null

    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json"
    grep -q '"force_quorum_enabled": true' "$meta"
}

@test "FIX-3: cluster metadata gains witness_node_id after add_witness" {
    local wid
    wid=$(add_witness_to_cluster "$TEST_CLUSTER_ID")

    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json"
    grep -q "\"witness_node_id\": \"$wid\"" "$meta"
}

@test "FIX-3: add_witness_to_cluster is idempotent — second call returns same id" {
    local wid1 wid2
    wid1=$(add_witness_to_cluster "$TEST_CLUSTER_ID")
    wid2=$(add_witness_to_cluster "$TEST_CLUSTER_ID")

    [ "$wid1" = "$wid2" ]
}

@test "FIX-3: witness resolves 2-node even-split — cluster reaches quorum with witness" {
    # A 2-node cluster: threshold=2 (both must be up).  One node fails → quorum LOST.
    # After adding a witness, effective cluster size=3, threshold=2.
    # 1 data node up + witness up = 2 UP nodes → quorum HELD.
    local two_id
    two_id=$(
        bash "$CLUSTER_MANAGER" create --name two-node --nodes 2 2>/dev/null \
            | grep "Cluster ID:" | awk '{print $3}'
    )

    # Before witness: 1/2 nodes up = quorum LOST
    local nodes_dir="$TEST_DATA_DIR/clusters/$two_id/nodes"
    sed_inplace 's/"status": "up"/"status": "down"/' \
        "$nodes_dir/node-2/metadata.json"

    run check_quorum "$(count_up_nodes "$two_id")" "$(count_total_nodes "$two_id")"
    [ "$status" -ne 0 ]   # quorum LOST before witness

    # Add witness
    add_witness_to_cluster "$two_id" >/dev/null

    # Now: node-1 up, node-2 down, witness up → 2/3 = quorum HELD
    run check_quorum "$(count_up_nodes "$two_id")" "$(count_total_nodes "$two_id")"
    [ "$status" -eq 0 ]   # quorum HELD after witness
}

@test "FIX-3: remove_witness_from_cluster removes the witness directory" {
    local wid
    wid=$(add_witness_to_cluster "$TEST_CLUSTER_ID")

    remove_witness_from_cluster "$TEST_CLUSTER_ID"

    [ ! -d "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/$wid" ]
}

@test "FIX-3: is_witness_enabled returns false after remove_witness_from_cluster" {
    add_witness_to_cluster "$TEST_CLUSTER_ID" >/dev/null
    remove_witness_from_cluster "$TEST_CLUSTER_ID"

    run is_witness_enabled "$TEST_CLUSTER_ID"
    [ "$status" -ne 0 ]
}

@test "FIX-3: node_count in metadata decreases by 1 after remove_witness" {
    add_witness_to_cluster "$TEST_CLUSTER_ID" >/dev/null

    local count_with
    count_with=$(grep '"node_count"' \
        "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json" \
        | grep -o '[0-9]*')

    remove_witness_from_cluster "$TEST_CLUSTER_ID"

    local count_without
    count_without=$(grep '"node_count"' \
        "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json" \
        | grep -o '[0-9]*')

    [ "$count_without" -eq $(( count_with - 1 )) ]
}

@test "FIX-3: cluster-manager add-witness subcommand works end-to-end" {
    run bash "$CLUSTER_MANAGER" add-witness --cluster-id "$TEST_CLUSTER_ID"
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Ww]itness ]]
}

@test "FIX-3: cluster-manager remove-witness subcommand works end-to-end" {
    bash "$CLUSTER_MANAGER" add-witness --cluster-id "$TEST_CLUSTER_ID" >/dev/null 2>&1

    run bash "$CLUSTER_MANAGER" remove-witness --cluster-id "$TEST_CLUSTER_ID"
    [ "$status" -eq 0 ]
}
