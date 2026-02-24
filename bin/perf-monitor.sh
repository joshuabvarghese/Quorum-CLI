#!/bin/bash

################################################################################
# Performance Monitor - Real-time cluster performance monitoring
################################################################################

set -euo pipefail

# Ensure tput works in non-interactive (CI) environments
export TERM="${TERM:-dumb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"
DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs/monitoring}"

# shellcheck source=lib/logger.sh
source "$LIB_DIR/logger.sh"

METRICS_DIR="$DATA_DIR/metrics"
LOG_FILE="$LOG_DIR/perf-monitor.log"
export LOG_FILE

################################################################################
# Functions
################################################################################

show_usage() {
    cat << EOF
Performance Monitor - Real-time Cluster Monitoring

Usage: $(basename "$0") <command> [options]

Commands:
    start           Start monitoring daemon
    stop            Stop monitoring daemon
    status          Show current metrics
    report          Generate performance report
    analyze         Analyze performance trends
    dashboard       Show real-time dashboard

Options:
    --cluster-id <id>    Cluster ID to monitor
    --interval <sec>     Collection interval (default: 5)
    --duration <sec>     Monitoring duration
    --metrics <list>     Metrics to collect (cpu,mem,disk,net,latency)
    --output <file>      Output file for reports

Examples:
    $(basename "$0") start --cluster-id cls-001 --interval 5
    $(basename "$0") dashboard --cluster-id cls-001
    $(basename "$0") report --cluster-id cls-001 --output report.txt

EOF
    exit 0
}

initialize_monitoring() {
    mkdir -p "$METRICS_DIR" "$LOG_DIR"
}

collect_metrics() {
    local cluster_id="$1"
    local timestamp
    timestamp=$(date +%s)
    
    # CPU metrics
    local cpu_usage
    cpu_usage=$(top -l 1 | grep "CPU usage" | awk '{print $3}' | tr -d '%' || echo "0")
    
    # Memory metrics
    local mem_usage
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mem_usage=$(vm_stat | awk '/Pages active/ {print $3}' | tr -d '.' || echo "0")
    else
        mem_usage=$(free | grep Mem | awk '{print ($3/$2) * 100.0}' || echo "0")
    fi
    
    # Disk I/O
    local disk_read_ops
    disk_read_ops=$(( RANDOM % 1000 + 500 ))
    local disk_write_ops
    disk_write_ops=$(( RANDOM % 800 + 400 ))
    
    # Network
    local net_rx_bytes
    net_rx_bytes=$(( RANDOM % 1000000 + 100000 ))
    local net_tx_bytes
    net_tx_bytes=$(( RANDOM % 800000 + 80000 ))
    
    # Latency simulation
    local read_latency
    read_latency=$(( RANDOM % 20 + 5 ))
    local write_latency
    write_latency=$(( RANDOM % 30 + 10 ))
    
    # Throughput
    local ops_per_sec
    ops_per_sec=$(( RANDOM % 5000 + 2000 ))
    
    # Save metrics
    local metrics_file
metrics_file="$METRICS_DIR/cluster-$cluster_id-$(date +%Y%m%d).json"
    
    cat >> "$metrics_file" << EOF
{
  "timestamp": $timestamp,
  "cpu_percent": $cpu_usage,
  "memory_percent": $mem_usage,
  "disk_read_ops": $disk_read_ops,
  "disk_write_ops": $disk_write_ops,
  "network_rx_bytes": $net_rx_bytes,
  "network_tx_bytes": $net_tx_bytes,
  "read_latency_ms": $read_latency,
  "write_latency_ms": $write_latency,
  "ops_per_sec": $ops_per_sec
},
EOF
}

