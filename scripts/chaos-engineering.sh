#!/usr/bin/env bash
set -euo pipefail

simulate_iptables_partition() {
    local target_node="$1"
    local dry_run="${2:-false}"
    echo "[INFO] Simulating partition for: $target_node (Dry-run: $dry_run)"
    if [ "$dry_run" = "true" ]; then
        echo "[INFO] Dry run: ssh $target_node 'sudo iptables -A INPUT -s 192.168.1.0/24 -j DROP'"
    else
        echo "[WARN] Applying real firewall rules to isolate $target_node..."
    fi
}

