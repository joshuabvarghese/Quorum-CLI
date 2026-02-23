#!/usr/bin/env bash
# ============================================================================
# storage_ops.bats — Integration tests for storage-ops.sh
# ============================================================================

setup() {
    export BATS_TMPDIR
    BATS_TMPDIR=$(mktemp -d)
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
    export DATA_DIR="$BATS_TMPDIR/data"
    export LOG_FILE="$BATS_TMPDIR/storage.log"
    export JSON_LOG_FILE="$BATS_TMPDIR/storage.json.log"
    mkdir -p "$DATA_DIR/volumes" "$DATA_DIR/snapshots" \
             "$BATS_TMPDIR/logs/storage"
    STORAGE_OPS="$PROJECT_ROOT/bin/storage-ops.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR"
}

# ─── Strict Mode ──────────────────────────────────────────────────────────────

@test "storage-ops: strict mode present" {
    run grep -c "set -euo pipefail" "$STORAGE_OPS"
    assert_success
    assert_equal "$output" "1"
}

# ─── Volume Provisioning ──────────────────────────────────────────────────────

@test "storage-ops provision: creates volume directory" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 100MB --replication 3
    assert_success
    assert_output "Volume ID:"
    # At least one volume directory should exist
    local vol_count
    vol_count=$(ls "$DATA_DIR/volumes" 2>/dev/null | wc -l | tr -d ' ')
    [[ $vol_count -gt 0 ]]
}

@test "storage-ops provision: volume has correct metadata" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 500MB --replication 2 2>&1)
    local vol_id
    vol_id=$(echo "$out" | grep "Volume ID:" | awk '{print $3}')
    run grep "replication_factor" "$DATA_DIR/volumes/$vol_id/metadata/volume.json"
    assert_output "2"
}

@test "storage-ops provision: creates correct number of replica entries" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 1GB --replication 3 2>&1)
    local vol_id
    vol_id=$(echo "$out" | grep "Volume ID:" | awk '{print $3}')
    local replica_count
    replica_count=$(ls "$DATA_DIR/volumes/$vol_id/replicas" | wc -l | tr -d ' ')
    assert_equal "$replica_count" "3"
}

@test "storage-ops provision: requires --cluster-id" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --size 100MB
    assert_failure
    assert_output "required"
}

# ─── Snapshots ───────────────────────────────────────────────────────────────

@test "storage-ops snapshot: creates snapshot from existing volume" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 100MB --replication 1 2>&1)
    local vol_id
    vol_id=$(echo "$out" | grep "Volume ID:" | awk '{print $3}')

    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" snapshot --volume-id "$vol_id" --retention 7d
    assert_success
    assert_output "Snapshot ID:"
}

@test "storage-ops snapshot: snapshot directory exists after creation" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 100MB --replication 1 2>&1)
    local vol_id
    vol_id=$(echo "$out" | grep "Volume ID:" | awk '{print $3}')

    local snap_out
    snap_out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" snapshot --volume-id "$vol_id" 2>&1)
    local snap_id
    snap_id=$(echo "$snap_out" | grep "Snapshot ID:" | awk '{print $3}')
    assert_dir_exists "$DATA_DIR/snapshots/$snap_id"
}

@test "storage-ops snapshot: fails for non-existent volume" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" snapshot --volume-id "vol-does-not-exist"
    assert_failure
    assert_output "not found"
}

# ─── Verify / Integrity ───────────────────────────────────────────────────────

@test "storage-ops verify: reports HEALTHY for a freshly provisioned volume" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 100MB --replication 3 2>&1)
    local vol_id
    vol_id=$(echo "$out" | grep "Volume ID:" | awk '{print $3}')

    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" verify --volume-id "$vol_id"
    assert_success
    assert_output "HEALTHY"
}

@test "storage-ops verify: all replicas show as SYNCED" {
    local out
    out=$(env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 100MB --replication 3 2>&1)
    local vol_id
    vol_id=$(echo "$out" | grep "Volume ID:" | awk '{print $3}')

    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" verify --volume-id "$vol_id"
    assert_output "SYNCED"
}

# ─── Dry Run ─────────────────────────────────────────────────────────────────

@test "storage-ops provision --dry-run: makes no filesystem changes" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" provision --cluster-id cls-001 --size 10GB --dry-run
    assert_success
    assert_output "DRY-RUN"
    local vol_count
    vol_count=$(ls "$DATA_DIR/volumes" 2>/dev/null | wc -l | tr -d ' ')
    assert_equal "$vol_count" "0"
}

# ─── Stats ───────────────────────────────────────────────────────────────────

@test "storage-ops stats: outputs capacity metrics" {
    run env DATA_DIR="$DATA_DIR" LOG_FILE="$LOG_FILE" JSON_LOG_FILE="$JSON_LOG_FILE" \
        bash "$STORAGE_OPS" stats
    assert_success
    assert_output "Total Volumes:"
    assert_output "Total Capacity:"
}