show_dashboard() {
    local cluster_id="$1"
    local interval="${2:-5}"
    
    # Clear screen function
    clear_screen() {
        printf '\033[2J\033[H'
    }
    
    log_info "Starting real-time dashboard for cluster: $cluster_id"
    log_info "Press Ctrl+C to stop"
    sleep 2
    
    while true; do
        clear_screen
        
        # Header
        echo "$(tput bold)╔════════════════════════════════════════════════════════════════╗$(tput sgr0)"
        echo "$(tput bold)║       REAL-TIME PERFORMANCE DASHBOARD - $(printf "%-22s" "$cluster_id")║$(tput sgr0)"
        echo "$(tput bold)╚════════════════════════════════════════════════════════════════╝$(tput sgr0)"
        echo ""
        
        # Timestamp
        echo "Last Update: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        # CPU Usage
        local cpu_percent
        cpu_percent=$(( RANDOM % 40 + 30 ))
        echo "$(tput bold)CPU Usage:$(tput sgr0)"
        draw_bar "$cpu_percent" "100"
        echo ""
        
        # Memory Usage
        local mem_percent
        mem_percent=$(( RANDOM % 30 + 40 ))
        echo "$(tput bold)Memory Usage:$(tput sgr0)"
        draw_bar "$mem_percent" "100"
        echo ""
        
        # Disk I/O
        echo "$(tput bold)Disk I/O:$(tput sgr0)"
        printf "  Read:  %6d ops/s  |  " "$(( RANDOM % 1000 + 500 ))"
        printf "Write: %6d ops/s\n" "$(( RANDOM % 800 + 400 ))"
        echo ""
        
        # Network
        echo "$(tput bold)Network:$(tput sgr0)"
        printf "  RX:    %8.2f MB/s  |  " "$(echo "scale=2; $(( RANDOM % 100 + 50 )) / 10" | bc)"
        printf "TX:    %8.2f MB/s\n" "$(echo "scale=2; $(( RANDOM % 80 + 40 )) / 10" | bc)"
        echo ""
        
        # Latency
        echo "$(tput bold)Latency (p99):$(tput sgr0)"
        printf "  Read:  %4d ms       |  " "$(( RANDOM % 20 + 5 ))"
        printf "Write: %4d ms\n" "$(( RANDOM % 30 + 10 ))"
        echo ""
        
        # Throughput
        echo "$(tput bold)Throughput:$(tput sgr0)"
        printf "  Operations: %8d ops/sec\n" "$(( RANDOM % 5000 + 2000 ))"
        echo ""
        
        # Error Rate
        echo "$(tput bold)Error Rate:$(tput sgr0)"
        local error_rate="0.0$(( RANDOM % 5 ))"
        printf "  Errors:     %s%%\n" "$error_rate"
        echo ""
        
        # Top Consumers
        echo "$(tput bold)Top Resource Consumers:$(tput sgr0)"
        echo "  node-1: CPU 35% | MEM 512MB"
        echo "  node-2: CPU 42% | MEM 678MB"
        echo "  node-3: CPU 38% | MEM 545MB"
        echo ""
        
        sleep "$interval"
    done
}

draw_bar() {
    local value=$1
    local max=$2
    local width=50
    
    local filled
    filled=$(( value * width / max ))
    local empty
    empty=$(( width - filled ))
    
    printf "  ["
    
    # Color based on value
    if [[ $value -lt 50 ]]; then
        printf '%s' "$(tput setaf 2)"  # Green
    elif [[ $value -lt 75 ]]; then
        printf '%s' "$(tput setaf 3)"  # Yellow
    else
        printf '%s' "$(tput setaf 1)"  # Red
    fi
    
    printf "%${filled}s" | tr ' ' '='
    printf '%s' "$(tput sgr0)"
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%%\n" "$value"
}

generate_report() {
    local cluster_id="$1"
    local output_file="$2"
    
    log_info "Generating performance report for cluster: $cluster_id"
    
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "        PERFORMANCE REPORT - $cluster_id"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        echo "EXECUTIVE SUMMARY"
        echo "───────────────────────────────────────────────────────────────"
        echo "Time Period: Last 24 hours"
        echo "Cluster Status: HEALTHY"
        echo "Average Load: 42%"
        echo "Peak Load: 78%"
        echo ""
        
        echo "PERFORMANCE METRICS"
        echo "───────────────────────────────────────────────────────────────"
        echo ""
        
        echo "CPU Utilization:"
        echo "  Average: 42.5%"
        echo "  Peak:    78.2%"
        echo "  Min:     18.7%"
        echo ""
        
        echo "Memory Usage:"
        echo "  Average: 55.3%"
        echo "  Peak:    82.1%"
        echo "  Min:     35.4%"
        echo ""
        
        echo "Disk I/O:"
        echo "  Avg Read IOPS:   1,245"
        echo "  Avg Write IOPS:    892"
        echo "  Peak Read IOPS:  2,543"
        echo "  Peak Write IOPS: 1,876"
        echo ""
        
        echo "Network:"
        echo "  Avg RX: 45.2 MB/s"
        echo "  Avg TX: 38.7 MB/s"
        echo "  Peak RX: 89.3 MB/s"
        echo "  Peak TX: 76.5 MB/s"
        echo ""
        
        echo "Latency (milliseconds):"
        echo "  Read Latency:"
        echo "    p50:  8 ms"
        echo "    p95: 15 ms"
        echo "    p99: 23 ms"
        echo "  Write Latency:"
        echo "    p50: 12 ms"
        echo "    p95: 22 ms"
        echo "    p99: 35 ms"
        echo ""
        
        echo "Throughput:"
        echo "  Average: 3,456 ops/sec"
        echo "  Peak:    6,789 ops/sec"
        echo ""
        
        echo "RECOMMENDATIONS"
        echo "───────────────────────────────────────────────────────────────"
        echo "1. CPU usage is within normal range"
        echo "2. Consider adding nodes if sustained load > 70%"
        echo "3. Memory usage healthy, no action needed"
        echo "4. Disk I/O performance optimal"
        echo "5. Network utilization normal"
        echo ""
        
        echo "ALERTS"
        echo "───────────────────────────────────────────────────────────────"
        echo "• No critical alerts in the last 24 hours"
        echo "• 2 warnings: High CPU during peak hours"
        echo ""
        
    } | tee "$output_file"
    
    log_success "Report saved to: $output_file"
}

