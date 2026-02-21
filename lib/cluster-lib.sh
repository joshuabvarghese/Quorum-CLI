#!/usr/bin/env bash

################################################################################
# Cluster Library - Utility functions for cluster management
################################################################################

set -euo pipefail
IFS=$'\n\t'

# Cluster state constants
readonly CLUSTER_STATUS_HEALTHY="healthy"
readonly CLUSTER_STATUS_DEGRADED="degraded"
readonly CLUSTER_STATUS_UNHEALTHY="unhealthy"
readonly CLUSTER_STATUS_INITIALIZING="initializing"

# Node status constants
readonly NODE_STATUS_UP="up"
readonly NODE_STATUS_DOWN="down"
readonly NODE_STATUS_STARTING="starting"
readonly NODE_STATUS_STOPPING="stopping"

################################################################################
# Cluster validation functions
################################################################################

validate_cluster_name() {
    local name="$1"
    if [[ -z "$name" ]]; then return 1; fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then return 1; fi
    return 0
}

validate_node_count() {
    local count="$1"
    local max_nodes="${2:-100}"
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then return 1; fi
    if [[ $count -lt 1 ]] || [[ $count -gt $max_nodes ]]; then return 1; fi
    return 0
}

validate_replication_factor() {
    local factor="$1"
    local node_count="$2"
    if [[ ! "$factor" =~ ^[0-9]+$ ]]; then return 1; fi
    if [[ $factor -lt 1 ]] || [[ $factor -gt $node_count ]]; then return 1; fi
    return 0
}

################################################################################
# Quorum math
################################################################################

# Returns 0 (true) if quorum is reachable given up_nodes/total_nodes.
# Quorum = strict majority: floor(total/2) + 1
check_quorum() {
    local up_nodes="$1"
    local total_nodes="$2"
    local quorum_needed=$(( total_nodes / 2 + 1 ))
    [[ $up_nodes -ge $quorum_needed ]]
}

# Returns the quorum threshold for a given total
quorum_threshold() {
    local total="$1"
    echo $(( total / 2 + 1 ))
}

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

    for node_dir in "$cluster_dir/nodes"/*; do
        if [[ -d "$node_dir" ]]; then
            (( total_nodes++ ))
            local status
            status=$(grep '"status"' "$node_dir/metadata.json" | cut -d'"' -f4)
            if [[ "$status" == "$NODE_STATUS_UP" ]]; then
                (( up_nodes++ ))
            fi
        fi
    done

    if [[ $up_nodes -eq $total_nodes ]]; then
        echo "$CLUSTER_STATUS_HEALTHY"
    elif check_quorum "$up_nodes" "$total_nodes"; then
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
            (( total_nodes++ ))
            local metadata
            metadata=$(cat "$node_dir/metadata.json")
            local data_size
            data_size=$(echo "$metadata" | grep -o '"data_size_mb": [0-9]*' | awk '{print $2}')
            total_data_mb=$(( total_data_mb + data_size ))
            local load
            load=$(echo "$metadata" | grep -o '"load_percent": [0-9]*' | awk '{print $2}')
            avg_load=$(( avg_load + load ))
        fi
    done

    if [[ $total_nodes -gt 0 ]]; then
        avg_load=$(( avg_load / total_nodes ))
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
    local up_nodes=()

    for node_dir in "$cluster_dir/nodes"/*; do
        if [[ -d "$node_dir" ]]; then
            local node_id
            node_id=$(basename "$node_dir")
            local status
            status=$(grep '"status"' "$node_dir/metadata.json" | cut -d'"' -f4)
            if [[ "$status" == "$NODE_STATUS_UP" ]]; then
                up_nodes+=("$node_id")
            fi
        fi
    done

    local leader
    leader=$(printf '%s\n' "${up_nodes[@]}" | sort | head -n1)
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
    node_count=$(ls -1 "$cluster_dir/nodes" | wc -l | tr -d ' ')
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
export -f check_quorum quorum_threshold
export -f check_cluster_health check_node_health
export -f get_cluster_metrics
export -f elect_leader get_cluster_leader
export -f calculate_replication_status
export -f generate_cluster_report
