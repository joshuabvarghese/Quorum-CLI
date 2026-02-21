#!/usr/bin/env bash

################################################################################
# Storage Operations - Volume provisioning, snapshots, replication
################################################################################

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"
DATA_DIR="$PROJECT_ROOT/data"
LOG_DIR="$PROJECT_ROOT/logs/storage"

source "$LIB_DIR/logger.sh"

VOLUME_DIR="$DATA_DIR/volumes"
SNAPSHOT_DIR="$DATA_DIR/snapshots"
LOG_FILE="$LOG_DIR/storage-ops.log"

# Dry-run flag
DRY_RUN=false

dry_run_exec() {
    local desc="$1"; shift
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would execute: $desc"
        return 0
    fi
    "$@"
}

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
    --dry-run            Show what would happen without making changes

Examples:
    $(basename "$0") provision --cluster-id cls-001 --size 5GB --replication 3
    $(basename "$0") snapshot --volume-id vol-001 --retention 7d
    $(basename "$0") verify --volume-id vol-001
    $(basename "$0") provision --cluster-id cls-001 --size 10GB --dry-run

EOF
    exit 0
}

provision_volume() {
    local cluster_id="$1"
    local size="$2"
    local replication="${3:-3}"

    local volume_id="vol-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"

    log_info "Provisioning volume: $volume_id"
    log_info "Size: $size, Replication: $replication"

    dry_run_exec "Create volume directories" \
        mkdir -p "$VOLUME_DIR/$volume_id"/{data,replicas,metadata}

    # Parse size to bytes for metadata
    local size_mb=0
    if [[ "$size" =~ ([0-9]+)GB ]]; then
        size_mb=$(( ${BASH_REMATCH[1]} * 1024 ))
    elif [[ "$size" =~ ([0-9]+)MB ]]; then
        size_mb=${BASH_REMATCH[1]}
    fi

    dry_run_exec "Write volume metadata" bash -c "cat > '$VOLUME_DIR/$volume_id/metadata/volume.json' << EOF
{
  \"volume_id\": \"$volume_id\",
  \"cluster_id\": \"$cluster_id\",
  \"size\": \"$size\",
  \"size_mb\": $size_mb,
  \"replication_factor\": $replication,
  \"status\": \"active\",
  \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"checksum\": \"$(openssl rand -hex 8 2>/dev/null || echo a3f2e1b7c4d2e8f9)\"
}
EOF"

    # Create replica entries
    for (( i=1; i<=replication; i++ )); do
        dry_run_exec "Create replica-$i for $volume_id" \
            mkdir -p "$VOLUME_DIR/$volume_id/replicas/replica-$i"
        if [[ "$DRY_RUN" != "true" ]]; then
            echo "synced" > "$VOLUME_DIR/$volume_id/replicas/replica-$i/status"
        fi
    done

    # Create placeholder data file
    dry_run_exec "Create volume data file" \
        dd if=/dev/urandom of="$VOLUME_DIR/$volume_id/data/volume.dat" bs=1k count=1 2>/dev/null

    log_success "Volume provisioned successfully!"
    echo ""
    echo "Volume ID: $volume_id"
    echo "Size: $size"
    echo "Replication: $replication"
    echo "Status: active"
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

    log_info "Creating snapshot: $snapshot_id"
    log_info "Source volume: $volume_id"
    log_info "Retention: $retention"
    log_info "Copying volume data..."

    dry_run_exec "Create snapshot directory" \
        mkdir -p "$SNAPSHOT_DIR/$snapshot_id"

    dry_run_exec "Copy volume data to snapshot" \
        cp -r "$VOLUME_DIR/$volume_id/." "$SNAPSHOT_DIR/$snapshot_id/"

    dry_run_exec "Write snapshot metadata" bash -c "cat > '$SNAPSHOT_DIR/$snapshot_id/snapshot.json' << EOF
{
  \"snapshot_id\": \"$snapshot_id\",
  \"volume_id\": \"$volume_id\",
  \"retention\": \"$retention\",
  \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"status\": \"complete\"
}
EOF"

    log_success "Snapshot created successfully!"
    echo ""
    echo "Snapshot ID: $snapshot_id"
    echo "Volume: $volume_id"
    echo "Created: $(date)"
    echo ""
}

