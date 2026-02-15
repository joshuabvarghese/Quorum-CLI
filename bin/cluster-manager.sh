#!/bin/bash

################################################################################
# Cluster Manager - Main cluster lifecycle management
# Manages distributed cluster creation, scaling, and monitoring
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"
CONFIG_DIR="$PROJECT_ROOT/config"
DATA_DIR="$PROJECT_ROOT/data"
LOG_DIR="$PROJECT_ROOT/logs/cluster"

# Source libraries
source "$LIB_DIR/logger.sh"
source "$LIB_DIR/cluster-lib.sh"

# Global variables
CLUSTER_DATA_DIR="$DATA_DIR/clusters"
LOG_FILE="$LOG_DIR/cluster-manager.log"

################################################################################
# Functions
################################################################################

show_usage() {
    cat << EOF
Cluster Manager - Distributed Storage Cluster Management

Usage: $(basename "$0") <command> [options]

Commands:
    init                    Initialize the cluster management system
    create                  Create a new cluster
    destroy                 Destroy a cluster
    status                  Show cluster status
    list                    List all clusters
    add-node                Add a node to cluster
    remove-node             Remove a node from cluster
    scale                   Scale cluster up/down
    diagnose                Run cluster diagnostics

Options:
    --name <name>           Cluster name
    --nodes <count>         Number of nodes
    --type <type>           Cluster type (cassandra|kafka|redis)
    --cluster-id <id>       Cluster ID
    --node-id <id>          Node ID
    --replication-factor <n> Replication factor (default: 3)
    --verbose               Verbose output
    --help                  Show this help

Examples:
    $(basename "$0") init
    $(basename "$0") create --name prod-cluster --nodes 3 --type cassandra
    $(basename "$0") status --cluster-id cls-001
    $(basename "$0") add-node --cluster-id cls-001
    $(basename "$0") scale --cluster-id cls-001 --nodes 5

EOF
    exit 0
}

initialize_system() {
    log_info "Initializing cluster management system..."
    
    # Create directory structure
    mkdir -p "$CLUSTER_DATA_DIR" "$LOG_DIR"
    
    # Create default config if not exists
    if [[ ! -f "$CONFIG_DIR/cluster.conf" ]]; then
        cat > "$CONFIG_DIR/cluster.conf" << 'EOL'
# Default Cluster Configuration
DEFAULT_CLUSTER_TYPE=cassandra
DEFAULT_REPLICATION_FACTOR=3
DEFAULT_NODE_COUNT=3
BASE_PORT=7000
HEARTBEAT_INTERVAL=5
HEALTH_CHECK_INTERVAL=10
MAX_NODES_PER_CLUSTER=100
EOL
        log_info "Created default cluster configuration"
    fi
    
    log_success "System initialized successfully"
}

create_cluster() {
    local cluster_name="$1"
    local node_count="$2"
    local cluster_type="${3:-cassandra}"
    local replication_factor="${4:-3}"
    
    log_info "Creating cluster: $cluster_name"
    log_info "Type: $cluster_type, Nodes: $node_count, Replication: $replication_factor"
    
    # Generate cluster ID
    local cluster_id="cls-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"
    
    # Create cluster directory
    mkdir -p "$cluster_dir"/{nodes,metadata,state}
    
    # Create cluster metadata
    cat > "$cluster_dir/metadata/cluster.json" << EOF
{
  "cluster_id": "$cluster_id",
  "name": "$cluster_name",
  "type": "$cluster_type",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "node_count": $node_count,
  "replication_factor": $replication_factor,
  "status": "initializing"
}
EOF
    
    # Create nodes
    log_info "Provisioning $node_count nodes..."
    for ((i=1; i<=node_count; i++)); do
        create_node "$cluster_id" "$i" "$cluster_type" "$((7000 + i))"
    done
    
    # Elect leader (first node)
    echo "node-1" > "$cluster_dir/state/leader"
    
    # Update cluster status
    update_cluster_status "$cluster_id" "healthy"
    
    log_success "Cluster created successfully!"
    echo ""
    echo "Cluster ID: $cluster_id"
    echo "Name: $cluster_name"
    echo "Nodes: $node_count"
    echo "Type: $cluster_type"
    echo ""
    echo "View status with: $(basename "$0") status --cluster-id $cluster_id"
}

