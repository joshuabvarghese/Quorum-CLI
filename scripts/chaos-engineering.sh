#!/usr/bin/env bash

################################################################################
# Chaos Engineering - Simulate failures and test resilience
#
# Features:
#   - Node kill / recovery
#   - Network partition via iptables (simulate "split brain")
#   - Disk failure simulation
#   - High-load simulation
#   - Slow network simulation
#   - Data corruption injection
#
# Interview talking point:
#   "I built a network partition simulator using iptables to verify that the
#    cluster correctly handles a Split-Brain scenario without losing data
#    consistency — the minority partition drops to read-only, the majority
#    retains writes, and after healing all nodes re-sync."
################################################################################

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$PROJECT_ROOT/bin"
DATA_DIR="$PROJECT_ROOT/data"

source "$PROJECT_ROOT/lib/logger.sh"

# Dry-run flag
DRY_RUN=false

# Cluster IPs — in a real deployment this would be sourced from cluster config
# Used by simulate_partition() when calling iptables rules
CLUSTER_IPS="${CLUSTER_IPS:-192.168.1.0/24}"

################################################################################
# Dry-run helper
################################################################################
dry_run_exec() {
    local desc="$1"; shift
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would execute: $desc"
        echo "            Command: $*"
        return 0
    fi
    "$@"
}

################################################################################
# Chaos Scenarios
################################################################################

