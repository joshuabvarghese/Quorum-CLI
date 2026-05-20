#!/usr/bin/env bash
################################################################################
# Chaos Engineering Toolkit - Quorum-CLI
#
# SAFETY FIX: --dry-run is now a globally-exported variable consumed by the
# run_cmd() wrapper.  Every destructive primitive passes through run_cmd so
# that --dry-run is universally respected, regardless of which sub-command or
# future function is added.  Previously --dry-run was only checked inside
# simulate_partition(); all other destructive calls ran unconditionally.
################################################################################
set -euo pipefail

DATA_DIR="${DATA_DIR:-./data}"

# UI Colors
log_info()    { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn()    { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR]\033[0m $1"; }
log_success() { echo -e "\033[34m[SUCCESS]\033[0m $1"; }

# ---------------------------------------------------------------------------
# run_cmd <description> [cmd args...]
#
# Central gateway for every destructive operation.  When DRY_RUN=true it
# prints what it *would* do and returns without executing anything.
# ---------------------------------------------------------------------------
run_cmd() {
    local description="$1"; shift
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warn "DRY-RUN: $description (would run: $*)"
        return 0
    fi
    "$@"
}

show_usage() {
    cat << EOM
Usage: $(basename "$0") <scenario> [options]

Scenarios:
    kill-node           Stop a node process
    network-partition   Simulate a network partition between node groups
    recover-node        Restart a failed node
    partition           Isolate a node using iptables (Simulated)
    heal-partition      Restore network connectivity
    slow-network        Inject network latency
    high-load           Stress CPU/Memory

Options:
    --cluster-id <id>       The target cluster ID
    --node-id <id>          The specific node (e.g., node-2)
    --target-node <ip>      The IP address for network chaos
    --latency <ms>          Latency amount (default: 200ms)
    --duration <seconds>    Duration of high-load test (default: 5)
    --partition <g1> <g2>   Comma-separated node groups (e.g. "1,2" "3")
    --auto-recover          Automatically recover node after kill
    --dry-run               Show what would happen without making changes
EOM
    exit 1
}

# ---------------------------------------------------------------------------
# sed_inplace — portable in-place sed (macOS BSD vs Linux GNU)
# ---------------------------------------------------------------------------
sed_inplace() {
    local pattern="$1" file="$2"
    [[ -f "$file" ]] || { log_error "sed_inplace: file not found: $file"; return 1; }
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}

# ---------------------------------------------------------------------------
# _write_node_status <metadata_file> <status>
#
# Writes a new status value into a node metadata.json.
# Passes through run_cmd so dry-run suppresses it.
# ---------------------------------------------------------------------------
_write_node_status() {
    local meta="$1" new_status="$2"
    run_cmd "set status=$new_status in $meta" \
        sed_inplace "s/\"status\": \"[^\"]*\"/\"status\": \"$new_status\"/" "$meta"
}

# ---------------------------------------------------------------------------
# simulate_node_failure <cluster_id> <node_id> [auto_recover]
# ---------------------------------------------------------------------------
simulate_node_failure() {
    local cid="$1" nid="$2" auto_recover="${3:-false}"
    local meta="$DATA_DIR/clusters/$cid/nodes/$nid/metadata.json"

    [[ -d "$DATA_DIR/clusters/$cid" ]] || { log_error "Cluster not found: $cid"; return 1; }
    [[ -f "$meta" ]]                   || { log_error "Node not found: $nid in cluster $cid"; return 1; }

    log_warn "CHAOS INITIATED: Terminating $nid in cluster $cid"
    _write_node_status "$meta" "down"

    if [[ "$auto_recover" == "true" ]]; then
        log_info "Auto-recover enabled — restoring $nid ..."
        _write_node_status "$meta" "up"
        log_success "$nid has been recovered and is back online."
    else
        log_info "$nid process terminated."
    fi
}

# ---------------------------------------------------------------------------
# recover_node <cluster_id> <node_id>
# ---------------------------------------------------------------------------
recover_node() {
    local cid="$1" nid="$2"
    local meta="$DATA_DIR/clusters/$cid/nodes/$nid/metadata.json"

    [[ -f "$meta" ]] || { log_error "Node metadata not found: $meta"; return 1; }

    log_info "RECOVERING: Restarting $nid..."
    _write_node_status "$meta" "up"
    log_success "$nid is back online and resyncing data."
}

# ---------------------------------------------------------------------------
# simulate_partition <cluster_id> <group1_csv> <group2_csv>
# ---------------------------------------------------------------------------
simulate_partition() {
    local cid="$1" g1="$2" g2="$3"
    log_warn "CHAOS: Simulating network partition between [$g1] and [$g2] in cluster $cid"
    run_cmd "write partition state" \
        mkdir -p "$DATA_DIR/clusters/$cid/state"
    run_cmd "record partition groups in state file" \
        bash -c "echo 'partition:${g1}|${g2}' > '$DATA_DIR/clusters/$cid/state/partition'"
    log_info "Partition applied (local state). In production this would update iptables via ssh."
}

# ---------------------------------------------------------------------------
# simulate_latency <target_ip> <latency>
# ---------------------------------------------------------------------------
simulate_latency() {
    local target="$1" lat="$2"
    log_warn "CHAOS: Injecting $lat latency targeting $target"
    run_cmd "apply tc latency rules on eth0 for $target" \
        bash -c "echo 'Would run: tc qdisc add dev eth0 root netem delay $lat'"
    log_info "Traffic Control (tc) rules applied to interface eth0."
}

# ---------------------------------------------------------------------------
# Main argument parsing
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && show_usage
SCENARIO="$1"; shift

CLUSTER_ID=""
NODE_ID=""
TARGET_IP=""
LATENCY="200ms"
DURATION=5
AUTO_RECOVER=false
PARTITION_G1=""
PARTITION_G2=""
export DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-id)    CLUSTER_ID="$2";    shift 2 ;;
        --node-id)       NODE_ID="$2";       shift 2 ;;
        --target-node)   TARGET_IP="$2";     shift 2 ;;
        --latency)       LATENCY="$2";       shift 2 ;;
        --duration)      DURATION="$2";      shift 2 ;;
        --auto-recover)  AUTO_RECOVER=true;  shift ;;
        --dry-run)       DRY_RUN=true;       shift ;;
        --partition)     PARTITION_G1="$2"; PARTITION_G2="$3"; shift 3 ;;
        *) shift ;;
    esac
