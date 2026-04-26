#!/usr/bin/env bash
# serve-metrics.sh — HTTP shim for Prometheus scraping
#
# Called by socat for each incoming HTTP connection.  Reads the HTTP request
# (discards it), then writes an HTTP/1.0 200 response whose body is the
# Prometheus-format output of cluster-manager.sh metrics.
#
# The CLUSTER_ID env var is set by the metrics-exporter Docker service.
# If it is empty, we iterate over every cluster in DATA_DIR and emit all.
#
# Usage (direct):
#   CLUSTER_ID=cls-001 bash observability/serve-metrics.sh
# Usage (via socat, as docker-compose runs it):
#   socat TCP-LISTEN:9101,fork EXEC:"bash observability/serve-metrics.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data}"
CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"

# Consume HTTP request headers (socat passes stdin from the HTTP client)
while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
done

# Collect metrics body
body=""
if [[ -n "${CLUSTER_ID:-}" ]]; then
    body=$(bash "$CLUSTER_MANAGER" metrics --cluster-id "$CLUSTER_ID" 2>/dev/null || \
           printf "# ERROR: cluster %s not found\n" "$CLUSTER_ID")
else
    # Emit metrics for all known clusters
    if [[ -d "$DATA_DIR/clusters" ]]; then
        for cluster_dir in "$DATA_DIR/clusters"/*/; do
            [[ -d "$cluster_dir" ]] || continue
            cid=$(basename "$cluster_dir")
            cluster_body=$(bash "$CLUSTER_MANAGER" metrics --cluster-id "$cid" 2>/dev/null || true)
            body="${body}${cluster_body}"$'\n'
        done
    fi
    if [[ -z "$body" ]]; then
        body="# No clusters found in $DATA_DIR/clusters"
    fi
fi

# Write HTTP response
printf "HTTP/1.0 200 OK\r\n"
printf "Content-Type: text/plain; version=0.0.4\r\n"
printf "Content-Length: %d\r\n" "${#body}"
printf "Connection: close\r\n"
printf "\r\n"
printf "%s" "$body"
