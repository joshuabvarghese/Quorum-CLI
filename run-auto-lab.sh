#!/usr/bin/env bash

# Find the cluster ID
CID=$(./bin/cluster-manager.sh list | grep "my-cluster" | awk '{print $1}' | head -n 1)

if [ -z "$CID" ]; then
    echo "[INFO] No cluster found. Creating one..."
    ./bin/cluster-manager.sh create --name my-cluster --nodes 3
    CID=$(./bin/cluster-manager.sh list | grep "my-cluster" | awk '{print $1}' | head -n 1)
fi

echo "--- RUNNING AUTOMATED LAB ON CLUSTER: $CID ---"

# 1. Provision Storage
VOL_LINE=$(./bin/storage-ops.sh provision --cluster-id "$CID" --size 50GB | grep "vol-")
VOL_ID=$(echo $VOL_LINE | awk '{print $NF}')
echo "[AUTO] Provisioned Volume: $VOL_ID"

# 2. Inject Chaos
./scripts/chaos-engineering.sh kill-node --cluster-id "$CID" --node-id node-2

# 3. Verify while node is down
./bin/storage-ops.sh verify --cluster-id "$CID" --volume-id "$VOL_ID"

# 4. Recovery
./scripts/chaos-engineering.sh recover-node --cluster-id "$CID" --node-id node-2

echo "--- LAB COMPLETE ---"
./bin/cluster-manager.sh status --cluster-id "$CID"
