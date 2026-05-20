#!/usr/bin/env bats
# safety_fixes.bats — Regression tests for the three Tab-1 safety findings:
#
#   FIX-1  add_node_to_cluster rollback trap
#          If the sed metadata update fails after the directory is created,
#          the directory must be removed so the cluster is never in a
#          split-brain state (directory exists but counter disagrees).
#
#   FIX-2  Global DRY_RUN respected by all destructive primitives
#          --dry-run was previously only checked inside simulate_partition().
#          The run_cmd() wrapper now gates every mutating operation.
#
#   FIX-3  sed_inplace helper — no more fragile `sed -i '' || sed -i`
#          The fallback pattern can silently leave the original file
#          unchanged on some GNU sed builds.  sed_inplace() detects the OS
#          once and dispatches to the correct form, then verifies the edit.
#
# Run:
#   ./tests/bats-vendor/bin/bats tests/safety_fixes.bats
# ---------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"
CHAOS="$PROJECT_ROOT/scripts/chaos-engineering.sh"
CLUSTER_LIB="$PROJECT_ROOT/lib/cluster-lib.sh"

setup() {
    TEST_DATA_DIR="$(mktemp -d)"
    export DATA_DIR="$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"/{clusters,volumes,snapshots,logs/cluster,logs/storage}
    chmod +x "$CLUSTER_MANAGER" "$CHAOS"

    # Bootstrap a real cluster for tests that need one
    bash "$CLUSTER_MANAGER" init >/dev/null 2>&1 || true
    TEST_CLUSTER_ID=$(
        bash "$CLUSTER_MANAGER" create --name safety-test --nodes 3 2>/dev/null \
        | grep "Cluster ID:" | awk '{print $3}'
    )
    export TEST_CLUSTER_ID
}

teardown() {
    rm -rf "$TEST_DATA_DIR"
}

# ===========================================================================
# FIX-1: add_node_to_cluster rollback trap
# ===========================================================================

@test "FIX-1: add-node increments node_count in JSON by exactly 1" {
    local before_count
    before_count=$(grep '"node_count"' \
        "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json" \
        | grep -o '[0-9]*')

    bash "$CLUSTER_MANAGER" add-node --cluster-id "$TEST_CLUSTER_ID" >/dev/null 2>&1

    local after_count
    after_count=$(grep '"node_count"' \
        "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json" \
        | grep -o '[0-9]*')

    [ "$after_count" -eq "$((before_count + 1))" ]
}

