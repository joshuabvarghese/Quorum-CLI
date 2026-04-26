#!/usr/bin/env bash

################################################################################
# Cluster Manager - Main cluster lifecycle management
# Manages distributed cluster creation, scaling, and monitoring
################################################################################

set -euo pipefail

# Ensure tput works in non-interactive (CI) environments
export TERM="${TERM:-dumb}"

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"
CONFIG_DIR="$PROJECT_ROOT/config"
DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs/cluster}"

# Source libraries
# shellcheck source=lib/logger.sh
source "$LIB_DIR/logger.sh"
# shellcheck source=lib/cluster-lib.sh
source "$LIB_DIR/cluster-lib.sh"

# Global variables
CLUSTER_DATA_DIR="$DATA_DIR/clusters"
LOG_FILE="$LOG_DIR/cluster-manager.log"
export LOG_FILE

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
    metrics                 Expose Prometheus-format metrics for a cluster
    server                  Run a simple REST API server (requires socat or nc)

Options:
    --name <name>           Cluster name
    --nodes <count>         Number of nodes
    --type <type>           Cluster type (cassandra|kafka|redis)
    --cluster-id <id>       Cluster ID
    --node-id <id>          Node ID
    --replication-factor <n> Replication factor (default: 3)
    --port <n>              Port for --server mode (default: 9099)
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
    
    # Idempotency guard: refuse to silently create duplicate cluster names
    if [[ -d "$CLUSTER_DATA_DIR" ]]; then
        for _existing_dir in "$CLUSTER_DATA_DIR"/*/; do
            [[ -d "$_existing_dir" ]] || continue
            local _existing_meta="$_existing_dir/metadata/cluster.json"
            [[ -f "$_existing_meta" ]] || continue
            local _existing_name
            _existing_name=$(grep -o '"name": "[^"]*"' "$_existing_meta" | cut -d'"' -f4)
            if [[ "$_existing_name" == "$cluster_name" ]]; then
                local _existing_id
                _existing_id=$(basename "$_existing_dir")
                log_error "Cluster '${cluster_name}' already exists (ID: ${_existing_id})"
                echo "  To replace it:  $(basename "$0") destroy --cluster-id ${_existing_id}" >&2
                return 1
            fi
        done
    fi

    log_info "Creating cluster: $cluster_name"
    log_info "Type: $cluster_type, Nodes: $node_count, Replication: $replication_factor"
    
    # Generate cluster ID
    local cluster_id
    cluster_id="cls-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo "$RANDOM")"
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
    
    # Create nodes in parallel — background each create_node call,
    # collect PIDs, then wait for all to complete before proceeding.
    # This cuts provisioning time from O(N*serial) to O(1*parallel).
    log_info "Provisioning $node_count nodes in parallel..."
    local -a _node_pids=()
    for ((i=1; i<=node_count; i++)); do
        create_node "$cluster_id" "$i" "$cluster_type" "$((7000 + i))" &
        _node_pids+=($!)
    done
    # Wait for every provisioning job; surface any failures
    for _pid in "${_node_pids[@]}"; do
        wait "$_pid" || { log_error "Node provisioning job $_pid failed"; return 1; }
    done
    
    # Elect leader (first node)
    echo "node-1" > "$cluster_dir/state/leader"
    
    # Update cluster status
    update_cluster_status "$cluster_id" "healthy"
    
    log_success "Cluster created successfully!"
    echo ""
    echo "Cluster created successfully!"
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
    local name
    name=$(echo "$metadata" | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
    local type
    type=$(echo "$metadata" | grep -o '"type": "[^"]*"' | cut -d'"' -f4)
    local created
    created=$(echo "$metadata" | grep -o '"created_at": "[^"]*"' | cut -d'"' -f4)
    local status
    status=$(echo "$metadata" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
    local node_count
    node_count=$(echo "$metadata" | grep -o '"node_count": [0-9]*' | awk '{print $2}')
    local repl_factor
    repl_factor=$(echo "$metadata" | grep -o '"replication_factor": [0-9]*' | awk '{print $2}')
    
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
            local node_id
            node_id=$(basename "$node_dir")
            local node_meta
            node_meta=$(cat "$node_dir/metadata.json")
            
            local ip
            ip=$(echo "$node_meta" | grep -o '"ip": "[^"]*"' | cut -d'"' -f4)
            local port
            port=$(echo "$node_meta" | grep -o '"port": [0-9]*' | awk '{print $2}')
            local node_status
            node_status=$(echo "$node_meta" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
            local load
            load=$(echo "$node_meta" | grep -o '"load_percent": [0-9]*' | awk '{print $2}')
            local data_size
            data_size=$(echo "$node_meta" | grep -o '"data_size_mb": [0-9]*' | awk '{print $2}')
            
            local role="FOLLOWER"
            [[ "$node_id" == "$leader" ]] && role="LEADER"
            
            echo ""
            printf "  %-15s %s\n" "$node_id" "[$(tput bold)$role$(tput sgr0)]"
            printf "    %-18s %s:%s\n" "Address:" "$ip" "$port"
            printf "    %-18s %s\n" "Status:" "$(colorize_status "$node_status")"
            printf "    %-18s %s%%\n" "Load:" "$load"
            printf "    %-18s %s MB\n" "Data Size:" "$data_size"
            
            if [[ "$verbose" == "true" ]]; then
                local uptime
                uptime=$(calculate_uptime "$node_dir")
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
    local total_data
    total_data=$(( node_count * 1200 ))
    printf "  %-25s %s MB\n" "Total Data:" "$total_data"
    printf "  %-25s %s ops/sec\n" "IOPS:" "$(( RANDOM % 2000 + 500 ))"
    echo ""
}

colorize_status() {
    local status="$1"
    case "$status" in
        up|healthy|running)
            echo "$(tput setaf 2)$(echo "$status" | tr "[:lower:]" "[:upper:]")$(tput sgr0)"
            ;;
        down|unhealthy|failed)
            echo "$(tput setaf 1)$(echo "$status" | tr "[:lower:]" "[:upper:]")$(tput sgr0)"
            ;;
        warning|degraded)
            echo "$(tput setaf 3)$(echo "$status" | tr "[:lower:]" "[:upper:]")$(tput sgr0)"
            ;;
        *)
            echo "$(echo "$status" | tr "[:lower:]" "[:upper:]")"
            ;;
    esac
}

calculate_uptime() {
    local node_dir="$1"
    local started_at
    started_at=$(grep '"started_at"' "$node_dir/metadata.json" | cut -d'"' -f4)
    
    local start_epoch
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" "+%s" 2>/dev/null || date -d "$started_at" "+%s" 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local diff
    diff=$(( now_epoch - start_epoch ))
    
    local days
    days=$(( diff / 86400 ))
    local hours
    hours=$(( (diff % 86400) / 3600 ))
    local mins
    mins=$(( (diff % 3600) / 60 ))
    
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
            local cluster_id
            cluster_id=$(basename "$cluster_dir")
            local metadata
            metadata=$(cat "$cluster_dir/metadata/cluster.json")
            
            local name
            name=$(echo "$metadata" | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
            local type
            type=$(echo "$metadata" | grep -o '"type": "[^"]*"' | cut -d'"' -f4)
            local status
            status=$(echo "$metadata" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
            local node_count
            node_count=$(echo "$metadata" | grep -o '"node_count": [0-9]*' | awk '{print $2}')
            
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

# add_nodes_parallel <cluster_id> <count>
# Provisions <count> new nodes in parallel using background subshells,
# then waits for all jobs before updating cluster metadata.
# This is the engine behind both add-node and scale.
add_nodes_parallel() {
    local cluster_id="$1"
    local count="${2:-1}"

    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"
    local current_nodes
    current_nodes=$(find "$cluster_dir/nodes" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')

    log_info "Provisioning $count new node(s) in parallel (current total: $current_nodes)..."

    local -a _pids=()
    for (( i=1; i<=count; i++ )); do
        local new_node_num=$(( current_nodes + i ))
        create_node "$cluster_id" "$new_node_num" "cassandra" "$((7000 + new_node_num))" &
        _pids+=($!)
    done

    # Wait for all provisioning jobs
    for _pid in "${_pids[@]}"; do
        wait "$_pid" || { log_error "Node provisioning job $_pid failed"; return 1; }
    done

    local final_count=$(( current_nodes + count ))
    local metadata_file="$cluster_dir/metadata/cluster.json"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/\"node_count\": [0-9]*/\"node_count\": $final_count/" "$metadata_file"
    else
        sed -i "s/\"node_count\": [0-9]*/\"node_count\": $final_count/" "$metadata_file"
    fi

    log_success "Done. Cluster now has $final_count node(s)"
}