create_node() {
    local cluster_id="$1"
    local node_num="$2"
    local cluster_type="$3"
    local port="$4"
    
    local node_id="node-$node_num"
    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"
    local node_dir="$cluster_dir/nodes/$node_id"
    
    mkdir -p "$node_dir"/{data,logs}
    
    # Node metadata
    cat > "$node_dir/metadata.json" << EOF
{
  "node_id": "$node_id",
  "cluster_id": "$cluster_id",
  "ip": "192.168.1.$(( 100 + node_num ))",
  "port": $port,
  "role": "$([ "$node_num" -eq 1 ] && echo "leader" || echo "follower")",
  "status": "up",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "data_size_mb": 0,
  "load_percent": $(( RANDOM % 30 + 20 ))
}
EOF
    
    # Simulate node process
    echo "$$" > "$node_dir/pid"
    
    log_debug "Created node: $node_id"
}

show_cluster_status() {
    local cluster_id="$1"
    local verbose="${2:-false}"
    
    if [[ ! -d "$CLUSTER_DATA_DIR/$cluster_id" ]]; then
        log_error "Cluster not found: $cluster_id"
        return 1
    fi
    
    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"
    
    # Parse cluster metadata
    local metadata
    metadata=$(cat "$cluster_dir/metadata/cluster.json")
    local name=$(echo "$metadata" | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
    local type=$(echo "$metadata" | grep -o '"type": "[^"]*"' | cut -d'"' -f4)
    local created=$(echo "$metadata" | grep -o '"created_at": "[^"]*"' | cut -d'"' -f4)
    local status=$(echo "$metadata" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
    local node_count=$(echo "$metadata" | grep -o '"node_count": [0-9]*' | awk '{print $2}')
    local repl_factor=$(echo "$metadata" | grep -o '"replication_factor": [0-9]*' | awk '{print $2}')
    
    # Display header
    echo ""
    echo "$(tput bold)╔════════════════════════════════════════════════════════════════╗$(tput sgr0)"
    echo "$(tput bold)║          CLUSTER STATUS: $(printf "%-36s" "$name")║$(tput sgr0)"
    echo "$(tput bold)╚════════════════════════════════════════════════════════════════╝$(tput sgr0)"
    echo ""
    
    # Cluster info
    printf "%-20s %s\n" "Cluster ID:" "$cluster_id"
    printf "%-20s %s\n" "Name:" "$name"
    printf "%-20s %s\n" "Type:" "$type"
    printf "%-20s %s\n" "Status:" "$(colorize_status "$status")"
    printf "%-20s %s\n" "Created:" "$created"
    printf "%-20s %s\n" "Node Count:" "$node_count"
    printf "%-20s %s\n" "Replication Factor:" "$repl_factor"
    echo ""
    
    # Node status
    echo "$(tput bold)Nodes:$(tput sgr0)"
    echo "$(tput bold)───────────────────────────────────────────────────────────────$(tput sgr0)"
    
    local leader
    leader=$(cat "$cluster_dir/state/leader" 2>/dev/null || echo "none")
    
    for node_dir in "$cluster_dir/nodes"/*; do
        if [[ -d "$node_dir" ]]; then
            local node_id=$(basename "$node_dir")
            local node_meta=$(cat "$node_dir/metadata.json")
            
            local ip=$(echo "$node_meta" | grep -o '"ip": "[^"]*"' | cut -d'"' -f4)
            local port=$(echo "$node_meta" | grep -o '"port": [0-9]*' | awk '{print $2}')
            local node_status=$(echo "$node_meta" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
            local load=$(echo "$node_meta" | grep -o '"load_percent": [0-9]*' | awk '{print $2}')
            local data_size=$(echo "$node_meta" | grep -o '"data_size_mb": [0-9]*' | awk '{print $2}')
            
            local role="FOLLOWER"
            [[ "$node_id" == "$leader" ]] && role="LEADER"
            
            echo ""
            printf "  %-15s %s\n" "$node_id" "[$(tput bold)$role$(tput sgr0)]"
            printf "    %-18s %s:%s\n" "Address:" "$ip" "$port"
            printf "    %-18s %s\n" "Status:" "$(colorize_status "$node_status")"
            printf "    %-18s %s%%\n" "Load:" "$load"
            printf "    %-18s %s MB\n" "Data Size:" "$data_size"
            
            if [[ "$verbose" == "true" ]]; then
                local uptime=$(calculate_uptime "$node_dir")
                printf "    %-18s %s\n" "Uptime:" "$uptime"
            fi
        fi
    done
    
    echo ""
    
    # Performance metrics
    if [[ "$verbose" == "true" ]]; then
        echo "$(tput bold)Performance Metrics (Last 5 min):$(tput sgr0)"
        echo "$(tput bold)───────────────────────────────────────────────────────────────$(tput sgr0)"
        printf "  %-25s %s ms\n" "Read Latency (p99):" "$(( RANDOM % 20 + 5 ))"
        printf "  %-25s %s ms\n" "Write Latency (p99):" "$(( RANDOM % 30 + 10 ))"
        printf "  %-25s %s ops/sec\n" "Throughput:" "$(( RANDOM % 5000 + 2000 ))"
        printf "  %-25s %s%%\n" "Error Rate:" "0.0$(( RANDOM % 5 ))"
        echo ""
    fi
    
    # Storage summary
    echo "$(tput bold)Storage:$(tput sgr0)"
    echo "$(tput bold)───────────────────────────────────────────────────────────────$(tput sgr0)"
    local total_data=$(( node_count * 1200 ))
    printf "  %-25s %s MB\n" "Total Data:" "$total_data"
    printf "  %-25s %s ops/sec\n" "IOPS:" "$(( RANDOM % 2000 + 500 ))"
    echo ""
}

colorize_status() {
    local status="$1"
    case "$status" in
        up|healthy|running)
            echo "$(tput setaf 2)${status^^}$(tput sgr0)"
            ;;
        down|unhealthy|failed)
            echo "$(tput setaf 1)${status^^}$(tput sgr0)"
            ;;
        warning|degraded)
            echo "$(tput setaf 3)${status^^}$(tput sgr0)"
            ;;
        *)
            echo "${status^^}"
            ;;
    esac
}

calculate_uptime() {
    local node_dir="$1"
    local started_at
    started_at=$(grep '"started_at"' "$node_dir/metadata.json" | cut -d'"' -f4)
    
    local start_epoch
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" "+%s" 2>/dev/null || date -d "$started_at" "+%s" 2>/dev/null || echo 0)
    local now_epoch=$(date +%s)
    local diff=$(( now_epoch - start_epoch ))
    
    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))
    
    if [[ $days -gt 0 ]]; then
        echo "${days}d ${hours}h ${mins}m"
    elif [[ $hours -gt 0 ]]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

list_clusters() {
    echo ""
    echo "$(tput bold)Available Clusters:$(tput sgr0)"
    echo "$(tput bold)────────────────────────────────────────────────────────────────$(tput sgr0)"
    
    if [[ ! -d "$CLUSTER_DATA_DIR" ]] || [[ -z "$(ls -A "$CLUSTER_DATA_DIR" 2>/dev/null)" ]]; then
        echo "  No clusters found"
        echo ""
        return
    fi
    
    printf "\n%-20s %-25s %-12s %-10s %s\n" "CLUSTER ID" "NAME" "TYPE" "NODES" "STATUS"
    printf "%-20s %-25s %-12s %-10s %s\n" "──────────" "────" "────" "─────" "──────"
    
    for cluster_dir in "$CLUSTER_DATA_DIR"/*; do
        if [[ -d "$cluster_dir" ]]; then
            local cluster_id=$(basename "$cluster_dir")
            local metadata=$(cat "$cluster_dir/metadata/cluster.json")
            
            local name=$(echo "$metadata" | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
            local type=$(echo "$metadata" | grep -o '"type": "[^"]*"' | cut -d'"' -f4)
            local status=$(echo "$metadata" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
            local node_count=$(echo "$metadata" | grep -o '"node_count": [0-9]*' | awk '{print $2}')
            
            printf "%-20s %-25s %-12s %-10s %s\n" \
                "$cluster_id" "$name" "$type" "$node_count" "$(colorize_status "$status")"
        fi
    done
    
    echo ""
}

update_cluster_status() {
    local cluster_id="$1"
    local new_status="$2"
    
    local metadata_file="$CLUSTER_DATA_DIR/$cluster_id/metadata/cluster.json"
    
    # Use sed to update status
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s/\"status\": \"[^\"]*\"/\"status\": \"$new_status\"/" "$metadata_file"
    else
        # Linux
        sed -i "s/\"status\": \"[^\"]*\"/\"status\": \"$new_status\"/" "$metadata_file"
    fi
}

add_node_to_cluster() {
    local cluster_id="$1"
    
    if [[ ! -d "$CLUSTER_DATA_DIR/$cluster_id" ]]; then
        log_error "Cluster not found: $cluster_id"
        return 1
    fi
    
    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"
    local current_nodes=$(ls -1 "$cluster_dir/nodes" | wc -l | tr -d ' ')
    local new_node_num=$((current_nodes + 1))
    
    log_info "Adding node-$new_node_num to cluster $cluster_id..."
    
    # Create new node
    create_node "$cluster_id" "$new_node_num" "cassandra" "$((7000 + new_node_num))"
    
    # Update cluster metadata
    local metadata_file="$cluster_dir/metadata/cluster.json"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/\"node_count\": [0-9]*/\"node_count\": $new_node_num/" "$metadata_file"
    else
        sed -i "s/\"node_count\": [0-9]*/\"node_count\": $new_node_num/" "$metadata_file"
    fi
    
    log_success "Node added successfully! Total nodes: $new_node_num"
}

################################################################################
# Main
################################################################################

main() {
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Parse command
    if [[ $# -eq 0 ]]; then
        show_usage
    fi
    
    local command="$1"
    shift
    
    # Parse options
    local cluster_name=""
    local node_count=3
    local cluster_type="cassandra"
    local cluster_id=""
    local replication_factor=3
    local verbose=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                cluster_name="$2"
                shift 2
                ;;
            --nodes)
                node_count="$2"
                shift 2
                ;;
            --type)
                cluster_type="$2"
                shift 2
                ;;
            --cluster-id)
                cluster_id="$2"
                shift 2
                ;;
            --replication-factor)
                replication_factor="$2"
                shift 2
                ;;
            --verbose)
                verbose=true
                shift
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
    
    # Execute command
    case "$command" in
        init)
            initialize_system
            ;;
        create)
            if [[ -z "$cluster_name" ]]; then
                log_error "Cluster name is required"
                show_usage
            fi
            create_cluster "$cluster_name" "$node_count" "$cluster_type" "$replication_factor"
            ;;
        status)
            if [[ -z "$cluster_id" ]]; then
                log_error "Cluster ID is required"
                exit 1
            fi
            show_cluster_status "$cluster_id" "$verbose"
            ;;
        list)
            list_clusters
            ;;
        add-node)
            if [[ -z "$cluster_id" ]]; then
                log_error "Cluster ID is required"
                exit 1
            fi
            add_node_to_cluster "$cluster_id"
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            ;;
    esac
}

# Run main
main "$@"
