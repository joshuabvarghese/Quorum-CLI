#!/usr/bin/env bash
set -euo pipefail

# Minimalist Chaos Script
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }

simulate_iptables_partition() {
    local target="$1"
    local dry_run="${2:-false}"
    log_warn "CHAOS: Isolating node $target"
    
    if [ "$dry_run" = "true" ]; then
        log_info "DRY-RUN: ssh $target 'sudo iptables -A INPUT -s 192.168.1.0/24 -j DROP'"
    else
        log_info "Executing real partition on $target..."
    fi
}

case "${1:-}" in
    partition)
        # Shift away the 'partition' word
        shift
        target=""
        dry=false
        # Simple argument parser
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --target-node) target="$2"; shift 2 ;;
                --dry-run) dry=true; shift ;;
                *) shift ;;
            esac
        done
        simulate_iptables_partition "$target" "$dry"
        ;;
    *)
        echo "Usage: $0 partition --target-node <IP> --dry-run"
        ;;
esac
