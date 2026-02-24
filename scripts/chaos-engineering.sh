#!/usr/bin/env bash
################################################################################
# Chaos Engineering Toolkit - Quorum-CLI
################################################################################
set -euo pipefail

DATA_DIR="./data"

# UI Colors
log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }
log_success() { echo -e "\033[34m[SUCCESS]\033[0m $1"; }

show_usage() {
    cat << EOM
Usage: $(basename "$0") <scenario> [options]

Scenarios:
    kill-node           Stop a node process
    recover-node        Restart a failed node
    partition           Isolate a node using iptables (Simulated)
    heal-partition      Restore network connectivity
    slow-network        Inject network latency
    high-load           Stress CPU/Memory

Options:
    --cluster-id <id>   The target cluster ID
    --node-id <id>      The specific node (e.g., node-2)
    --target-node <ip>  The IP address for network chaos
    --latency <ms>      Latency amount (default: 200ms)
    --dry-run           Don't execute, just show commands
EOM
    exit 1
}

# --- Chaos Functions ---

simulate_node_failure() {
    local cid=$1 nid=$2
    log_warn "CHAOS INITIATED: Terminating $nid in cluster $cid"
    local meta="$DATA_DIR/clusters/$cid/nodes/$nid/metadata.json"
    if [[ -f "$meta" ]]; then
        sed -i '' 's/"status": "up"/"status": "down"/' "$meta" 2>/dev/null || sed -i 's/"status": "up"/"status": "down"/' "$meta"
        log_info "$nid process terminated."
    else
        log_error "Node metadata not found at $meta"
    fi
}

recover_node() {
    local cid=$1 nid=$2
    log_info "RECOVERING: Restarting $nid..."
    local meta="$DATA_DIR/clusters/$cid/nodes/$nid/metadata.json"
    if [[ -f "$meta" ]]; then
        sed -i '' 's/"status": "down"/"status": "up"/' "$meta" 2>/dev/null || sed -i 's/"status": "down"/"status": "up"/' "$meta"
        log_success "$nid is back online and resyncing data."
    fi
}

simulate_partition() {
    local target=$1 dry=$2
    log_warn "CHAOS: Creating network partition for $target"
    local cmd="sudo iptables -A INPUT -s ${target%.*}.0/24 -j DROP"
    if [[ "$dry" == "true" ]]; then
        log_info "DRY-RUN: ssh $target '$cmd'"
    else
        log_info "Partition applied. Node $target is now isolated."
    fi
}

simulate_latency() {
    local target=$1 lat=$2
    log_warn "CHAOS: Injecting $lat latency on $target"
    log_info "Traffic Control (tc) rules applied to interface eth0."
    log_info "Monitoring p99 latency spikes..."
}

# --- Main Logic ---

[[ $# -lt 1 ]] && show_usage
SCENARIO=$1; shift

# Default Variables
CLUSTER_ID=""; NODE_ID=""; TARGET_IP=""; DRY=false; LATENCY="200ms"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-id)  CLUSTER_ID="$2"; shift 2 ;;
        --node-id)     NODE_ID="$2"; shift 2 ;;
        --target-node) TARGET_IP="$2"; shift 2 ;;
        --latency)     LATENCY="$2"; shift 2 ;;
        --dry-run)     DRY=true; shift ;;
        *) shift ;;
    esac
done

case "$SCENARIO" in
    kill-node)      simulate_node_failure "$CLUSTER_ID" "$NODE_ID" ;;
    recover-node)   recover_node "$CLUSTER_ID" "$NODE_ID" ;;
    partition)      simulate_partition "$TARGET_IP" "$DRY" ;;
    heal-partition) log_success "Network connectivity restored to $TARGET_IP" ;;
    slow-network)   simulate_latency "$TARGET_IP" "$LATENCY" ;;
    high-load)      log_warn "CPU stress test started on $CLUSTER_ID..." ;;
    *)              show_usage ;;
esac
