#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="./data"

log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }

case "${1:-}" in
    partition)
        shift
        target=""; dry=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --target-node) target="$2"; shift 2 ;;
                --dry-run) dry=true; shift ;;
                *) shift ;;
            esac
        done
        log_warn "CHAOS: Isolating node $target"
        [[ "$dry" == "true" ]] && log_info "DRY-RUN: ssh $target 'sudo iptables -A INPUT -j DROP'"
        ;;
    kill-node)
        shift
        cid=""; nid=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --cluster-id) cid="$2"; shift 2 ;;
                --node-id) nid="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        log_warn "CHAOS INITIATED: Killing $nid"
        # Actual logic: Update metadata to 'down'
        meta="$DATA_DIR/clusters/$cid/nodes/$nid/metadata.json"
        if [[ -f "$meta" ]]; then
            sed -i '' 's/"status": "up"/"status": "down"/' "$meta" 2>/dev/null || sed -i 's/"status": "up"/"status": "down"/' "$meta"
            log_info "$nid is now DOWN."
        else
            echo "Error: Metadata not found at $meta"
        fi
        ;;
    *)
        echo "Usage: $0 {partition|kill-node} [options]"
        ;;
esac

    recover-node)
        shift
        cid=""; nid=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --cluster-id) cid="$2"; shift 2 ;;
                --node-id) nid="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        log_info "RECOVERING: Bringing $nid back online..."
        meta="./data/clusters/$cid/nodes/$nid/metadata.json"
        if [[ -f "$meta" ]]; then
            sed -i '' 's/"status": "down"/"status": "up"/' "$meta" 2>/dev/null || sed -i 's/"status": "down"/"status": "up"/' "$meta"
            log_success "$nid is now UP and resyncing."
        fi
        ;;
