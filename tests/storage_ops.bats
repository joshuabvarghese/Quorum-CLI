#!/usr/bin/env bats
# storage_ops.bats — Integration tests for bin/storage-ops.sh
#
# Run:  ./tests/bats-vendor/bin/bats tests/storage_ops.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STORAGE_OPS="$PROJECT_ROOT/bin/storage-ops.sh"
CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"

setup() {
    TEST_DATA_DIR="$(mktemp -d)"
    export DATA_DIR="$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"/{clusters,volumes,snapshots,logs/storage,logs/cluster}
    chmod +x "$STORAGE_OPS" "$CLUSTER_MANAGER"

    # Bootstrap a cluster so storage-ops has something to attach to
    bash "$CLUSTER_MANAGER" init 2>/dev/null || true
    TEST_CLUSTER_ID=$(bash "$CLUSTER_MANAGER" \
        create --name storage-test --nodes 3 2>/dev/null \
        | grep "Cluster ID:" | awk '{print $3}')
    export TEST_CLUSTER_ID
}

teardown() {
    rm -rf "$TEST_DATA_DIR"
}

# ---------------------------------------------------------------------------
# Provision
# ---------------------------------------------------------------------------

@test "provision: exits non-zero without --cluster-id" {
    run bash "$STORAGE_OPS" provision --size 10GB
    [ "$status" -ne 0 ]
}

@test "provision: creates a volume with expected fields" {
    run bash "$STORAGE_OPS" provision \
        --cluster-id "$TEST_CLUSTER_ID" --size 10GB --replication 3
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Volume ID:" ]] || [[ "$output" =~ "vol-" ]]
}

@test "provision --dry-run: prints what it would do without creating files" {
    local before
    before=$(find "$TEST_DATA_DIR/volumes" -type f 2>/dev/null | wc -l)

    run bash "$STORAGE_OPS" provision \
        --cluster-id "$TEST_CLUSTER_ID" --size 100GB --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Dd]ry ]] || [[ "$output" =~ "DRY" ]]

    local after
    after=$(find "$TEST_DATA_DIR/volumes" -type f 2>/dev/null | wc -l)
    # No volume files should have been created
    [ "$before" -eq "$after" ]
}

# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

@test "list: exits zero and does not error on empty volume dir" {
    run bash "$STORAGE_OPS" list
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

@test "stats: exits zero and produces output" {
    run bash "$STORAGE_OPS" stats
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

@test "snapshot: exits non-zero when --volume-id is missing" {
    run bash "$STORAGE_OPS" snapshot --retention 7d
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

@test "verify: exits non-zero for unknown volume-id" {
    run bash "$STORAGE_OPS" verify --volume-id vol-does-not-exist
    [ "$status" -ne 0 ]
}
