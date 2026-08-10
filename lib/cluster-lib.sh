#!/usr/bin/env bash

################################################################################
# Cluster Library - Utility functions for cluster management
################################################################################

# Guard against double-sourcing (readonly constants below would otherwise
# throw "readonly variable" on a second `source` in the same shell — this
# bit several BATS tests that source the library more than once per process)
[[ -n "${_CLUSTER_LIB_SH_SOURCED:-}" ]] && return 0
readonly _CLUSTER_LIB_SH_SOURCED=1

# Cluster state constants
readonly CLUSTER_STATUS_HEALTHY="healthy"
readonly CLUSTER_STATUS_DEGRADED="degraded"
readonly CLUSTER_STATUS_UNHEALTHY="unhealthy"
# shellcheck disable=SC2034
readonly CLUSTER_STATUS_INITIALIZING="initializing"

# Node status constants
readonly NODE_STATUS_UP="up"
readonly NODE_STATUS_DOWN="down"
# shellcheck disable=SC2034
readonly NODE_STATUS_STARTING="starting"
# shellcheck disable=SC2034
readonly NODE_STATUS_STOPPING="stopping"

################################################################################
# Cluster validation functions
################################################################################

validate_cluster_name() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        return 1
    fi
    
    # Check if name contains only alphanumeric, dash, underscore
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 1
    fi
    
    return 0
}

validate_node_count() {
    local count="$1"
    local max_nodes="${2:-100}"
    
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if [[ $count -lt 1 ]] || [[ $count -gt $max_nodes ]]; then
        return 1
    fi
    
    return 0
}

