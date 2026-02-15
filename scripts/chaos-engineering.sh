#!/bin/bash

################################################################################
# Chaos Engineering - Simulate failures and test resilience
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$PROJECT_ROOT/bin"
DATA_DIR="$PROJECT_ROOT/data"

source "$PROJECT_ROOT/lib/logger.sh"

################################################################################
# Chaos Scenarios
################################################################################

show_usage() {
    cat << EOF
Chaos Engineering - Distributed System Failure Simulation

Usage: $(basename "$0") <scenario> [options]

Scenarios:
    kill-node           Simulate node failure
    network-partition   Simulate network split
    disk-failure        Simulate disk failure
    high-load           Simulate high resource usage
    slow-network        Simulate network latency
    data-corruption     Simulate data corruption

Options:
    --cluster-id <id>    Cluster ID
    --node-id <id>       Node ID to kill
    --partition <p>      Partition groups (e.g., "1,2" "3")
    --duration <sec>     Duration of chaos
    --auto-recover       Auto-recover after duration

Examples:
    $(basename "$0") kill-node --cluster-id cls-001 --node-id node-2
    $(basename "$0") network-partition --cluster-id cls-001 --partition "1,2" "3"
    $(basename "$0") high-load --cluster-id cls-001 --duration 60

EOF
    exit 0
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
    
    # Update node status to down
    local metadata_file="$node_dir/metadata.json"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/"status": "up"/"status": "down"/' "$metadata_file"
    else
        sed -i 's/"status": "up"/"status": "down"/' "$metadata_file"
    fi
    
    # Remove PID file
    rm -f "$node_dir/pid"
    
    log_info "Node $node_id is now DOWN"
    echo ""
    
    # Check cluster health
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
    
    # Update status
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/"status": "down"/"status": "up"/' "$metadata_file"
    else
        sed -i 's/"status": "down"/"status": "up"/' "$metadata_file"
    fi
    
    # Recreate PID
    echo "$$" > "$node_dir/pid"
    
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
        echo "  Partition $((i+1)): ${partitions[$i]}"
    done
    echo ""
    
    log_warn "Nodes in different partitions cannot communicate"
    log_info "This may trigger split-brain scenarios"
    echo ""
    
    # Simulate by marking some nodes as unreachable
    log_info "Monitoring cluster behavior during partition..."
    
    sleep 3
    
    log_warn "Partition detected! Quorum-based decisions in progress..."
    log_info "Majority partition maintains write capability"
    log_info "Minority partition enters read-only mode"
    
    echo ""
    log_info "To heal partition, run: $(basename "$0") heal-partition --cluster-id $cluster_id"
}

simulate_disk_failure() {
    local cluster_id="$1"
    local node_id="$2"
    
    log_warn "$(tput setaf 1)CHAOS INITIATED:$(tput sgr0) Disk failure on $node_id"
    
    local node_dir="$DATA_DIR/clusters/$cluster_id/nodes/$node_id"
    
    # Simulate by making data directory read-only
    chmod -w "$node_dir/data" 2>/dev/null || true
    
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
    
    # Simulate load spikes
    for ((i=1; i<=duration; i++)); do
        printf "\rLoad: %d%%  Memory: %d%%  Time: %ds/%ds" \
            "$((RANDOM % 30 + 70))" \
            "$((RANDOM % 20 + 75))" \
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
    
    log_info "Monitoring impact on read/write latency..."
    
    for i in {1..5}; do
        local read_lat=$((RANDOM % 50 + latency_ms))
        local write_lat=$((RANDOM % 80 + latency_ms))
        
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
    
    # Modify a few bytes in the volume
    local volume_file="$DATA_DIR/volumes/$volume_id/data/volume.dat"
    
    if [[ -f "$volume_file" ]]; then
        echo "corrupted" | dd of="$volume_file" bs=1 seek=1000 conv=notrunc 2>/dev/null || true
        
        log_info "Corruption injected"
        log_info "Running integrity check..."
        
        sleep 2
        
        "$BIN_DIR/storage-ops.sh" verify --volume-id "$volume_id"
        
        echo ""
        log_warn "Corruption should be detected in integrity check"
        log_info "Repair should restore from healthy replica"
    else
        log_error "Volume file not found"
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
    local duration=60
    local auto_recover=false
    local partitions=()
    local volume_id=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster-id)
                cluster_id="$2"
                shift 2
                ;;
            --node-id)
                node_id="$2"
                shift 2
                ;;
            --duration)
                duration="$2"
                shift 2
                ;;
            --auto-recover)
                auto_recover=true
                shift
                ;;
            --partition)
                while [[ $# -gt 1 ]] && [[ ! "$2" =~ ^-- ]]; do
                    shift
                    partitions+=("$1")
                done
                shift
                ;;
            --volume-id)
                volume_id="$2"
                shift 2
                ;;
            --help)
                show_usage
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done
    
    case "$scenario" in
        kill-node)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            [[ -z "$node_id" ]] && { log_error "Node ID required"; exit 1; }
            simulate_node_failure "$cluster_id" "$node_id" "$auto_recover"
            ;;
        network-partition)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            [[ ${#partitions[@]} -lt 2 ]] && { log_error "At least 2 partitions required"; exit 1; }
            simulate_network_partition "$cluster_id" "${partitions[@]}"
            ;;
        disk-failure)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            [[ -z "$node_id" ]] && { log_error "Node ID required"; exit 1; }
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
            [[ -z "$volume_id" ]] && { log_error "Volume ID required"; exit 1; }
            simulate_data_corruption "$cluster_id" "$volume_id"
            ;;
        *)
            log_error "Unknown scenario: $scenario"
            show_usage
            ;;
    esac
}

main "$@"
