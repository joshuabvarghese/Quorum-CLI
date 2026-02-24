#!/usr/bin/env bash
CID=$(./bin/cluster-manager.sh list | grep "my-cluster" | awk '{print $1}' | head -n 1)

echo "--- MONITORING CLUSTER: $CID ---"

# Get a list of all nodes that are currently DOWN
DOWN_NODES=$(./bin/cluster-manager.sh status --cluster-id "$CID" | grep "DOWN" -B 2 | grep "node-" | awk '{print $1}')

if [ -z "$DOWN_NODES" ]; then
    echo "[HEALTHY] All nodes are up."
else
    for NODE in $DOWN_NODES; do
        echo "[REPAIR] Found $NODE is down. Triggering recovery..."
        ./scripts/chaos-engineering.sh recover-node --cluster-id "$CID" --node-id "$NODE"
    done
    echo "[SUCCESS] Healing sequence complete."
fi
