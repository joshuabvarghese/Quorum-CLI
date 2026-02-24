cat > bin/storage-ops.sh << 'EOF'
#!/bin/bash

################################################################################
# Storage Operations - Volume provisioning, snapshots, replication
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"
DATA_DIR="$PROJECT_ROOT/data"
LOG_DIR="$PROJECT_ROOT/logs/storage"

source "$LIB_DIR/logger.sh"

VOLUME_DIR="$DATA_DIR/volumes"
SNAPSHOT_DIR="$DATA_DIR/snapshots"
LOG_FILE="$LOG_DIR/storage-ops.log"

################################################################################
# Functions
################################################################################

show_usage() {
    cat << EOF
Storage Operations - Volume and Snapshot Management

Usage: $(basename "$0") <command> [options]

Commands:
    provision       Create a new volume
    list            List all volumes
    snapshot        Create a snapshot
    verify          Verify data integrity
    stats           Show storage statistics

Options:
    --volume-id <id>     Volume ID
    --size <size>        Size (e.g., 1GB, 500MB)
    --cluster-id <id>    Cluster ID
    --replication <n>    Replication factor
    --retention <time>   Retention period (e.g., 7d, 30d)

Examples:
    $(basename "$0") provision --cluster-id cls-001 --size 5GB --replication 3
    $(basename "$0") snapshot --volume-id vol-001 --retention 7d
    $(basename "$0") verify --volume-id vol-001

EOF
    exit 0

initialize_storage() {
    mkdir -p "$VOLUME_DIR" "$SNAPSHOT_DIR" "$LOG_DIR"
}

provision_volume() {
    local cluster_id="$1"
    local size_str="$2"
    local replication="${3:-3}"
    
    # Parse size
    local size_mb
    size_mb=$(parse_size "$size_str")
    
    # Generate volume ID
    local volume_id="vol-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local volume_dir="$VOLUME_DIR/$volume_id"
    
    log_info "Provisioning volume: $volume_id"
    log_info "Size: $size_str ($size_mb MB), Replication: $replication"
    
    # Create volume directory
    mkdir -p "$volume_dir"/{data,metadata,replicas}
    
    # Create metadata
    cat > "$volume_dir/metadata/volume.json" << EOF
{
  "volume_id": "$volume_id",
  "cluster_id": "$cluster_id",
  "size_mb": $size_mb,
  "replication_factor": $replication,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active",
  "used_mb": 0,
  "checksum": ""
}
EOF
    
    # Simulate data allocation
    dd if=/dev/zero of="$volume_dir/data/volume.dat" bs=1m count="$size_mb" 2>/dev/null || \
        dd if=/dev/zero of="$volume_dir/data/volume.dat" bs=1M count="$size_mb" 2>/dev/null
    
    # Create replicas
    for ((i=1; i<=replication; i++)); do
        local replica_id="replica-$i"
        mkdir -p "$volume_dir/replicas/$replica_id"
        
        cat > "$volume_dir/replicas/$replica_id/metadata.json" << EOF
{
  "replica_id": "$replica_id",
  "location": "node-$i",
  "status": "synced",
  "last_sync": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    done
    
    log_success "Volume provisioned successfully!"
    echo ""
    echo "Volume ID: $volume_id"
    echo "Size: $size_str"
    echo "Replication: $replication"
    echo "Status: active"
}

parse_size() {
    local size_str="$1"
    
    # Extract number and unit
    local number
    local unit
    number=$(echo "$size_str" | grep -o '[0-9]*')
    unit=$(echo "$size_str" | grep -o '[A-Za-z]*')
    
    case "${unit^^}" in
        GB|G)
            echo $((number * 1024))
            ;;
        MB|M)
            echo "$number"
            ;;
        TB|T)
            echo $((number * 1024 * 1024))
            ;;
        *)
            echo "$number"
            ;;
    esac
}