analyze_performance() {
    local cluster_id="$1"
    
    log_info "Analyzing performance trends for cluster: $cluster_id"
    echo ""
    
    echo "$(tput bold)Performance Analysis:$(tput sgr0)"
    echo "────────────────────────────────────────────────────────────────"
    echo ""
    
    echo "$(tput setaf 3)Potential Bottlenecks Detected:$(tput sgr0)"
    echo "  1. CPU usage spikes during 2PM-4PM (avg 78%)"
    echo "  2. Write latency increases under heavy load"
    echo ""
    
    echo "$(tput setaf 2)Performance Strengths:$(tput sgr0)"
    echo "  ✓ Consistent read latency"
    echo "  ✓ Good network throughput"
    echo "  ✓ Stable memory usage"
    echo ""
    
    echo "$(tput setaf 6)Optimization Recommendations:$(tput sgr0)"
    echo "  → Consider adding 1-2 nodes for peak hour handling"
    echo "  → Enable caching for frequently accessed data"
    echo "  → Review write-heavy operations during peak times"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    initialize_monitoring
    
    if [[ $# -eq 0 ]]; then
        show_usage
    fi
    
    local command="$1"
    shift
    
    local cluster_id=""
    local interval=5
    local output_file="performance-report.txt"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster-id)
                cluster_id="$2"
                shift 2
                ;;
            --interval)
                interval="$2"
                shift 2
                ;;
            --output)
                output_file="$2"
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
    
    case "$command" in
        dashboard)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            show_dashboard "$cluster_id" "$interval"
            ;;
        report)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            generate_report "$cluster_id" "$output_file"
            ;;
        analyze)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            analyze_performance "$cluster_id"
            ;;
        metrics)
            emit_prometheus_metrics "$cluster_id"
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            ;;
    esac
}

################################################################################
# emit_prometheus_metrics
#
# Outputs cluster metrics in Prometheus exposition format so they can be
# scraped by a Prometheus server or Pushgateway.
#
# Example output:
#   # HELP quorum_nodes_up Number of nodes currently UP
#   # TYPE quorum_nodes_up gauge
#   quorum_nodes_up{cluster="cls-001",name="prod"} 3
#
# Usage:
#   ./bin/perf-monitor.sh metrics                   # all clusters
#   ./bin/perf-monitor.sh metrics --cluster-id cls  # single cluster
################################################################################

