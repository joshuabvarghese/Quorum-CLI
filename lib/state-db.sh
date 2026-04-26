#!/usr/bin/env bash
################################################################################
# state-db.sh — SQLite-backed persistent state layer for Quorum-CLI
#
# WHY SQLite INSTEAD OF FLAT FILES
# ─────────────────────────────────
# Flat JSON files work well for a single writer, but they have three
# production failure modes that come up in interviews:
#
#   1. Non-atomic updates: a crash mid-`sed` leaves corrupt state.
#   2. No reboot durability contract: `cluster_status=healthy` exists
#      only in the filesystem; after a `docker restart` with a tmpfs
#      mount it's gone.
#   3. No consistency: two concurrent `add-node` calls race on node_count.
#
# SQLite solves all three:
#   - Writes are wrapped in BEGIN/COMMIT transactions (atomic).
#   - The .db file survives reboots (persisted on whatever volume hosts DATA_DIR).
#   - SQLite's exclusive write lock serialises concurrent writers.
#
# COMPATIBILITY
# ─────────────
# sqlite3 is present on macOS (system install) and most Linux distros.
# The functions below degrade gracefully when sqlite3 is absent:
# state_db_available() returns 1, callers fall back to JSON files.
#
# SCHEMA
# ──────
# clusters(id TEXT PK, name TEXT UNIQUE, type TEXT, status TEXT,
#           node_count INT, replication_factor INT, created_at TEXT,
#           updated_at TEXT)
#
# nodes(cluster_id TEXT, node_id TEXT, ip TEXT, port INT,
#        role TEXT, status TEXT, started_at TEXT, load_percent INT,
#        data_size_mb INT, PRIMARY KEY (cluster_id, node_id))
#
# events(id INTEGER PK AUTOINCREMENT, cluster_id TEXT, node_id TEXT,
#         event_type TEXT, detail TEXT, ts TEXT)
#   — append-only audit log; never deleted programmatically.
#
# USAGE
# ─────
#   source lib/state-db.sh
#   state_db_init "/path/to/quorum.db"
#   state_db_upsert_cluster "$id" "$name" "$type" "healthy" 3 3
#   state_db_set_node_status "$cluster_id" "node-2" "down"
#   state_db_get_cluster_json "$cluster_id"   # → raw JSON row
################################################################################

# Guard against double-sourcing
[[ -n "${_STATE_DB_SH_SOURCED:-}" ]] && return 0
readonly _STATE_DB_SH_SOURCED=1

# Default DB path — callers override by setting STATE_DB before sourcing,
# or by calling state_db_init explicitly.
STATE_DB="${STATE_DB:-}"

################################################################################
# Availability check
################################################################################

state_db_available() {
    command -v sqlite3 &>/dev/null
}

################################################################################
# Initialisation
################################################################################