add_node_to_cluster() {
    local cluster_id="$1"
    local count="${2:-1}"

    if [[ ! -d "$CLUSTER_DATA_DIR/$cluster_id" ]]; then
        log_error "Cluster not found: $cluster_id"
        return 1
    fi

    add_nodes_parallel "$cluster_id" "$count"
}

################################################################################
# emit_prometheus_metrics — output cluster metrics in Prometheus text format
#
# Prometheus exposition format (text/plain; version=0.0.4):
#   # HELP <metric> <description>
#   # TYPE <metric> <type>
#   <metric>{<labels>} <value>
#
# To scrape ad-hoc:
#   ./bin/cluster-manager.sh metrics --cluster-id cls-001 > /tmp/metrics
#   # Or serve once over HTTP on port 9101:
#   ./bin/cluster-manager.sh metrics --cluster-id cls-001 \
#       | nc -l -p 9101 -q1   # Linux
#
# Metrics exposed:
#   quorum_cluster_health          1=healthy 0=degraded/unhealthy
#   quorum_nodes_total             number of nodes configured
#   quorum_nodes_healthy           nodes currently reporting status=up
#   quorum_leader_elections_total  monotonic counter (increments each run)
################################################################################

emit_prometheus_metrics() {
    local cluster_id="$1"

    if [[ ! -d "$CLUSTER_DATA_DIR/$cluster_id" ]]; then
        log_error "Cluster not found: $cluster_id"
        return 1
    fi

    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"
    local meta
    meta=$(cat "$cluster_dir/metadata/cluster.json")

    local cluster_name
    cluster_name=$(echo "$meta" | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
    local cluster_type
    cluster_type=$(echo "$meta" | grep -o '"type": "[^"]*"' | cut -d'"' -f4)
    local cluster_status
    cluster_status=$(echo "$meta" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
    local node_count
    node_count=$(echo "$meta" | grep -o '"node_count": [0-9]*' | awk '{print $2}')

    # Count healthy (status=up) nodes from filesystem state
    local healthy_nodes=0
    for node_dir in "$cluster_dir/nodes"/*/; do
        [[ -d "$node_dir" ]] || continue
        local nstatus
        nstatus=$(grep -o '"status": "[^"]*"' "$node_dir/metadata.json" \
                  | grep -o '"[^"]*"$' | tr -d '"')
        [[ "$nstatus" == "up" ]] && (( healthy_nodes++ )) || true
    done

    # Derive health gauge: 1=healthy, 0.5=degraded, 0=unhealthy
    local health_value
    case "$cluster_status" in
        healthy)   health_value=1 ;;
        degraded)  health_value=0.5 ;;
        *)         health_value=0 ;;
    esac

    # Leader-election counter: persist across calls in state dir
    local election_file="$cluster_dir/state/leader_elections"
    local elections=0
    if [[ -f "$election_file" ]]; then
        elections=$(cat "$election_file")
    fi
    # Increment each time metrics are scraped (simulates election telemetry)
    echo $(( elections + 1 )) > "$election_file"
    elections=$(( elections + 1 ))

    # Quorum majority threshold
    local quorum_threshold=$(( node_count / 2 + 1 ))

    local labels="cluster=\"${cluster_name}\",type=\"${cluster_type}\",id=\"${cluster_id}\""

    cat << EOF
# HELP quorum_cluster_health Cluster health: 1=healthy, 0.5=degraded, 0=unhealthy
# TYPE quorum_cluster_health gauge
quorum_cluster_health{${labels}} ${health_value}

# HELP quorum_nodes_total Total number of nodes configured in the cluster
# TYPE quorum_nodes_total gauge
quorum_nodes_total{${labels}} ${node_count}

# HELP quorum_nodes_healthy Number of nodes currently reporting status=up
# TYPE quorum_nodes_healthy gauge
quorum_nodes_healthy{${labels}} ${healthy_nodes}

# HELP quorum_nodes_down Number of nodes currently reporting status=down
# TYPE quorum_nodes_down gauge
quorum_nodes_down{${labels}} $(( node_count - healthy_nodes ))

# HELP quorum_quorum_threshold Minimum nodes required for quorum (floor(n/2)+1)
# TYPE quorum_quorum_threshold gauge
quorum_quorum_threshold{${labels}} ${quorum_threshold}

# HELP quorum_has_quorum 1 if healthy nodes meet quorum threshold, 0 otherwise
# TYPE quorum_has_quorum gauge
quorum_has_quorum{${labels}} $(( healthy_nodes >= quorum_threshold ? 1 : 0 ))

# HELP quorum_leader_elections_total Monotonic count of leader election events observed
# TYPE quorum_leader_elections_total counter
quorum_leader_elections_total{${labels}} ${elections}

# HELP quorum_scrape_timestamp_seconds Unix timestamp of this scrape
# TYPE quorum_scrape_timestamp_seconds gauge
quorum_scrape_timestamp_seconds{${labels}} $(date +%s)
EOF
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
    local api_port=9099
    
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
            --port)
                api_port="$2"
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
            add_node_to_cluster "$cluster_id" "1"
            ;;
        scale)
            if [[ -z "$cluster_id" ]]; then
                log_error "Cluster ID is required"
                exit 1
            fi
            local _current_count
            _current_count=$(find "$CLUSTER_DATA_DIR/$cluster_id/nodes" \
                -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$node_count" -le "$_current_count" ]]; then
                log_error "Target node count ($node_count) must exceed current ($_current_count). Use remove-node to scale down."
                exit 1
            fi
            local _add_count=$(( node_count - _current_count ))
            log_info "Scaling cluster from $_current_count → $node_count nodes (adding $_add_count)"
            add_node_to_cluster "$cluster_id" "$_add_count"
            ;;
        metrics)
            if [[ -z "$cluster_id" ]]; then
                log_error "Cluster ID is required"
                exit 1
            fi
            emit_prometheus_metrics "$cluster_id"
            ;;
        nodetool-status)
            if [[ -z "$cluster_id" ]]; then
                log_error "Cluster ID is required"
                exit 1
            fi
            nodetool_status "$cluster_id"
            ;;
        token-ranges)
            if [[ -z "$cluster_id" ]]; then
                log_error "Cluster ID is required"
                exit 1
            fi
            cassandra_token_ranges "$cluster_id"
            ;;
        server)
            api_server "$api_port"
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            ;;
    esac
}

################################################################################
# nodetool_status — Cassandra nodetool-style ring view
#
# Modelled after `nodetool status` output so that engineers who work on
# Instaclustr's managed Cassandra service will immediately recognise the
# format.  In a real deployment this would call `nodetool status` via SSH;
# here it reads the cluster state files to produce the same information.
#
# Output format mirrors Cassandra's:
#   Datacenter: datacenter1
#   ========================
#   Status=Up/Down
#   |/ State=Normal/Leaving/Joining/Moving
#   --  Address        Load       Owns (effective)  Host ID   Token  Rack
#   UN  192.168.1.101  ?          66.7%             uuid...   -9223..  rack1
#
# Usage:
#   ./bin/cluster-manager.sh nodetool-status --cluster-id cls-001
################################################################################

nodetool_status() {
    local cluster_id="$1"

    if [[ ! -d "$CLUSTER_DATA_DIR/$cluster_id" ]]; then
        log_error "Cluster not found: $cluster_id"
        return 1
    fi

    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"
    local meta
    meta=$(cat "$cluster_dir/metadata/cluster.json")

    local cluster_type
    cluster_type=$(echo "$meta" | grep -o '"type"[: ]*"[^"]*"' \
                   | grep -o '"[^"]*"$' | tr -d '"')
    local node_count
    node_count=$(find "$cluster_dir/nodes" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')

    echo ""
    echo "Note: Cassandra-compatible ring view (modelled after \`nodetool status\`)"
    echo "      In production this reads live gossip state via nodetool."
    echo ""
    echo "Datacenter: datacenter1"
    echo "========================"
    echo "Status=Up/Down"
    echo "|/ State=Normal/Leaving/Joining/Moving"
    printf "%-4s %-15s %-12s %-20s %-10s %-14s %s\n" \
        "--" "Address" "Load" "Owns (effective)" "Host ID" "Token" "Rack"

    local token_base=-9223372036854775808
    local owns_each
    owns_each=$(( 100 / node_count ))

    local leader
    leader=$(cat "$cluster_dir/state/leader" 2>/dev/null || echo "node-1")

    for node_dir in "$cluster_dir/nodes"/*/; do
        [[ -d "$node_dir" ]] || continue
        local node_meta="$node_dir/metadata.json"
        local node_id
        node_id=$(basename "$node_dir")

        local ip
        ip=$(grep -o '"ip"[: ]*"[^"]*"' "$node_meta" \
             | grep -o '"[^"]*"$' | tr -d '"')
        local status
        status=$(grep -o '"status"[: ]*"[^"]*"' "$node_meta" \
                 | grep -o '"[^"]*"$' | tr -d '"')
        local load
        load=$(grep -o '"data_size_mb"[: ]*[0-9]*' "$node_meta" \
               | awk '{print $NF}')

        # Status/State code: UN = Up/Normal, DN = Down/Normal
        local code="DN"
        [[ "$status" == "up" ]] && code="UN"

        # Fake but deterministic host UUID based on IP
        local host_id
        host_id=$(printf "%s" "${ip}" | md5sum 2>/dev/null | cut -c1-8 || \
                  printf "%08x" "$(( ${ip##*.} * 1234567 ))")

        # Token ring: evenly spaced tokens
        local node_num="${node_id##node-}"
        local token
        token=$(( token_base + node_num * ( 9223372036854775807 / node_count ) ))

        # Mark leader with an asterisk
        local rack="rack1"
        [[ "$node_id" == "$leader" ]] && rack="rack1 *leader"

        printf "%-4s %-15s %-12s %-20s %-10s %-14s %s\n" \
            "$code" "$ip" "${load:-0} MB" "${owns_each}.0%" \
            "${host_id}..." "${token:0:10}" "$rack"
    done
    echo ""
}

################################################################################
# cassandra_token_ranges — print token range ownership (ring topology)
#
# Cassandra distributes data across the ring using consistent hashing.
# This function prints the token ranges owned by each node — useful for
# diagnosing hot partitions and verifying even data distribution.
################################################################################

cassandra_token_ranges() {
    local cluster_id="$1"
    local cluster_dir="$CLUSTER_DATA_DIR/$cluster_id"

    [[ -d "$cluster_dir" ]] || { log_error "Cluster not found: $cluster_id"; return 1; }

    local nodes
    nodes=$(find "$cluster_dir/nodes" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" 2>/dev/null | sort)
    local node_count
    node_count=$(echo "$nodes" | wc -l | tr -d ' ')
    local range_size
    range_size=$(( 18446744073709551615 / node_count ))

    echo ""
    echo "Token Ring — Ownership by Node"
    echo "Range size: ${range_size} tokens per node"
    printf "%-12s %-22s %-22s %s\n" "Node" "Token Start" "Token End" "Owns"
    echo "────────────────────────────────────────────────────────────────"

    local idx=0
    while IFS= read -r node_id; do
        local start
        start=$(( idx * range_size ))
        local end
        end=$(( (idx + 1) * range_size - 1 ))
        printf "%-12s %-22s %-22s %s%%\n" \
            "$node_id" "$start" "$end" "$(( 100 / node_count ))"
        (( idx++ ))
    done <<< "$nodes"
    echo ""
}

################################################################################
# api_server — minimal HTTP/1.0 REST API served via socat (or nc fallback)
#
# Protocol: HTTP/1.0 plain-text.  No TLS termination here — put nginx/haproxy
# in front for production.  Each request is handled by a subshell; socat
# forks per-connection so requests are effectively concurrent.
#
# Endpoints:
#   GET /healthz                    Liveness probe (always 200 OK)
#   GET /clusters                   List clusters (JSON array)
#   GET /clusters/<id>/status       Cluster status (JSON)
#   GET /clusters/<id>/metrics      Prometheus metrics (text/plain)
#   POST /clusters/<id>/add-node    Add one node (JSON response)
#
# Usage:
#   ./bin/cluster-manager.sh server --port 9099
#   curl http://localhost:9099/healthz
#   curl http://localhost:9099/clusters
#   curl http://localhost:9099/clusters/cls-001/metrics
################################################################################

_http_200() {
    local content_type="${1:-application/json}"
    local body="$2"
    printf "HTTP/1.0 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$content_type" "${#body}" "$body"
}

_http_404() {
    local body=\'{"error":"not found"}\'
    printf "HTTP/1.0 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "${#body}" "$body"
}

_http_400() {
    local body="{\"error\":\"$1\"}"
    printf "HTTP/1.0 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "${#body}" "$body"
}

_api_handle_request() {
    # Read the HTTP request line from stdin (socat pipes it here)
    local request_line
    IFS= read -r request_line
    request_line="${request_line%$'\r'}"  # strip CR

    local method path
    method=$(echo "$request_line" | awk \'{ print $1 }\')
    path=$(echo "$request_line"   | awk \'{ print $2 }\')

    # Drain headers (we don\'t use them but must consume before writing response)
    while IFS= read -r header && [[ "$header" != $\'\r\' ]] && [[ -n "$header" ]]; do :; done

    case "$path" in
        /healthz)
            _http_200 "text/plain" "OK"
            ;;

        /clusters)
            local json="["
            local first=true
            if [[ -d "$CLUSTER_DATA_DIR" ]]; then
                for _cdir in "$CLUSTER_DATA_DIR"/*/; do
                    [[ -d "$_cdir" ]] || continue
                    local _cmeta="$_cdir/metadata/cluster.json"
                    [[ -f "$_cmeta" ]] || continue
                    $first || json+=","
                    json+=$(cat "$_cmeta")
                    first=false
                done
            fi
            json+="]"
            _http_200 "application/json" "$json"
            ;;

        /clusters/*/status)
            local cid="${path#/clusters/}"
            cid="${cid%/status}"
            if [[ ! -d "$CLUSTER_DATA_DIR/$cid" ]]; then
                _http_404
            else
                local body
                body=$(cat "$CLUSTER_DATA_DIR/$cid/metadata/cluster.json")
                _http_200 "application/json" "$body"
            fi
            ;;

        /clusters/*/metrics)
            local cid="${path#/clusters/}"
            cid="${cid%/metrics}"
            if [[ ! -d "$CLUSTER_DATA_DIR/$cid" ]]; then
                _http_404
            else
                local body
                body=$(emit_prometheus_metrics "$cid" 2>/dev/null)
                _http_200 "text/plain; version=0.0.4" "$body"
            fi
            ;;

        /clusters/*/add-node)
            if [[ "$method" != "POST" ]]; then
                _http_400 "method must be POST"
                return
            fi
            local cid="${path#/clusters/}"
            cid="${cid%/add-node}"
            if [[ ! -d "$CLUSTER_DATA_DIR/$cid" ]]; then
                _http_404
            else
                add_node_to_cluster "$cid" "1" &>/dev/null
                local body
                body=$(cat "$CLUSTER_DATA_DIR/$cid/metadata/cluster.json")
                _http_200 "application/json" "$body"
            fi
            ;;

        *)
            _http_404
            ;;
    esac
}

api_server() {
    local port="${1:-9099}"

    # Prefer socat (supports concurrent connections via fork);
    # fall back to a serial nc loop if socat is absent.
    if command -v socat &>/dev/null; then
        log_info "API server listening on port $port (socat)"
        log_info "Endpoints: /healthz  /clusters  /clusters/<id>/status"
        log_info "           /clusters/<id>/metrics  POST /clusters/<id>/add-node"
        # Export everything _api_handle_request needs
        export -f _api_handle_request _http_200 _http_404 _http_400
        export -f emit_prometheus_metrics add_node_to_cluster add_nodes_parallel
        export -f create_node update_cluster_status log_info log_warn log_error log_success log_debug
        export CLUSTER_DATA_DIR DATA_DIR
        socat TCP-LISTEN:"$port",reuseaddr,fork \
            EXEC:"bash -c _api_handle_request",pty,raw,echo=0
    else
        # nc serial fallback (one request at a time — fine for demos)
        log_warn "socat not found — using nc serial mode (install socat for concurrent requests)"
        log_info "API server listening on port $port (nc fallback)"
        while true; do
            _api_handle_request | nc -l "$port" -q1 2>/dev/null || true
        done
    fi
}

# Run main
main "$@"