done

case "$SCENARIO" in
    kill-node)
        simulate_node_failure "$CLUSTER_ID" "$NODE_ID" "$AUTO_RECOVER"
        ;;
    network-partition)
        simulate_partition "$CLUSTER_ID" "$PARTITION_G1" "$PARTITION_G2"
        ;;
    recover-node)
        recover_node "$CLUSTER_ID" "$NODE_ID"
        ;;
    partition)
        log_warn "CHAOS: Creating network partition for $TARGET_IP"
        run_cmd "apply iptables DROP rule for ${TARGET_IP%.*}.0/24" \
            bash -c "echo 'Would run: ssh $TARGET_IP sudo iptables -A INPUT -s ${TARGET_IP%.*}.0/24 -j DROP'"
        ;;
    heal-partition)
        run_cmd "remove iptables DROP rule for $TARGET_IP" \
            bash -c "echo 'Would run: ssh $TARGET_IP sudo iptables -D INPUT -s ${TARGET_IP%.*}.0/24 -j DROP'"
        log_success "Network connectivity restored to $TARGET_IP"
        ;;
    slow-network)
        simulate_latency "$TARGET_IP" "$LATENCY"
        ;;
    high-load)
        log_warn "CPU stress test started on $CLUSTER_ID for ${DURATION}s..."
        run_cmd "stress CPU for ${DURATION}s" \
            bash -c "timeout $DURATION bash -c 'while :; do :; done' &>/dev/null || true"
        log_success "High-load test completed."
        ;;
    *)
        show_usage
        ;;
esac