# state_db_init <db_path>
# Creates the database file and schema if it does not already exist.
# Idempotent — safe to call on every startup.
state_db_init() {
    local db="${1:-$STATE_DB}"
    [[ -z "$db" ]] && { echo "[state-db] ERROR: db path required" >&2; return 1; }
    STATE_DB="$db"

    if ! state_db_available; then
        echo "[state-db] WARN: sqlite3 not found — state-db layer disabled, using JSON files" >&2
        return 1
    fi

    # WAL mode: readers don't block writers; writers don't block readers.
    sqlite3 "$db" << 'SQL'
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS clusters (
    id                TEXT PRIMARY KEY,
    name              TEXT NOT NULL UNIQUE,
    type              TEXT NOT NULL DEFAULT 'cassandra',
    status            TEXT NOT NULL DEFAULT 'initializing',
    node_count        INTEGER NOT NULL DEFAULT 0,
    replication_factor INTEGER NOT NULL DEFAULT 3,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS nodes (
    cluster_id    TEXT NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
    node_id       TEXT NOT NULL,
    ip            TEXT NOT NULL,
    port          INTEGER NOT NULL,
    role          TEXT NOT NULL DEFAULT 'follower',
    status        TEXT NOT NULL DEFAULT 'up',
    started_at    TEXT NOT NULL,
    load_percent  INTEGER NOT NULL DEFAULT 0,
    data_size_mb  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (cluster_id, node_id)
);

CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    cluster_id  TEXT NOT NULL,
    node_id     TEXT,
    event_type  TEXT NOT NULL,
    detail      TEXT,
    ts          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_events_cluster ON events(cluster_id, ts);
SQL
}

################################################################################
# Cluster operations
################################################################################

# state_db_upsert_cluster <id> <name> <type> <status> <node_count> <repl_factor>
state_db_upsert_cluster() {
    local id="$1" name="$2" type="$3" status="$4" node_count="$5" repl_factor="$6"
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    sqlite3 "$STATE_DB" << SQL
BEGIN;
INSERT INTO clusters (id, name, type, status, node_count, replication_factor, created_at, updated_at)
    VALUES ('$id', '$name', '$type', '$status', $node_count, $repl_factor, '$now', '$now')
ON CONFLICT(id) DO UPDATE SET
    status            = excluded.status,
    node_count        = excluded.node_count,
    updated_at        = excluded.updated_at;

INSERT INTO events (cluster_id, event_type, detail, ts)
    VALUES ('$id', 'CLUSTER_UPSERT', 'status=$status node_count=$node_count', '$now');
COMMIT;
SQL
}

# state_db_set_cluster_status <cluster_id> <status>
state_db_set_cluster_status() {
    local cid="$1" status="$2"
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sqlite3 "$STATE_DB" << SQL
BEGIN;
UPDATE clusters SET status='$status', updated_at='$now' WHERE id='$cid';
INSERT INTO events (cluster_id, event_type, detail, ts)
    VALUES ('$cid', 'CLUSTER_STATUS', 'status=$status', '$now');
COMMIT;
SQL
}

# state_db_increment_node_count <cluster_id> <delta>
state_db_increment_node_count() {
    local cid="$1" delta="$2"
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sqlite3 "$STATE_DB" << SQL
BEGIN;
UPDATE clusters
    SET node_count = node_count + $delta,
        updated_at = '$now'
WHERE id = '$cid';
INSERT INTO events (cluster_id, event_type, detail, ts)
    VALUES ('$cid', 'NODE_COUNT_DELTA', 'delta=$delta', '$now');
COMMIT;
SQL
}

# state_db_get_cluster_json <cluster_id>
# Returns a single-row JSON object or empty string if not found.
state_db_get_cluster_json() {
    local cid="$1"
    sqlite3 -json "$STATE_DB" \
        "SELECT * FROM clusters WHERE id='$cid' LIMIT 1;" \
        2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d[0]) if d else '')" 2>/dev/null || echo ""
}

# state_db_list_clusters_json
# Returns a JSON array of all clusters.
state_db_list_clusters_json() {
    sqlite3 -json "$STATE_DB" "SELECT * FROM clusters ORDER BY created_at;" 2>/dev/null \
        || echo "[]"
}

################################################################################
# Node operations
################################################################################

# state_db_upsert_node <cluster_id> <node_id> <ip> <port> <role> <status>
state_db_upsert_node() {
    local cid="$1" nid="$2" ip="$3" port="$4" role="$5" status="$6"
    local load_pct=$(( RANDOM % 30 + 20 ))
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    sqlite3 "$STATE_DB" << SQL
BEGIN;
INSERT INTO nodes (cluster_id, node_id, ip, port, role, status, started_at, load_percent, data_size_mb)
    VALUES ('$cid', '$nid', '$ip', $port, '$role', '$status', '$now', $load_pct, 0)
ON CONFLICT(cluster_id, node_id) DO UPDATE SET
    status       = excluded.status,
    role         = excluded.role,
    load_percent = excluded.load_percent;

INSERT INTO events (cluster_id, node_id, event_type, detail, ts)
    VALUES ('$cid', '$nid', 'NODE_UPSERT', 'ip=$ip role=$role status=$status', '$now');
COMMIT;
SQL
}

# state_db_set_node_status <cluster_id> <node_id> <status>
state_db_set_node_status() {
    local cid="$1" nid="$2" status="$3"
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sqlite3 "$STATE_DB" << SQL
BEGIN;
UPDATE nodes SET status='$status' WHERE cluster_id='$cid' AND node_id='$nid';
INSERT INTO events (cluster_id, node_id, event_type, detail, ts)
    VALUES ('$cid', '$nid', 'NODE_STATUS', 'status=$status', '$now');
COMMIT;
SQL
}