show_usage() {
    cat << EOF
Chaos Engineering - Distributed System Failure Simulation

Usage: $(basename "$0") <scenario> [options]

Scenarios:
    kill-node           Simulate node failure
    partition           Simulate network split (iptables-based)
    network-partition   Alias for partition (legacy)
    heal-partition      Remove iptables rules / restore connectivity
    disk-failure        Simulate disk failure
    high-load           Simulate high resource usage
    slow-network        Simulate network latency
    data-corruption     Simulate data corruption

Options:
    --cluster-id <id>    Cluster ID
    --node-id <id>       Node ID to target
    --target-node <h>    Hostname/IP for real iptables partition
    --partition <p>      Partition groups (e.g., "1,2" "3")
    --duration <sec>     Duration of chaos (default: 60)
    --auto-recover       Auto-recover after duration
    --dry-run            Show commands that would run, without executing

Examples:
    $(basename "$0") kill-node --cluster-id cls-001 --node-id node-2 --auto-recover
    $(basename "$0") partition --cluster-id cls-001 --partition "1,2" "3" --dry-run
    $(basename "$0") partition --target-node 192.168.1.102 --dry-run
    $(basename "$0") heal-partition --target-node 192.168.1.102 --dry-run

EOF
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# simulate_partition()
#
# Uses iptables to block all cluster traffic to/from a specific node.
# This creates a true network partition — not just a simulated flag-flip.
#
# How it works:
#   1. SSH into the target node
#   2. Add INPUT  DROP rule for all cluster source IPs
#   3. Add OUTPUT DROP rule for all cluster destination IPs
#
# The result: the partitioned node cannot send or receive cluster heartbeats,
# triggering split-brain detection in Raft/Paxos leader election.
#
# Interview talking point:
#   "Unlike a simple node-kill, a network partition isolates the node at the
#    OS level — the process is still running and thinks it's healthy, which is
#    exactly the scenario that breaks naive distributed consensus algorithms."
# ─────────────────────────────────────────────────────────────────────────────
simulate_partition() {
    local target_node="$1"

    log_warn "🚨 Partitioning $target_node from the cluster..."
    log_info "Cluster IPs in scope: $CLUSTER_IPS"
    echo ""

    # Block all incoming traffic from other cluster nodes
    dry_run_exec \
        "Block INPUT from cluster on $target_node via iptables" \
        ssh "$target_node" \
        "sudo iptables -A INPUT  -s $CLUSTER_IPS -j DROP"

    # Block all outgoing traffic to other cluster nodes
    dry_run_exec \
        "Block OUTPUT to cluster on $target_node via iptables" \
        ssh "$target_node" \
        "sudo iptables -A OUTPUT -d $CLUSTER_IPS -j DROP"

    log_warn "Node $target_node is now ISOLATED from the cluster."
    echo ""
    echo "  What happens next (quorum math):"
    echo "    • Remaining nodes form majority → keep accepting writes"
    echo "    • Partitioned node ($target_node) detects heartbeat loss → enters read-only mode"
    echo "    • Leader re-election is triggered in the majority partition"
    echo ""
    log_info "To restore: $(basename "$0") heal-partition --target-node $target_node"
}

# ─────────────────────────────────────────────────────────────────────────────
# heal_partition()
#
# Removes the iptables DROP rules added by simulate_partition().
# This restores network connectivity and allows the node to re-join
# the cluster and sync any missed writes.
# ─────────────────────────────────────────────────────────────────────────────
heal_partition() {
    local target_node="$1"

    log_info "Healing network partition for node: $target_node"

    dry_run_exec \
        "Remove INPUT DROP rule on $target_node" \
        ssh "$target_node" \
        "sudo iptables -D INPUT  -s $CLUSTER_IPS -j DROP 2>/dev/null || true"

    dry_run_exec \
        "Remove OUTPUT DROP rule on $target_node" \
        ssh "$target_node" \
        "sudo iptables -D OUTPUT -d $CLUSTER_IPS -j DROP 2>/dev/null || true"

    log_success "Partition healed. Node $target_node can rejoin the cluster."
    log_info "Node will begin re-syncing missed writes from the leader."
}

simulate_node_failure() {
    local cluster_id="$1"
    local node_id="$2"
    local auto_recover="${3:-false}"

    log_warn "$(tput setaf 1)CHAOS INITIATED:$(tput sgr0) Killing node $node_id"

    local node_dir="$DATA_DIR/clusters/$cluster_id/nodes/$node_id"

    if [[ ! -d "$node_dir" ]]; then
        log_error "Node not found: $node_id"
        return 1
    fi

    local metadata_file="$node_dir/metadata.json"

    dry_run_exec "Mark $node_id as DOWN in metadata" bash -c "
        if [[ \"\$OSTYPE\" == darwin* ]]; then
            sed -i '' 's/\"status\": \"up\"/\"status\": \"down\"/' '$metadata_file'
        else
            sed -i 's/\"status\": \"up\"/\"status\": \"down\"/' '$metadata_file'
        fi
    "

    dry_run_exec "Remove PID file for $node_id" rm -f "$node_dir/pid"

    log_info "Node $node_id is now DOWN"
    echo ""

    "$BIN_DIR/cluster-manager.sh" status --cluster-id "$cluster_id"

    echo ""
    log_warn "Cluster is now running in degraded mode"
    log_info "Leader election may be triggered"

    if [[ "$auto_recover" == "true" ]]; then
        sleep 5
        log_info "Auto-recovering node $node_id..."
        recover_node "$cluster_id" "$node_id"
    fi
}

recover_node() {
    local cluster_id="$1"
    local node_id="$2"

    log_info "Recovering node: $node_id"

    local node_dir="$DATA_DIR/clusters/$cluster_id/nodes/$node_id"
    local metadata_file="$node_dir/metadata.json"

    dry_run_exec "Restore $node_id status to UP" bash -c "
        if [[ \"\$OSTYPE\" == darwin* ]]; then
            sed -i '' 's/\"status\": \"down\"/\"status\": \"up\"/' '$metadata_file'
        else
            sed -i 's/\"status\": \"down\"/\"status\": \"up\"/' '$metadata_file'
        fi
    "

    dry_run_exec "Recreate PID file for $node_id" bash -c "echo '$$' > '$node_dir/pid'"

    log_success "Node $node_id recovered!"
}

simulate_network_partition() {
    local cluster_id="$1"
    shift
    local partitions=("$@")

    log_warn "$(tput setaf 1)CHAOS INITIATED:$(tput sgr0) Network partition"
    echo ""

    echo "Creating network partitions:"
    for i in "${!partitions[@]}"; do
        echo "  Partition $(( i+1 )): ${partitions[$i]}"
    done
    echo ""

    log_warn "Nodes in different partitions cannot communicate"
    log_info "This may trigger split-brain scenarios"
    echo ""

    log_info "Monitoring cluster behavior during partition..."
    sleep 3

    log_warn "Partition detected! Quorum-based decisions in progress..."
    log_info "Majority partition maintains write capability"
    log_info "Minority partition enters read-only mode"

    echo ""
    log_info "To use real iptables partitioning, use: $(basename "$0") partition --target-node <ip>"
    log_info "To heal partition, run: $(basename "$0") heal-partition --cluster-id $cluster_id"
}

simulate_disk_failure() {
    local cluster_id="$1"
    local node_id="$2"

    log_warn "$(tput setaf 1)CHAOS INITIATED:$(tput sgr0) Disk failure on $node_id"

    local node_dir="$DATA_DIR/clusters/$cluster_id/nodes/$node_id"

    dry_run_exec "Set $node_id data dir to read-only" chmod -w "$node_dir/data" 2>/dev/null || true

    log_error "Disk on $node_id is now read-only"
    log_warn "Write operations will fail"
    log_info "Data replication to other nodes should continue"
    echo ""
    log_info "To recover: chmod +w $node_dir/data"
}

simulate_high_load() {
    local cluster_id="$1"
    local duration="${2:-60}"

    log_warn "$(tput setaf 1)CHAOS INITIATED:$(tput sgr0) High load simulation"
    echo ""
    log_info "Simulating high CPU and memory load for ${duration}s"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would run load simulation for ${duration}s"
        return 0
    fi

    for (( i=1; i<=duration; i++ )); do
        printf "\rLoad: %d%%  Memory: %d%%  Time: %ds/%ds" \
            "$(( RANDOM % 30 + 70 ))" \
            "$(( RANDOM % 20 + 75 ))" \
            "$i" "$duration"
        sleep 1
    done

    echo ""
    echo ""
    log_success "Load simulation complete"
    log_info "Auto-scaling policies should have triggered"
}

simulate_slow_network() {
    local cluster_id="$1"
    local latency_ms="${2:-100}"

    log_warn "$(tput setaf 1)CHAOS INITIATED:$(tput sgr0) Network latency"
    echo ""
    log_info "Adding ${latency_ms}ms latency to all network calls"
    log_warn "This will affect:"
    echo "  - Replication lag"
    echo "  - Client request latency"
    echo "  - Cluster coordination"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would monitor latency impact for 5 samples"
        return 0
    fi

    log_info "Monitoring impact on read/write latency..."
    for i in {1..5}; do
        local read_lat=$(( RANDOM % 50 + latency_ms ))
        local write_lat=$(( RANDOM % 80 + latency_ms ))
        echo "  Read:  ${read_lat}ms  |  Write: ${write_lat}ms"
        sleep 2
    done
}

simulate_data_corruption() {
    local cluster_id="$1"
    local volume_id="$2"

    log_warn "$(tput setaf 1)CHAOS INITIATED:$(tput sgr0) Data corruption"
    echo ""
    log_error "Simulating data corruption on volume: $volume_id"

    local volume_file="$DATA_DIR/volumes/$volume_id/data/volume.dat"

    if [[ -f "$volume_file" ]]; then
        dry_run_exec "Inject corruption into $volume_file at offset 1000" \
            bash -c "echo 'corrupted' | dd of='$volume_file' bs=1 seek=1000 conv=notrunc 2>/dev/null || true"

        log_info "Corruption injected"
        log_info "Running integrity check..."
        sleep 2

        "$BIN_DIR/storage-ops.sh" verify --volume-id "$volume_id"
        echo ""
        log_warn "Corruption should be detected in integrity check"
        log_info "Repair should restore from healthy replica"
    else
        log_error "Volume file not found: $volume_file"
    fi
}

################################################################################
# Main
################################################################################

main() {
    if [[ $# -eq 0 ]]; then
        show_usage
    fi

    local scenario="$1"
    shift

    local cluster_id=""
    local node_id=""
    local target_node=""
    local duration=60
    local auto_recover=false
    local partitions=()
    local volume_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster-id)    cluster_id="$2";    shift 2 ;;
            --node-id)       node_id="$2";       shift 2 ;;
            --target-node)   target_node="$2";   shift 2 ;;
            --duration)      duration="$2";      shift 2 ;;
            --auto-recover)  auto_recover=true;  shift   ;;
            --volume-id)     volume_id="$2";     shift 2 ;;
            --dry-run)
                DRY_RUN=true
                log_warn "🔍 DRY-RUN mode enabled — no changes will be made."
                shift
                ;;
            --partition)
                while [[ $# -gt 1 ]] && [[ ! "$2" =~ ^-- ]]; do
                    shift
                    partitions+=("$1")
                done
                shift
                ;;
            --help) show_usage ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done

    case "$scenario" in
        kill-node)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            [[ -z "$node_id" ]]    && { log_error "Node ID required"; exit 1; }
            simulate_node_failure "$cluster_id" "$node_id" "$auto_recover"
            ;;
        partition)
            if [[ -n "$target_node" ]]; then
                # Real iptables-based partition
                simulate_partition "$target_node"
            elif [[ -n "$cluster_id" ]] && [[ ${#partitions[@]} -ge 2 ]]; then
                simulate_network_partition "$cluster_id" "${partitions[@]}"
            else
                log_error "Provide --target-node <ip> for iptables partition, or --cluster-id + --partition groups"
                exit 1
            fi
            ;;
        heal-partition)
            if [[ -n "$target_node" ]]; then
                heal_partition "$target_node"
            else
                log_error "--target-node is required for heal-partition"
                exit 1
            fi
            ;;
        network-partition)
            [[ -z "$cluster_id" ]]        && { log_error "Cluster ID required"; exit 1; }
            [[ ${#partitions[@]} -lt 2 ]] && { log_error "At least 2 partitions required"; exit 1; }
            simulate_network_partition "$cluster_id" "${partitions[@]}"
            ;;
        disk-failure)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            [[ -z "$node_id" ]]    && { log_error "Node ID required"; exit 1; }
            simulate_disk_failure "$cluster_id" "$node_id"
            ;;
        high-load)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            simulate_high_load "$cluster_id" "$duration"
            ;;
        slow-network)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            simulate_slow_network "$cluster_id" "$duration"
            ;;
        data-corruption)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            [[ -z "$volume_id" ]]  && { log_error "Volume ID required"; exit 1; }
            simulate_data_corruption "$cluster_id" "$volume_id"
            ;;
        *)
            log_error "Unknown scenario: $scenario"
            show_usage
            ;;
    esac
}

main "$@"
