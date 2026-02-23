#!/usr/bin/env bash

################################################################################
# Quick Demo - Automated demonstration of the platform
################################################################################

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$PROJECT_ROOT/bin"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

demo_message() {
    echo ""
    echo "$(tput setaf 6)$(tput bold)>>> $1$(tput sgr0)"
    sleep 2
}

press_enter() {
    echo ""
    read -p "$(tput setaf 3)Press ENTER to continue...$(tput sgr0)" 
}

clear_screen() {
    printf '\033[2J\033[H'
}

################################################################################
# Demo Script
################################################################################

run_demo() {
    clear_screen
    
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║        DISTRIBUTED STORAGE & DATA PLATFORM MANAGER               ║
║                     Live Demonstration                           ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

EOF
    
    echo "This demo will walk you through the key features:"
    echo ""
    echo "  1. System Initialization"
    echo "  2. Cluster Creation"
    echo "  3. Storage Provisioning"
    echo "  4. Performance Monitoring"
    echo "  5. Chaos Engineering"
    echo "  6. Auto-Recovery"
    echo ""
    
    press_enter
    
    # ========== Step 1: Initialize ==========
    demo_message "Step 1: Initializing the system..."
    
    echo "Command: ./bin/cluster-manager.sh init"
    echo ""
    
    "$BIN_DIR/cluster-manager.sh" init
    
    press_enter
    
    # ========== Step 2: Create Cluster ==========
    demo_message "Step 2: Creating a 3-node distributed cluster..."
    
    echo "Command: ./bin/cluster-manager.sh create --name production-cluster --nodes 3 --type cassandra"
    echo ""
    
    CLUSTER_OUTPUT=$("$BIN_DIR/cluster-manager.sh" create \
        --name production-cluster \
        --nodes 3 \
        --type cassandra \
        --replication-factor 3)
    
    echo "$CLUSTER_OUTPUT"
    
    # Extract cluster ID
    CLUSTER_ID=$(echo "$CLUSTER_OUTPUT" | grep "Cluster ID:" | awk '{print $3}')
    
    press_enter
    
    # ========== Step 3: View Cluster Status ==========
    demo_message "Step 3: Viewing cluster status..."
    
    echo "Command: ./bin/cluster-manager.sh status --cluster-id $CLUSTER_ID --verbose"
    echo ""
    
    "$BIN_DIR/cluster-manager.sh" status --cluster-id "$CLUSTER_ID" --verbose
    
    press_enter
    
    # ========== Step 4: Provision Storage ==========
    demo_message "Step 4: Provisioning distributed storage volume..."
    
    echo "Command: ./bin/storage-ops.sh provision --cluster-id $CLUSTER_ID --size 500MB --replication 3"
    echo ""
    
    VOLUME_OUTPUT=$("$BIN_DIR/storage-ops.sh" provision \
        --cluster-id "$CLUSTER_ID" \
        --size 500MB \
        --replication 3)
    
    echo "$VOLUME_OUTPUT"
    
    # Extract volume ID
    VOLUME_ID=$(echo "$VOLUME_OUTPUT" | grep "Volume ID:" | awk '{print $3}')
    
    press_enter
    
    # ========== Step 5: Create Snapshot ==========
    demo_message "Step 5: Creating snapshot for disaster recovery..."
    
    echo "Command: ./bin/storage-ops.sh snapshot --volume-id $VOLUME_ID --retention 7d"
    echo ""
    
    "$BIN_DIR/storage-ops.sh" snapshot --volume-id "$VOLUME_ID" --retention 7d
    
    press_enter
    
    # ========== Step 6: Verify Integrity ==========
    demo_message "Step 6: Verifying data integrity and replication..."
    
    echo "Command: ./bin/storage-ops.sh verify --volume-id $VOLUME_ID"
    echo ""
    
    "$BIN_DIR/storage-ops.sh" verify --volume-id "$VOLUME_ID"
    
    press_enter
    
    # ========== Step 7: Storage Stats ==========
    demo_message "Step 7: Viewing storage statistics..."
    
    echo "Command: ./bin/storage-ops.sh stats"
    echo ""
    
    "$BIN_DIR/storage-ops.sh" stats
    
    press_enter
    
    # ========== Step 8: Performance Analysis ==========
    demo_message "Step 8: Analyzing cluster performance..."
    
    echo "Command: ./bin/perf-monitor.sh analyze --cluster-id $CLUSTER_ID"
    echo ""
    
    "$BIN_DIR/perf-monitor.sh" analyze --cluster-id "$CLUSTER_ID"
    
    press_enter
    
    # ========== Step 9: Generate Report ==========
    demo_message "Step 9: Generating performance report..."
    
    echo "Command: ./bin/perf-monitor.sh report --cluster-id $CLUSTER_ID --output demo-report.txt"
    echo ""
    
    "$BIN_DIR/perf-monitor.sh" report --cluster-id "$CLUSTER_ID" --output demo-report.txt
    
    press_enter
    
    # ========== Step 10: Chaos Engineering ==========
    demo_message "Step 10: Testing resilience - Simulating node failure..."
    
    echo "Command: ./scripts/chaos-engineering.sh kill-node --cluster-id $CLUSTER_ID --node-id node-2 --auto-recover"
    echo ""
    
    "$PROJECT_ROOT/scripts/chaos-engineering.sh" kill-node \
        --cluster-id "$CLUSTER_ID" \
        --node-id node-2 \
        --auto-recover
    
    press_enter
    
    # ========== Step 11: Add Node (Scale Up) ==========
    demo_message "Step 11: Scaling cluster - Adding new node..."
    
    echo "Command: ./bin/cluster-manager.sh add-node --cluster-id $CLUSTER_ID"
    echo ""
    
    "$BIN_DIR/cluster-manager.sh" add-node --cluster-id "$CLUSTER_ID"
    
    press_enter
    
    # ========== Step 12: Final Status ==========
    demo_message "Step 12: Final cluster status check..."
    
    echo "Command: ./bin/cluster-manager.sh status --cluster-id $CLUSTER_ID"
    echo ""
    
    "$BIN_DIR/cluster-manager.sh" status --cluster-id "$CLUSTER_ID"
    
    # ========== Summary ==========
    echo ""
    echo "$(tput bold)╔══════════════════════════════════════════════════════════════════╗$(tput sgr0)"
    echo "$(tput bold)║                      DEMO COMPLETE!                              ║$(tput sgr0)"
    echo "$(tput bold)╚══════════════════════════════════════════════════════════════════╝$(tput sgr0)"
    echo ""
    echo "$(tput setaf 2)✓$(tput sgr0) Created distributed cluster with 4 nodes"
    echo "$(tput setaf 2)✓$(tput sgr0) Provisioned replicated storage volume"
    echo "$(tput setaf 2)✓$(tput sgr0) Created disaster recovery snapshot"
    echo "$(tput setaf 2)✓$(tput sgr0) Verified data integrity"
    echo "$(tput setaf 2)✓$(tput sgr0) Generated performance reports"
    echo "$(tput setaf 2)✓$(tput sgr0) Tested resilience with chaos engineering"
    echo "$(tput setaf 2)✓$(tput sgr0) Demonstrated auto-recovery"
    echo "$(tput setaf 2)✓$(tput sgr0) Scaled cluster dynamically"
    echo ""
    echo "Cluster ID: $(tput setaf 6)$CLUSTER_ID$(tput sgr0)"
    echo "Volume ID:  $(tput setaf 6)$VOLUME_ID$(tput sgr0)"
    echo "Report:     $(tput setaf 6)demo-report.txt$(tput sgr0)"
    echo ""
    echo "$(tput setaf 3)Next steps:$(tput sgr0)"
    echo "  • Run tests: ./tests/integration-tests.sh"
    echo "  • View dashboard: ./bin/perf-monitor.sh dashboard --cluster-id $CLUSTER_ID"
    echo "  • List all clusters: ./bin/cluster-manager.sh list"
    echo "  • List all volumes: ./bin/storage-ops.sh list"
    echo ""
}

################################################################################
# Main
################################################################################

echo "Starting automated demo in 3 seconds..."
sleep 3

run_demo

echo "Demo completed successfully!"
echo ""