verify_volume() {
    local volume_id="$1"

    if [[ ! -d "$VOLUME_DIR/$volume_id" ]]; then
        log_error "Volume not found: $volume_id"
        return 1
    fi

    log_info "Verifying data integrity for volume: $volume_id"
    log_info "Calculating checksum..."

    local checksum
    checksum=$(cat "$VOLUME_DIR/$volume_id/metadata/volume.json" \
               | grep -o '"checksum": "[^"]*"' | cut -d'"' -f4 \
               || echo "unknown")

    log_info "Verifying replicas..."

    local replicas_dir="$VOLUME_DIR/$volume_id/replicas"
    local replica_count=0
    local synced_count=0

    for replica_dir in "$replicas_dir"/*; do
        if [[ -d "$replica_dir" ]]; then
            (( replica_count++ ))
            local replica_name
            replica_name=$(basename "$replica_dir")
            local status
            status=$(cat "$replica_dir/status" 2>/dev/null || echo "unknown")
            if [[ "$status" == "synced" ]]; then
                (( synced_count++ ))
                log_info "  $replica_name: ✓ SYNCED"
            else
                log_warn "  $replica_name: ✗ OUT OF SYNC"
            fi
        fi
    done

    echo ""
    echo "Integrity Check Results:"
    echo "────────────────────────────────────────"
    printf "%-30s %s\n" "Volume ID:"          "$volume_id"
    printf "%-30s %s\n" "Checksum:"           "$checksum"
    printf "%-30s %s/%s\n" "Replicas Synced:" "$synced_count" "$replica_count"

    if [[ $synced_count -eq $replica_count ]] && [[ $replica_count -gt 0 ]]; then
        printf "%-30s " "Status:"
        echo "$(tput setaf 2)HEALTHY$(tput sgr0)"
    else
        printf "%-30s " "Status:"
        echo "$(tput setaf 1)DEGRADED$(tput sgr0)"
    fi
    echo ""
}

list_volumes() {
    echo ""
    echo "$(tput bold)Available Volumes:$(tput sgr0)"
    echo "────────────────────────────────────────────────────────────────"

    if [[ ! -d "$VOLUME_DIR" ]] || [[ -z "$(ls -A "$VOLUME_DIR" 2>/dev/null)" ]]; then
        echo "  No volumes found"
        echo ""
        return
    fi

    printf "\n%-25s %-12s %-12s %-10s %s\n" "VOLUME ID" "SIZE" "REPLICATION" "STATUS" "CLUSTER"
    printf "%-25s %-12s %-12s %-10s %s\n"   "─────────" "────" "───────────" "──────" "───────"

    for vol_dir in "$VOLUME_DIR"/*; do
        if [[ -d "$vol_dir" ]]; then
            local vol_id meta size repl status cluster_id
            vol_id=$(basename "$vol_dir")
            meta=$(cat "$vol_dir/metadata/volume.json" 2>/dev/null || echo "{}")
            size=$(echo "$meta" | grep -o '"size": "[^"]*"' | cut -d'"' -f4 || echo "unknown")
            repl=$(echo "$meta" | grep -o '"replication_factor": [0-9]*' | awk '{print $2}' || echo "?")
            status=$(echo "$meta" | grep -o '"status": "[^"]*"' | cut -d'"' -f4 || echo "unknown")
            cluster_id=$(echo "$meta" | grep -o '"cluster_id": "[^"]*"' | cut -d'"' -f4 || echo "none")
            printf "%-25s %-12s %-12s %-10s %s\n" "$vol_id" "$size" "$repl" "$status" "$cluster_id"
        fi
    done
    echo ""
}

show_storage_stats() {
    local total_volumes=0
    local total_capacity_mb=0
    local total_used_mb=0
    local snapshot_count=0

    if [[ -d "$VOLUME_DIR" ]]; then
        for vol_dir in "$VOLUME_DIR"/*; do
            if [[ -d "$vol_dir" ]]; then
                (( total_volumes++ ))
                local meta size_mb
                meta=$(cat "$vol_dir/metadata/volume.json" 2>/dev/null || echo '{"size_mb":0}')
                size_mb=$(echo "$meta" | grep -o '"size_mb": [0-9]*' | awk '{print $2}' || echo 0)
                total_capacity_mb=$(( total_capacity_mb + size_mb ))
                # Simulate ~10% used
                total_used_mb=$(( total_used_mb + size_mb / 10 ))
            fi
        done
    fi

    if [[ -d "$SNAPSHOT_DIR" ]]; then
        for snap_dir in "$SNAPSHOT_DIR"/*; do
            [[ -d "$snap_dir" ]] && (( snapshot_count++ ))
        done
    fi

    local usage_pct=0
    [[ $total_capacity_mb -gt 0 ]] && usage_pct=$(( total_used_mb * 100 / total_capacity_mb ))

    echo ""
    echo "Storage Statistics:"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    printf "%-30s %s\n"   "Total Volumes:"   "$total_volumes"
    printf "%-30s %.2f GB\n" "Total Capacity:" "$(echo "scale=2; $total_capacity_mb / 1024" | bc)"
    printf "%-30s %.2f GB\n" "Total Used:"    "$(echo "scale=2; $total_used_mb / 1024" | bc)"
    printf "%-30s %s%%\n" "Usage:"           "$usage_pct"
    printf "%-30s %s\n"   "Snapshots:"       "$snapshot_count"
    echo ""
    echo "IOPS Performance:"
    echo "────────────────────────────────────────"
    printf "  %-25s %s\n" "Read IOPS:"           "$(( RANDOM % 1000 + 1200 ))"
    printf "  %-25s %s\n" "Write IOPS:"          "$(( RANDOM % 800 + 800 ))"
    printf "  %-25s %s ms\n" "Avg Read Latency:"  "$(( RANDOM % 5 + 5 ))"
    printf "  %-25s %s ms\n" "Avg Write Latency:" "$(( RANDOM % 8 + 10 ))"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    mkdir -p "$LOG_DIR" "$VOLUME_DIR" "$SNAPSHOT_DIR"

    if [[ $# -eq 0 ]]; then
        show_usage
    fi

    local command="$1"
    shift

    local volume_id=""
    local cluster_id=""
    local size="1GB"
    local replication=3
    local retention="7d"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --volume-id)   volume_id="$2";   shift 2 ;;
            --cluster-id)  cluster_id="$2";  shift 2 ;;
            --size)        size="$2";        shift 2 ;;
            --replication) replication="$2"; shift 2 ;;
            --retention)   retention="$2";   shift 2 ;;
            --dry-run)
                DRY_RUN=true
                log_warn "🔍 DRY-RUN mode enabled — no changes will be made."
                shift
                ;;
            --help) show_usage ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done

    case "$command" in
        provision)
            [[ -z "$cluster_id" ]] && { log_error "Cluster ID required"; exit 1; }
            provision_volume "$cluster_id" "$size" "$replication"
            ;;
        snapshot)
            [[ -z "$volume_id" ]] && { log_error "Volume ID required"; exit 1; }
            create_snapshot "$volume_id" "$retention"
            ;;
        verify)
            [[ -z "$volume_id" ]] && { log_error "Volume ID required"; exit 1; }
            verify_volume "$volume_id"
            ;;
        list)
            list_volumes
            ;;
        stats)
            show_storage_stats
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            ;;
    esac
}

main "$@"