@test "FIX-1: filesystem node count matches JSON node_count after add-node" {
    bash "$CLUSTER_MANAGER" add-node --cluster-id "$TEST_CLUSTER_ID" >/dev/null 2>&1

    local fs_count json_count
    fs_count=$(find "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes" \
        -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    json_count=$(grep '"node_count"' \
        "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json" \
        | grep -o '[0-9]*')

    [ "$fs_count" -eq "$json_count" ]
}

@test "FIX-1: filesystem and JSON stay in sync across multiple add-node calls" {
    for _ in 1 2 3; do
        bash "$CLUSTER_MANAGER" add-node --cluster-id "$TEST_CLUSTER_ID" >/dev/null 2>&1
    done

    local fs_count json_count
    fs_count=$(find "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes" \
        -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    json_count=$(grep '"node_count"' \
        "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json" \
        | grep -o '[0-9]*')

    [ "$fs_count" -eq "$json_count" ]
}

@test "FIX-1: rollback removes new node dir when metadata update is sabotaged" {
    # Sabotage: delete the metadata file so sed_inplace cannot find it.
    # The rollback must remove the node directory that was already created,
    # leaving the cluster in its original state (no dangling directory,
    # no counter drift between filesystem and JSON).
    #
    # Note: chmod 444 is unreliable in root-privileged CI containers where
    # permission bits are ignored for the process owner.  Removing the file
    # is a platform-portable way to guarantee sed_inplace returns non-zero.
    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json"
    local nodes_dir="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes"

    local nodes_before
    nodes_before=$(find "$nodes_dir" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')

    # Remove the metadata file to force the sed step to fail
    rm "$meta"

    # add-node must fail (non-zero exit)
    run bash "$CLUSTER_MANAGER" add-node --cluster-id "$TEST_CLUSTER_ID"
    [ "$status" -ne 0 ]

    # Directory count must be unchanged (rollback removed the new node dir)
    local nodes_after
    nodes_after=$(find "$nodes_dir" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    [ "$nodes_before" -eq "$nodes_after" ]
}

# ===========================================================================
# FIX-2: Global DRY_RUN — all destructive chaos ops honour --dry-run
# ===========================================================================

@test "FIX-2: chaos kill-node --dry-run makes zero filesystem changes" {
    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/node-2/metadata.json"
    local before_md5
    before_md5=$(md5sum "$meta" | awk '{print $1}')

    run bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-2 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Dd][Rr][Yy] ]]

    local after_md5
    after_md5=$(md5sum "$meta" | awk '{print $1}')
    [ "$before_md5" = "$after_md5" ]
}

@test "FIX-2: chaos network-partition --dry-run creates no new files" {
    local before_count
    before_count=$(find "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID" -type f | wc -l)

    run bash "$CHAOS" network-partition \
        --cluster-id "$TEST_CLUSTER_ID" --partition "1,2" "3" --dry-run
    [ "$status" -eq 0 ]

    local after_count
    after_count=$(find "$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID" -type f | wc -l)
    [ "$before_count" -eq "$after_count" ]
}

@test "FIX-2: chaos kill-node without --dry-run DOES set status=down" {
    # Confirm the fix did not over-suppress: real invocations still mutate.
    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/node-2/metadata.json"

    run bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-2
    [ "$status" -eq 0 ]

    grep -q '"status": "down"' "$meta"
}

@test "FIX-2: chaos --auto-recover restores node to up after kill" {
    # First put node-3 down manually
    bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-3 >/dev/null 2>&1

    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/nodes/node-3/metadata.json"
    grep -q '"status": "down"' "$meta"

    # Now auto-recover
    run bash "$CHAOS" kill-node \
        --cluster-id "$TEST_CLUSTER_ID" --node-id node-3 --auto-recover
    [ "$status" -eq 0 ]

    grep -q '"status": "up"' "$meta"
}

# ===========================================================================
# FIX-3: sed_inplace helper — portable, verifiable in-place edits
# ===========================================================================

@test "FIX-3: sed_inplace edits the correct file on this OS" {
    source "$CLUSTER_LIB"

    local tmpfile
    tmpfile=$(mktemp)
    echo '{"status": "old_value"}' > "$tmpfile"

    sed_inplace 's/"status": "old_value"/"status": "new_value"/' "$tmpfile"

    grep -q '"status": "new_value"' "$tmpfile"
    rm -f "$tmpfile"
}

@test "FIX-3: sed_inplace does NOT leave a backup file beside the target" {
    source "$CLUSTER_LIB"

    local tmpdir tmpfile
    tmpdir=$(mktemp -d)
    tmpfile="$tmpdir/test.json"
    echo '{"status": "before"}' > "$tmpfile"

    sed_inplace 's/before/after/' "$tmpfile"

    # Only the one file should exist — no '', '~', or '.bak' artefact
    local file_count
    file_count=$(find "$tmpdir" -type f | wc -l | tr -d ' ')
    [ "$file_count" -eq 1 ]

    rm -rf "$tmpdir"
}

@test "FIX-3: sed_inplace returns non-zero for a missing file" {
    source "$CLUSTER_LIB"

    run sed_inplace 's/a/b/' "/tmp/does-not-exist-$(date +%s%N)"
    [ "$status" -ne 0 ]
}

@test "FIX-3: update_cluster_status correctly mutates JSON on disk" {
    # update_cluster_status now uses sed_inplace — verify the whole pipeline
    local meta="$TEST_DATA_DIR/clusters/$TEST_CLUSTER_ID/metadata/cluster.json"

    # The cluster starts as 'healthy' — flip it
    bash "$CLUSTER_MANAGER" status --cluster-id "$TEST_CLUSTER_ID" >/dev/null 2>&1 || true

    grep -q '"status": "healthy"' "$meta"

    # Directly invoke the function via the script (it sources cluster-lib.sh)
    DATA_DIR="$TEST_DATA_DIR" bash -c "
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        source '$PROJECT_ROOT/lib/logger.sh'
        CLUSTER_DATA_DIR='$TEST_DATA_DIR/clusters'
        update_cluster_status '$TEST_CLUSTER_ID' 'degraded'
    " 2>/dev/null || true

    grep -q '"status": "degraded"' "$meta"
}