validate_replication_factor() {
    local factor="$1"
    local node_count="$2"
    
    if [[ ! "$factor" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if [[ $factor -lt 1 ]] || [[ $factor -gt $node_count ]]; then
        return 1
    fi
    
    return 0
}

################################################################################
# Quorum math functions
# Quorum = floor(N/2) + 1  (strict majority — same formula as Cassandra/Raft)
################################################################################

# quorum_threshold <total_nodes>
#   Prints the minimum number of UP nodes required for quorum.
#   e.g. quorum_threshold 5  → 3
quorum_threshold() {
    local total="$1"
    echo $(( total / 2 + 1 ))
}

# check_quorum <up_nodes> <total_nodes>
#   Returns 0 if quorum is held (up_nodes >= threshold), 1 if quorum is lost.
check_quorum() {
    local up_nodes="$1"
    local total_nodes="$2"
    local threshold
    threshold=$(quorum_threshold "${total_nodes}")

    if [[ "${up_nodes}" -ge "${threshold}" ]]; then
        return 0   # Quorum HELD
    else
        return 1   # Quorum LOST
    fi
}

# count_up_nodes <cluster_id>
#   Returns the number of nodes currently in status=up.
count_up_nodes() {
    local cluster_id="$1"
    local cluster_dir="${DATA_DIR}/clusters/${cluster_id}"
    local count=0

    for node_dir in "${cluster_dir}/nodes"/*/; do
        [[ -d "$node_dir" ]] || continue
        local status
        status=$(grep -o '"status"[: ]*"[^"]*"' "${node_dir}/metadata.json" \
                 | grep -o '"[^"]*"$' | tr -d '"')
        if [[ "$status" == "up" ]]; then (( count++ )) || true; fi
    done

    echo "$count"
}

# count_total_nodes <cluster_id>
#   Returns the total number of node directories present.
count_total_nodes() {
    local cluster_id="$1"
    local cluster_dir="${DATA_DIR}/clusters/${cluster_id}"
    local count=0

    for node_dir in "${cluster_dir}/nodes"/*/; do
        if [[ -d "$node_dir" ]]; then (( count++ )) || true; fi
    done

    echo "$count"
}

export -f quorum_threshold check_quorum count_up_nodes count_total_nodes

################################################################################
# Cluster health functions
################################################################################

check_cluster_health() {
    local cluster_id="$1"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"

    if [[ ! -d "$cluster_dir" ]]; then
        echo "$CLUSTER_STATUS_UNHEALTHY"
        return 1
    fi

    local up_nodes=0
    local total_nodes=0

    for node_dir in "$cluster_dir/nodes"/*/; do
        [[ -d "$node_dir" ]] || continue
        (( total_nodes++ )) || true

        local status
        status=$(grep -o '"status"[: ]*"[^"]*"' "$node_dir/metadata.json" \
                 | grep -o '"[^"]*"$' | tr -d '"')

        if [[ "$status" == "$NODE_STATUS_UP" ]]; then
            (( up_nodes++ )) || true
        fi
    done

    # BUG FIX: the original used `up_nodes > total_nodes/2` (integer division)
    # which disagrees with check_quorum's `floor(N/2)+1` threshold.
    # Example — 4-node cluster, 3 nodes up:
    #   OLD:  3 > 4/2  →  3 > 2  → DEGRADED   (wrong: quorum is HELD)
    #   NEW:  check_quorum 3 4  → threshold=3, 3>=3  → HEALTHY  (correct)
    #
    # We now delegate to check_quorum so both functions are always consistent.
    # A witness node (if present) is already counted in total_nodes because
    # add_witness_to_cluster creates a real node directory for it.
    if [[ $up_nodes -eq $total_nodes ]]; then
        echo "$CLUSTER_STATUS_HEALTHY"
    elif check_quorum "$up_nodes" "$total_nodes"; then
        # Quorum is held but not all nodes are up → degraded but operational
        echo "$CLUSTER_STATUS_DEGRADED"
    else
        echo "$CLUSTER_STATUS_UNHEALTHY"
    fi
}

check_node_health() {
    local cluster_id="$1"
    local node_id="$2"
    
    local node_dir="$DATA_DIR/clusters/$cluster_id/nodes/$node_id"
    
    if [[ ! -d "$node_dir" ]]; then
        echo "$NODE_STATUS_DOWN"
        return 1
    fi
    
    # Check if node process is running (simulated)
    if [[ -f "$node_dir/pid" ]]; then
        echo "$NODE_STATUS_UP"
    else
        echo "$NODE_STATUS_DOWN"
    fi
}

################################################################################
# Cluster metrics functions
################################################################################

get_cluster_metrics() {
    local cluster_id="$1"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"
    
    local total_nodes=0
    local total_data_mb=0
    local avg_load=0
    
    for node_dir in "$cluster_dir/nodes"/*; do
        if [[ -d "$node_dir" ]]; then
            ((total_nodes++)) || true
            
            local metadata
            metadata=$(cat "$node_dir/metadata.json")
            
            local data_size
            data_size=$(echo "$metadata" | grep -o '"data_size_mb": [0-9]*' | awk '{print $2}')
            total_data_mb=$((total_data_mb + data_size))
            
            local load
            load=$(echo "$metadata" | grep -o '"load_percent": [0-9]*' | awk '{print $2}')
            avg_load=$((avg_load + load))
        fi
    done
    
    if [[ $total_nodes -gt 0 ]]; then
        avg_load=$((avg_load / total_nodes))
    fi
    
    cat << EOF
{
  "total_nodes": $total_nodes,
  "total_data_mb": $total_data_mb,
  "avg_load_percent": $avg_load
}
EOF
}

################################################################################
# Leader election (simplified Raft-like)
################################################################################

elect_leader() {
    local cluster_id="$1"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"

    # BUG FIX: the original `while IFS= read -r node_id; do ... done` had no
    # stdin source.  The heredoc/process-substitution was missing, so the loop
    # body never executed, up_nodes was always empty, and an empty string was
    # written to state/leader — silently, with exit code 0.
    #
    # Fix: pipe the sorted list of node directory basenames into the loop via
    # process substitution so it works correctly under `set -euo pipefail`.

    local up_nodes=()

    while IFS= read -r node_id; do
        [[ -z "$node_id" ]] && continue
        local node_dir="$cluster_dir/nodes/$node_id"
        [[ -d "$node_dir" ]] || continue

        local status
        status=$(grep -o '"status"[: ]*"[^"]*"' "$node_dir/metadata.json" \
                 | grep -o '"[^"]*"$' | tr -d '"')

        if [[ "$status" == "$NODE_STATUS_UP" ]]; then
            up_nodes+=("$node_id")
        fi
    done < <(find "$cluster_dir/nodes/" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)

    if [[ ${#up_nodes[@]} -eq 0 ]]; then
        # No UP nodes — cluster has no leader; write sentinel and return error
        echo "" > "$cluster_dir/state/leader"
        echo "none"
        return 1
    fi

    # Deterministic: sort and take the lexicographically smallest node-id
    local leader
    leader=$(printf '%s\n' "${up_nodes[@]}" | sort | head -n1)

    mkdir -p "$cluster_dir/state"
    echo "$leader" > "$cluster_dir/state/leader"
    echo "$leader"
}

get_cluster_leader() {
    local cluster_id="$1"
    local leader_file="$DATA_DIR/clusters/$cluster_id/state/leader"

    if [[ -f "$leader_file" ]]; then
        cat "$leader_file"
    else
        echo "none"
    fi
}

################################################################################
# Witness / force-quorum  (FIX-3: previously documented but never implemented)
#
# A Witness node is a lightweight tie-breaker that participates in quorum
# voting but holds no data.  It is the canonical solution for even-sized
# clusters (2, 4, 6 nodes) where a 50/50 network split would otherwise leave
# both partitions unable to achieve quorum, causing a full write-halt.
#
# Design:
#   - A Witness is stored as a regular node directory so that count_total_nodes,
#     count_up_nodes, check_quorum, and check_cluster_health all naturally
#     include it without special-casing.
#   - Its metadata.json carries  "role": "witness"  and  "is_witness": true
#     so callers that care (replication, data-placement) can skip it.
#   - The cluster metadata gains a  "witness_node_id"  field and a boolean
#     "force_quorum_enabled" flag.
#   - add_witness_to_cluster is idempotent: calling it twice on the same
#     cluster is safe.
#
# Usage:
#   add_witness_to_cluster  <cluster_id>   # add/enable witness
#   remove_witness_from_cluster <cluster_id>  # remove/disable witness
#   is_witness_enabled <cluster_id>        # returns 0 if enabled
#   get_witness_node_id <cluster_id>       # prints witness node-id or "none"
################################################################################

# add_witness_to_cluster <cluster_id>
#   Creates a witness node directory, updates cluster metadata, and re-runs
#   leader election so the new effective cluster size is taken into account.
add_witness_to_cluster() {
    local cluster_id="$1"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"

    [[ -d "$cluster_dir" ]] || { echo "add_witness_to_cluster: cluster not found: $cluster_id" >&2; return 1; }

    # Idempotency guard
    if is_witness_enabled "$cluster_id"; then
        local existing
        existing=$(get_witness_node_id "$cluster_id")
        echo "$existing"
        return 0
    fi

    # Assign the next available node number for the witness
    local current_count
    current_count=$(find "$cluster_dir/nodes" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    local witness_num=$(( current_count + 1 ))
    local witness_id="node-${witness_num}"
    local witness_dir="$cluster_dir/nodes/$witness_id"

    mkdir -p "$witness_dir"

    cat > "$witness_dir/metadata.json" << EOF
{
  "node_id": "$witness_id",
  "cluster_id": "$cluster_id",
  "ip": "127.0.0.1",
  "port": 0,
  "role": "witness",
  "is_witness": true,
  "status": "up",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "data_size_mb": 0,
  "load_percent": 0
}
EOF

    # Update cluster metadata: increment node_count and add witness fields
    local meta="$cluster_dir/metadata/cluster.json"
    sed_inplace "s/\"node_count\": [0-9]*/\"node_count\": $witness_num/" "$meta"

    # Append witness fields if not already present; use a temp file for safety
    local tmp
    tmp=$(mktemp)
    # Insert before the closing brace
    sed 's/}[[:space:]]*$/,\n  "witness_node_id": "'"$witness_id"'",\n  "force_quorum_enabled": true\n}/' "$meta" > "$tmp"
    mv "$tmp" "$meta"

    # Re-elect leader with the new topology
    elect_leader "$cluster_id" >/dev/null || true

    echo "$witness_id"
}

# remove_witness_from_cluster <cluster_id>
#   Removes the witness node directory and clears the witness metadata fields.
remove_witness_from_cluster() {
    local cluster_id="$1"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"

    [[ -d "$cluster_dir" ]] || { echo "remove_witness_from_cluster: cluster not found: $cluster_id" >&2; return 1; }

    local witness_id
    witness_id=$(get_witness_node_id "$cluster_id")

    if [[ "$witness_id" == "none" ]]; then
        return 0   # nothing to do
    fi

    local witness_dir="$cluster_dir/nodes/$witness_id"
    rm -rf "$witness_dir"

    # Update node_count in metadata
    local remaining
    remaining=$(find "$cluster_dir/nodes" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    local meta="$cluster_dir/metadata/cluster.json"
    sed_inplace "s/\"node_count\": [0-9]*/\"node_count\": $remaining/" "$meta"

    # Remove witness fields from metadata JSON
    local tmp
    tmp=$(mktemp)
    grep -v '"witness_node_id"\|"force_quorum_enabled"' "$meta" \
        | sed 's/,[[:space:]]*$//' > "$tmp"
    mv "$tmp" "$meta"

    elect_leader "$cluster_id" >/dev/null || true
}

# is_witness_enabled <cluster_id>
#   Returns 0 if a witness is active, 1 otherwise.
is_witness_enabled() {
    local cluster_id="$1"
    local meta="$DATA_DIR/clusters/$cluster_id/metadata/cluster.json"
    [[ -f "$meta" ]] || return 1
    grep -q '"force_quorum_enabled": true' "$meta"
}

# get_witness_node_id <cluster_id>
#   Prints the witness node-id, or "none" if no witness is configured.
get_witness_node_id() {
    local cluster_id="$1"
    local meta="$DATA_DIR/clusters/$cluster_id/metadata/cluster.json"
    if [[ -f "$meta" ]] && grep -q '"witness_node_id"' "$meta"; then
        grep -o '"witness_node_id": "[^"]*"' "$meta" | grep -o '"[^"]*"$' | tr -d '"'
    else
        echo "none"
    fi
}

################################################################################
# Replication functions
################################################################################

calculate_replication_status() {
    local cluster_id="$1"
    local cluster_dir="$DATA_DIR/clusters/$cluster_id"
    
    local metadata
    metadata=$(cat "$cluster_dir/metadata/cluster.json")
    
    local repl_factor
    repl_factor=$(echo "$metadata" | grep -o '"replication_factor": [0-9]*' | awk '{print $2}')
    
    local node_count
    node_count=$(find "$cluster_dir/nodes" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    
    if [[ $node_count -ge $repl_factor ]]; then
        echo "synchronized"
    else
        echo "under-replicated"
    fi
}

################################################################################
# Utility functions
################################################################################

generate_cluster_report() {
    local cluster_id="$1"
    local output_file="$2"
    
    {
        echo "# Cluster Report: $cluster_id"
        echo "Generated: $(date)"
        echo ""
        echo "## Overview"
        
        local metadata
        metadata=$(cat "$DATA_DIR/clusters/$cluster_id/metadata/cluster.json")
        
        echo "- Name: $(echo "$metadata" | grep -o '"name": "[^"]*"' | cut -d'"' -f4)"
        echo "- Type: $(echo "$metadata" | grep -o '"type": "[^"]*"' | cut -d'"' -f4)"
        echo "- Status: $(echo "$metadata" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)"
        echo ""
        
        echo "## Nodes"
        for node_dir in "$DATA_DIR/clusters/$cluster_id/nodes"/*; do
            if [[ -d "$node_dir" ]]; then
                local node_id
                node_id=$(basename "$node_dir")
                echo "- $node_id"
            fi
        done
    } > "$output_file"
}

# Export functions
export -f validate_cluster_name validate_node_count validate_replication_factor
export -f check_cluster_health check_node_health
export -f get_cluster_metrics
export -f elect_leader get_cluster_leader
export -f add_witness_to_cluster remove_witness_from_cluster is_witness_enabled get_witness_node_id
export -f calculate_replication_status
export -f generate_cluster_report

################################################################################
# sed_inplace <pattern> <file>
#
# Portable in-place sed that works on both macOS (BSD sed) and Linux (GNU sed).
#
# The `sed -i '' ... || sed -i ...` fallback is NOT safe:
#   - On some GNU sed versions, passing '' as the extension does not error —
#     it silently writes a backup file literally named '' beside the target,
#     leaves the original unchanged, and exits 0.  The metadata update then
#     never happens, and the caller never knows.
#
# This wrapper detects the OS once and dispatches to the correct form.
# Every destructive sed call in the project must go through this function.
################################################################################
sed_inplace() {
    local pattern="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        echo "sed_inplace: file not found: $file" >&2
        return 1
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}

# update_cluster_status <cluster_id> <new_status>
#   Flips the top-level "status" field in a cluster's metadata/cluster.json.
#   Moved here from bin/cluster-manager.sh — it only touches CLUSTER_DATA_DIR
#   and sed_inplace, both already library-level, and callers that just need
#   this one mutation shouldn't have to source the whole cluster-manager.sh
#   entrypoint (which runs main() on load) to get it.
update_cluster_status() {
    local cluster_id="$1"
    local new_status="$2"

    local metadata_file="$CLUSTER_DATA_DIR/$cluster_id/metadata/cluster.json"

    sed_inplace "s/\"status\": \"[^\"]*\"/\"status\": \"$new_status\"/" "$metadata_file"
}

export -f sed_inplace update_cluster_status
