#!/usr/bin/env bash
CID="cls-1771954031-6a7ef2"
while true; do
    NODE_NUM=$((1 + $RANDOM % 4))
    TARGET="node-$NODE_NUM"
    
    echo "[MONKEY] 🐒 Sabotaging $TARGET..."
    ./scripts/chaos-engineering.sh kill-node --cluster-id "$CID" --node-id "$TARGET"
    
    # Wait 10 seconds before the next strike
    sleep 10
done