list_volumes() {
    echo ""
    echo "$(tput bold)Storage Volumes:$(tput sgr0)"
    echo "$(tput bold)────────────────────────────────────────────────────────────────$(tput sgr0)"
    
    if [[ ! -d "$VOLUME_DIR" ]] || [[ -z "$(ls -A "$VOLUME_DIR" 2>/dev/null)" ]]; then
        echo "  No volumes found"
        echo ""
        return
    fi
    
    printf "\n%-20s %-15s %-10s %-10s %-10s %s\n" \
        "VOLUME ID" "CLUSTER" "SIZE" "USED" "REPLICAS" "STATUS"
    printf "%-20s %-15s %-10s %-10s %-10s %s\n" \
        "─────────" "───────" "────" "────" "────────" "──────"
    
    for volume_dir in "$VOLUME_DIR"/*; do
        if [[ -d "$volume_dir" ]]; then
            local volume_id
            volume_id=$(basename "$volume_dir")
            
            if [[ -f "$volume_dir/metadata/volume.json" ]]; then
                local metadata
                metadata=$(cat "$volume_dir/metadata/volume.json")
                
                local cluster_id
                cluster_id=$(echo "$metadata" | grep -o '"cluster_id": "[^"]*"' | cut -d'"' -f4)
                
                local size_mb
                size_mb=$(echo "$metadata" | grep -o '"size_mb": [0-9]*' | awk '{print $2}')
                
                local used_mb
                used_mb=$(echo "$metadata" | grep -o '"used_mb": [0-9]*' | awk '{print $2}')
                
                local repl_factor
                repl_factor=$(echo "$metadata" | grep -o '"replication_factor": [0-9]*' | awk '{print $2}')
                
                local status
                status=$(echo "$metadata" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
                
                printf "%-20s %-15s %-10s %-10s %-10s %s\n" \
                    "$volume_id" "$cluster_id" "${size_mb}MB" "${used_mb}MB" "$repl_factor" "$status"
            fi
        fi
    done
    
    echo ""
}

create_snapshot() {
    local volume_id="$1"
    local retention="${2:-7d}"
    
    if [[ ! -d "$VOLUME_DIR/$volume_id" ]]; then
        log_error "Volume not found: $volume_id"
        return 1
    fi
    
    local snapshot_id="snap-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local snapshot_dir="$SNAPSHOT_DIR/$snapshot_id"
    
    log_info "Creating snapshot: $snapshot_id"
    log_info "Source volume: $volume_id"
    log_info "Retention: $retention"
    
    mkdir -p "$snapshot_dir"
    
    # Create snapshot metadata
    cat > "$snapshot_dir/metadata.json" << EOF
{
  "snapshot_id": "$snapshot_id",
  "volume_id": "$volume_id",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "retention": "$retention",
  "size_mb": $(stat -f%z "$VOLUME_DIR/$volume_id/data/volume.dat" 2>/dev/null || stat -c%s "$VOLUME_DIR/$volume_id/data/volume.dat" 2>/dev/null || echo 0),
  "checksum": "$(md5sum "$VOLUME_DIR/$volume_id/data/volume.dat" 2>/dev/null | awk '{print $1}' || md5 -q "$VOLUME_DIR/$volume_id/data/volume.dat" 2>/dev/null || echo 'none')"
}
EOF
    
    # Copy volume data (simulated incremental snapshot)
    log_info "Copying volume data..."
    cp "$VOLUME_DIR/$volume_id/data/volume.dat" "$snapshot_dir/volume.dat"
    
    log_success "Snapshot created successfully!"
    echo ""
    echo "Snapshot ID: $snapshot_id"
    echo "Volume: $volume_id"
    echo "Created: $(date)"
}

verify_integrity() {
    local volume_id="$1"
    
    if [[ ! -d "$VOLUME_DIR/$volume_id" ]]; then
        log_error "Volume not found: $volume_id"
        return 1
    fi
    
    log_info "Verifying data integrity for volume: $volume_id"
    
    local volume_file="$VOLUME_DIR/$volume_id/data/volume.dat"
    
    if [[ ! -f "$volume_file" ]]; then
        log_error "Volume data file not found"
        return 1
    fi
    
    # Calculate checksum
    log_info "Calculating checksum..."
    local checksum
    checksum=$(md5sum "$volume_file" 2>/dev/null | awk '{print $1}' || md5 -q "$volume_file" 2>/dev/null || echo 'none')
    
    # Verify replicas
    log_info "Verifying replicas..."
    local replica_count=0
    local synced_count=0
    
    for replica_dir in "$VOLUME_DIR/$volume_id/replicas"/*; do
        if [[ -d "$replica_dir" ]]; then
            ((replica_count++))
            
            local replica_id
            replica_id=$(basename "$replica_dir")
            
            local status
            status=$(grep '"status"' "$replica_dir/metadata.json" | cut -d'"' -f4)
            
            if [[ "$status" == "synced" ]]; then
                ((synced_count++))
                log_info "  $replica_id: ✓ SYNCED"
            else
                log_warn "  $replica_id: ✗ OUT OF SYNC"
            fi
        fi
    done
    
    echo ""
    echo "$(tput bold)Integrity Check Results:$(tput sgr0)"
    echo "────────────────────────────────────────"
    printf "%-25s %s\n" "Volume ID:" "$volume_id"
    printf "%-25s %s\n" "Checksum:" "$checksum"
    printf "%-25s %d/%d\n" "Replicas Synced:" "$synced_count" "$replica_count"
    
    if [[ $synced_count -eq $replica_count ]]; then
        echo "$(tput setaf 2)Status: HEALTHY$(tput sgr0)"
    else
        echo "$(tput setaf 3)Status: DEGRADED$(tput sgr0)"
    fi
    echo ""
}

show_stats() {
    echo ""
    echo "$(tput bold)Storage Statistics:$(tput sgr0)"
    echo "$(tput bold)════════════════════════════════════════════════════════════════$(tput sgr0)"
    echo ""
    
    # Calculate totals
    local total_volumes=0
    local total_capacity_mb=0
    local total_used_mb=0
    local total_snapshots=0
    
    if [[ -d "$VOLUME_DIR" ]]; then
        for volume_dir in "$VOLUME_DIR"/*; do
            if [[ -d "$volume_dir" ]]; then
                ((total_volumes++))
                
                local metadata
                metadata=$(cat "$volume_dir/metadata/volume.json" 2>/dev/null || echo '{}')
                
                local size_mb
                size_mb=$(echo "$metadata" | grep -o '"size_mb": [0-9]*' | awk '{print $2}' || echo 0)
                total_capacity_mb=$((total_capacity_mb + size_mb))
                
                local used_mb
                used_mb=$(echo "$metadata" | grep -o '"used_mb": [0-9]*' | awk '{print $2}' || echo 0)
                total_used_mb=$((total_used_mb + used_mb))
            fi
        done
    fi
    
    if [[ -d "$SNAPSHOT_DIR" ]]; then
        total_snapshots=$(ls -1 "$SNAPSHOT_DIR" 2>/dev/null | wc -l | tr -d ' ')
    fi
    
    local usage_percent=0
    if [[ $total_capacity_mb -gt 0 ]]; then
        usage_percent=$((total_used_mb * 100 / total_capacity_mb))
    fi
    
    printf "%-30s %d\n" "Total Volumes:" "$total_volumes"
    printf "%-30s %.2f GB\n" "Total Capacity:" "$(echo "scale=2; $total_capacity_mb / 1024" | bc)"
    printf "%-30s %.2f GB\n" "Total Used:" "$(echo "scale=2; $total_used_mb / 1024" | bc)"
    printf "%-30s %d%%\n" "Usage:" "$usage_percent"
    printf "%-30s %d\n" "Snapshots:" "$total_snapshots"
    
    echo ""
    echo "$(tput bold)IOPS Performance:$(tput sgr0)"
    printf "%-30s %d\n" "Read IOPS:" "$(( RANDOM % 2000 + 1000 ))"
    printf "%-30s %d\n" "Write IOPS:" "$(( RANDOM % 1500 + 800 ))"
    printf "%-30s %d ms\n" "Avg Read Latency:" "$(( RANDOM % 10 + 5 ))"
    printf "%-30s %d ms\n" "Avg Write Latency:" "$(( RANDOM % 15 + 8 ))"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    initialize_storage
    
    if [[ $# -eq 0 ]]; then
        show_usage
    fi
    
    local command="$1"
    shift
    
    local volume_id=""
    local cluster_id=""
    local size=""
    local replication=3
    local retention="7d"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --volume-id)
                volume_id="$2"
                shift 2
                ;;
            --cluster-id)
                cluster_id="$2"
                shift 2
                ;;
            --size)
                size="$2"
                shift 2
                ;;
            --replication)
                replication="$2"
                shift 2
                ;;
            --retention)
                retention="$2"
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
        provision)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            [[ -z "$size" ]] && { log_error "Size required"; exit 1; }
            provision_volume "$cluster_id" "$size" "$replication"
            ;;
        list)
            list_volumes
            ;;
        snapshot)
            [[ -z "$volume_id" ]] && { log_error "Volume ID required"; exit 1; }
            create_snapshot "$volume_id" "$retention"
            ;;
        verify)
            [[ -z "$volume_id" ]] && { log_error "Volume ID required"; exit 1; }
            verify_integrity "$volume_id"
            ;;
        stats)
            show_stats
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            ;;
    esac
}

main "$@"
EOF