# state_db_healthy_node_count <cluster_id>
# Prints the count of nodes with status='up'.
state_db_healthy_node_count() {
    local cid="$1"
    sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM nodes WHERE cluster_id='$cid' AND status='up';" 2>/dev/null || echo 0
}

# state_db_get_nodes_json <cluster_id>
# Returns a JSON array of node rows.
state_db_get_nodes_json() {
    local cid="$1"
    sqlite3 -json "$STATE_DB" \
        "SELECT * FROM nodes WHERE cluster_id='$cid' ORDER BY node_id;" 2>/dev/null \
        || echo "[]"
}

################################################################################
# Audit log
################################################################################

# state_db_tail_events <cluster_id> [limit]
# Prints the N most-recent events for a cluster, newest first.
state_db_tail_events() {
    local cid="$1" limit="${2:-20}"
    sqlite3 -column -header "$STATE_DB" << SQL
SELECT ts, node_id, event_type, detail
FROM events
WHERE cluster_id='$cid'
ORDER BY id DESC
LIMIT $limit;
SQL
}

################################################################################
# Migration helper
################################################################################

# state_db_import_from_json_files <cluster_data_dir>
#
# One-shot migration: reads all cluster + node metadata JSON files from the
# flat-file layout and imports them into the SQLite database.  Idempotent —
# existing rows are updated via ON CONFLICT upsert.
#
# Usage:
#   source lib/state-db.sh
#   state_db_init "$PROJECT_ROOT/data/quorum.db"
#   state_db_import_from_json_files "$PROJECT_ROOT/data/clusters"
state_db_import_from_json_files() {
    local clusters_dir="$1"
    [[ -d "$clusters_dir" ]] || { echo "[state-db] ERROR: $clusters_dir not found" >&2; return 1; }

    local imported=0
    for cdir in "$clusters_dir"/*/; do
        [[ -d "$cdir" ]] || continue
        local cmeta="$cdir/metadata/cluster.json"
        [[ -f "$cmeta" ]] || continue

        local id name type status node_count repl_factor
        id=$(grep -o '"cluster_id": "[^"]*"' "$cmeta" | cut -d'"' -f4)
        name=$(grep -o '"name": "[^"]*"' "$cmeta" | cut -d'"' -f4)
        type=$(grep -o '"type": "[^"]*"' "$cmeta" | cut -d'"' -f4)
        status=$(grep -o '"status": "[^"]*"' "$cmeta" | cut -d'"' -f4)
        node_count=$(grep -o '"node_count": [0-9]*' "$cmeta" | awk '{print $2}')
        repl_factor=$(grep -o '"replication_factor": [0-9]*' "$cmeta" | awk '{print $2}')

        state_db_upsert_cluster "$id" "$name" "${type:-cassandra}" \
            "${status:-healthy}" "${node_count:-0}" "${repl_factor:-3}"

        for ndir in "$cdir/nodes"/*/; do
            [[ -d "$ndir" ]] || continue
            local nmeta="$ndir/metadata.json"
            [[ -f "$nmeta" ]] || continue

            local nid nip nport nrole nstatus
            nid=$(grep -o '"node_id": "[^"]*"' "$nmeta" | cut -d'"' -f4)
            nip=$(grep -o '"ip": "[^"]*"' "$nmeta" | cut -d'"' -f4)
            nport=$(grep -o '"port": [0-9]*' "$nmeta" | awk '{print $2}')
            nrole=$(grep -o '"role": "[^"]*"' "$nmeta" | cut -d'"' -f4)
            nstatus=$(grep -o '"status": "[^"]*"' "$nmeta" | cut -d'"' -f4)

            state_db_upsert_node "$id" "$nid" "$nip" "${nport:-7001}" \
                "${nrole:-follower}" "${nstatus:-up}"
        done

        (( imported++ )) || true
    done

    echo "[state-db] Imported $imported cluster(s) from JSON files into $STATE_DB"
}