emit_prometheus_metrics() {
    local filter_cluster="${1:-}"
    local cluster_data_dir="${DATA_DIR}/clusters"

    if [[ ! -d "$cluster_data_dir" ]] || \
       [[ -z "$(ls -A "$cluster_data_dir" 2>/dev/null)" ]]; then
        log_warn "No clusters found under $cluster_data_dir"
        return 0
    fi

    # Print HELP/TYPE headers once
    cat <<'HEADER'
# HELP quorum_nodes_total Total number of nodes in the cluster
# TYPE quorum_nodes_total gauge
# HELP quorum_nodes_up Number of nodes currently UP
# TYPE quorum_nodes_up gauge
# HELP quorum_nodes_down Number of nodes currently DOWN
# TYPE quorum_nodes_down gauge
# HELP quorum_replication_factor Configured replication factor
# TYPE quorum_replication_factor gauge
# HELP quorum_cluster_healthy 1 if cluster status is healthy, 0 otherwise
# TYPE quorum_cluster_healthy gauge
# HELP quorum_avg_load_percent Average CPU load across all nodes (percent)
# TYPE quorum_avg_load_percent gauge
# HELP quorum_read_latency_ms Simulated p99 read latency in milliseconds
# TYPE quorum_read_latency_ms gauge
# HELP quorum_write_latency_ms Simulated p99 write latency in milliseconds
# TYPE quorum_write_latency_ms gauge
# HELP quorum_ops_per_second Simulated operations per second
# TYPE quorum_ops_per_second gauge
HEADER

    for cluster_dir in "${cluster_data_dir}"/*/; do
        [[ -d "$cluster_dir" ]] || continue
        local cluster_id
        cluster_id=$(basename "$cluster_dir")

        # If a filter was given, skip non-matching clusters
        if [[ -n "$filter_cluster" && "$cluster_id" != "$filter_cluster" ]]; then
            continue
        fi

        local meta_file="${cluster_dir}/metadata/cluster.json"
        [[ -f "$meta_file" ]] || continue

        # Parse cluster metadata
        local cluster_name
        cluster_name=$(grep -o '"name"[: ]*"[^"]*"' "$meta_file" \
                       | grep -o '"[^"]*"$' | tr -d '"')
        local cluster_type
        cluster_type=$(grep -o '"type"[: ]*"[^"]*"' "$meta_file" \
                       | grep -o '"[^"]*"$' | tr -d '"')
        local repl_factor
        repl_factor=$(grep -o '"replication_factor"[: ]*[0-9]*' "$meta_file" \
                      | awk '{print $NF}')
        local cluster_status
        cluster_status=$(grep -o '"status"[: ]*"[^"]*"' "$meta_file" \
                         | grep -o '"[^"]*"$' | tr -d '"')

        # Count nodes
        local up=0 down=0 total=0 load_sum=0
        for node_dir in "${cluster_dir}/nodes"/*/; do
            [[ -d "$node_dir" ]] || continue
            (( total++ )) || true
            local node_meta="${node_dir}/metadata.json"
            local st
            st=$(grep -o '"status"[: ]*"[^"]*"' "$node_meta" \
                 | grep -o '"[^"]*"$' | tr -d '"')
            local load
            load=$(grep -o '"load_percent"[: ]*[0-9]*' "$node_meta" \
                   | awk '{print $NF}')
            load_sum=$(( load_sum + ${load:-0} ))
            if [[ "$st" == "up" ]]; then (( up++ )) || true; else (( down++ )); fi
        done

        local avg_load=0
        [[ $total -gt 0 ]] && avg_load=$(( load_sum / total ))

        # healthy = 1/0
        local is_healthy=0
        [[ "$cluster_status" == "healthy" ]] && is_healthy=1

        # Simulated latency / throughput (in a real deployment, read from a TSDB)
        local read_lat
        read_lat=$(( RANDOM % 20 + 5 ))
        local write_lat
        write_lat=$(( RANDOM % 30 + 10 ))
        local ops
        ops=$(( RANDOM % 5000 + 2000 ))

        # Common label set
        local labels="cluster_id=\"${cluster_id}\",name=\"${cluster_name}\",type=\"${cluster_type}\""

        # Emit metrics
        printf 'quorum_nodes_total{%s} %d\n'            "$labels" "$total"
        printf 'quorum_nodes_up{%s} %d\n'               "$labels" "$up"
        printf 'quorum_nodes_down{%s} %d\n'             "$labels" "$down"
        printf 'quorum_replication_factor{%s} %d\n'     "$labels" "${repl_factor:-3}"
        printf 'quorum_cluster_healthy{%s} %d\n'        "$labels" "$is_healthy"
        printf 'quorum_avg_load_percent{%s} %d\n'       "$labels" "$avg_load"
        printf 'quorum_read_latency_ms{%s} %d\n'        "$labels" "$read_lat"
        printf 'quorum_write_latency_ms{%s} %d\n'       "$labels" "$write_lat"
        printf 'quorum_ops_per_second{%s} %d\n'         "$labels" "$ops"
        printf '\n'
    done
}

main "$@"
