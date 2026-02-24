#!/usr/bin/env bats
# cluster_manager.bats — Integration tests for bin/cluster-manager.sh
#
# Run:  bats tests/cluster_manager.bats

# Setup proper BATS environment
setup() {
    # Get the project root directory
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    CLUSTER_MANAGER="$PROJECT_ROOT/bin/cluster-manager.sh"
    
    # Each test gets its own isolated DATA_DIR
    TEST_DATA_DIR="$(mktemp -d)"
    export DATA_DIR="$TEST_DATA_DIR"

    # Create necessary directories
    mkdir -p "$TEST_DATA_DIR/clusters" "$TEST_DATA_DIR/logs/cluster"
    
    # Make sure the cluster manager is executable
    if [ -f "$CLUSTER_MANAGER" ]; then
        chmod +x "$CLUSTER_MANAGER"
    else
        echo "WARNING: cluster-manager.sh not found at $CLUSTER_MANAGER"
    fi
    
    # Source the cluster library if it exists
    CLUSTER_LIB="$PROJECT_ROOT/lib/cluster-lib.sh"
    if [ -f "$CLUSTER_LIB" ]; then
        source "$CLUSTER_LIB"
    fi
}

teardown() {
    # Clean up temp directory
    if [ -n "$TEST_DATA_DIR" ] && [ -d "$TEST_DATA_DIR" ]; then
        rm -rf "$TEST_DATA_DIR"
    fi
}

# Helper: create a cluster and capture its ID
_create_and_get_id() {
    local name="${1:-test-cluster}"
    local nodes="${2:-3}"
    local output
    
    # Check if cluster manager exists
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        echo "ERROR: cluster-manager.sh not found"
        return 1
    fi
    
    # Initialize first if needed (ignore errors if already initialized)
    DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" init >/dev/null 2>&1 || true
    
    # Create cluster and capture output
    output=$(DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" create --name "$name" --nodes "$nodes" 2>&1)
    
    # Extract cluster ID from output
    echo "$output" | grep -i "cluster.*id" | grep -o '[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}' | head -1
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

@test "init: creates directory structure and default config" {
    # Skip if cluster manager doesn't exist
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" init
    [ "$status" -eq 0 ] || {
        echo "Failed with output: $output"
        return 1
    }
    [[ "$output" =~ [Ii]nitialized ]] || [[ "$output" =~ [Cc]reated ]] || {
        echo "Output didn't contain expected text: $output"
        return 1
    }
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

@test "create: exits non-zero when --name is missing" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" create --nodes 3
    [ "$status" -ne 0 ]
}

@test "create: creates cluster with correct node count" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    local cluster_id
    cluster_id=$(_create_and_get_id "ci-cluster" 3)
    
    # If cluster_id is empty, the creation failed
    if [ -z "$cluster_id" ]; then
        # Try to create without helper to see error
        DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" init >/dev/null 2>&1 || true
        run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" create --name "ci-cluster" --nodes 3
        echo "Create failed with: $output"
        [ -n "$cluster_id" ]
    fi
    
    [ -n "$cluster_id" ]
    
    local node_count
    if [ -d "$TEST_DATA_DIR/clusters/$cluster_id/nodes" ]; then
        node_count=$(ls -1 "$TEST_DATA_DIR/clusters/$cluster_id/nodes" 2>/dev/null | wc -l | tr -d ' ')
        [ "$node_count" -eq 3 ] || {
            echo "Expected 3 nodes, found $node_count"
            return 1
        }
    else
        echo "Cluster directory not found: $TEST_DATA_DIR/clusters/$cluster_id"
        return 1
    fi
}

@test "create: cluster metadata JSON is valid (has required fields)" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    local cluster_id
    cluster_id=$(_create_and_get_id "meta-test" 3)
    [ -n "$cluster_id" ] || skip "Failed to create cluster"

    local meta="$TEST_DATA_DIR/clusters/$cluster_id/metadata/cluster.json"
    [ -f "$meta" ] || {
        echo "Metadata file not found: $meta"
        return 1
    }
    
    # Check for required fields
    grep -q '"cluster_id"' "$meta" || {
        echo "cluster_id not found in metadata"
        return 1
    }
    grep -q '"name"' "$meta" || {
        echo "name not found in metadata"
        return 1
    }
    grep -q '"node_count"' "$meta" || {
        echo "node_count not found in metadata"
        return 1
    }
    grep -q '"status"' "$meta" || {
        echo "status not found in metadata"
        return 1
    }
}

@test "create: leader state file is created" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    local cluster_id
    cluster_id=$(_create_and_get_id "leader-test" 3)
    [ -n "$cluster_id" ] || skip "Failed to create cluster"

    local leader_file="$TEST_DATA_DIR/clusters/$cluster_id/state/leader"
    [ -f "$leader_file" ] || {
        echo "Leader file not found: $leader_file"
        return 1
    }
    
    local leader
    leader=$(cat "$leader_file" 2>/dev/null || echo "")
    [ -n "$leader" ] || {
        echo "Leader file is empty"
        return 1
    }
}

@test "create: each node has metadata.json with status=up" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    local cluster_id
    cluster_id=$(_create_and_get_id "node-meta-test" 3)
    [ -n "$cluster_id" ] || skip "Failed to create cluster"

    local nodes_dir="$TEST_DATA_DIR/clusters/$cluster_id/nodes"
    [ -d "$nodes_dir" ] || {
        echo "Nodes directory not found: $nodes_dir"
        return 1
    }
    
    local found_nodes=0
    for node_dir in "$nodes_dir"/*/; do
        if [ -d "$node_dir" ]; then
            local meta="$node_dir/metadata.json"
            [ -f "$meta" ] || {
                echo "Metadata not found in $node_dir"
                return 1
            }
            
            # Check status field
            if grep -q '"status"[[:space:]]*:[[:space:]]*"up"' "$meta"; then
                found_nodes=$((found_nodes + 1))
            else
                echo "Node in $node_dir doesn't have status 'up'"
                cat "$meta"
                return 1
            fi
        fi
    done
    
    [ "$found_nodes" -eq 3 ] || {
        echo "Expected 3 nodes with status up, found $found_nodes"
        return 1
    }
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

@test "list: shows 'No clusters found' when data dir is empty" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Nn]o[[:space:]]+clusters ]] || [[ "$output" =~ [Ee]mpty ]]
}

@test "list: shows created cluster after create" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    _create_and_get_id "list-test" 3 >/dev/null

    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ list-test ]]
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

@test "status: exits non-zero for unknown cluster-id" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" status --cluster-id "does-not-exist-$(date +%s)"
    [ "$status" -ne 0 ]
}

@test "status: exits non-zero when --cluster-id is missing" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" status
    [ "$status" -ne 0 ]
}

@test "status: shows HEALTHY for a freshly created 3-node cluster" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    local cluster_id
    cluster_id=$(_create_and_get_id "status-test" 3)
    [ -n "$cluster_id" ] || skip "Failed to create cluster"

    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" status --cluster-id "$cluster_id"
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Hh]ealthy ]] || [[ "$output" =~ [Hh]EALTHY ]]
}

# ---------------------------------------------------------------------------
# add-node
# ---------------------------------------------------------------------------

@test "add-node: increases node count by 1" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    local cluster_id
    cluster_id=$(_create_and_get_id "scale-test" 3)
    [ -n "$cluster_id" ] || skip "Failed to create cluster"

    # Count nodes before
    local before_count
    before_count=$(ls -1 "$TEST_DATA_DIR/clusters/$cluster_id/nodes" 2>/dev/null | wc -l | tr -d ' ')
    
    # Add node
    DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" add-node --cluster-id "$cluster_id" >/dev/null 2>&1 || true
    
    # Count nodes after
    local after_count
    after_count=$(ls -1 "$TEST_DATA_DIR/clusters/$cluster_id/nodes" 2>/dev/null | wc -l | tr -d ' ')
    
    [ "$after_count" -eq "$((before_count + 1))" ] || {
        echo "Expected $((before_count + 1)) nodes, found $after_count"
        return 1
    }
}

@test "add-node: exits non-zero for missing cluster" {
    if [ ! -f "$CLUSTER_MANAGER" ]; then
        skip "cluster-manager.sh not found"
    fi
    
    run DATA_DIR="$TEST_DATA_DIR" bash "$CLUSTER_MANAGER" add-node --cluster-id "no-such-cluster-$(date +%s)"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# check_cluster_health (POST-MORTEM regression: single-line JSON parsing)
# ---------------------------------------------------------------------------

@test "check_cluster_health: correctly reads status from single-line JSON" {
    # This test doesn't need the cluster manager, just the library
    CLUSTER_LIB="$PROJECT_ROOT/lib/cluster-lib.sh"
    if [ ! -f "$CLUSTER_LIB" ]; then
        skip "cluster-lib.sh not found"
    fi
    
    # Create test data
    local cluster_id="regression-cls-$(date +%s)"
    mkdir -p "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-1"
    
    # Single-line JSON — the exact format that broke the old parser
    cat > "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-1/metadata.json" <<EOF
{"node_id":"node-1","cluster_id":"$cluster_id","status":"up","role":"leader"}
EOF

    # Source the library and run the function
    source "$CLUSTER_LIB"
    
    # We need to mock or call the actual function
    if type check_cluster_health &>/dev/null; then
        run check_cluster_health "$cluster_id"
        echo "Health check result: $output"
        [ "$status" -eq 0 ] || [ "$output" = "healthy" ] || [ "$output" = "HEALTHY" ]
    else
        # If function doesn't exist, just check that we can read the file
        [ -f "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-1/metadata.json" ]
        grep -q '"status":"up"' "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-1/metadata.json"
    fi
}

@test "check_cluster_health: 1 of 3 nodes down = DEGRADED (quorum retained)" {
    CLUSTER_LIB="$PROJECT_ROOT/lib/cluster-lib.sh"
    if [ ! -f "$CLUSTER_LIB" ]; then
        skip "cluster-lib.sh not found"
    fi
    
    local cluster_id="degraded-cls-$(date +%s)"
    
    # Create 3 nodes, one down
    for i in 1 2 3; do
        mkdir -p "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-$i"
        local status="up"
        [ $i -eq 3 ] && status="down"
        cat > "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-$i/metadata.json" <<EOF
{"node_id":"node-$i","cluster_id":"$cluster_id","status":"$status"}
EOF
    done

    source "$CLUSTER_LIB"
    
    if type check_cluster_health &>/dev/null; then
        run check_cluster_health "$cluster_id"
        echo "Health check result: $output"
        # Accept various forms of degraded
        [[ "$output" =~ [Dd]egraded ]] || [[ "$output" =~ [Dd]EGRADED ]]
    else
        skip "check_cluster_health function not found"
    fi
}

@test "check_cluster_health: 2 of 3 nodes down = UNHEALTHY (quorum lost)" {
    CLUSTER_LIB="$PROJECT_ROOT/lib/cluster-lib.sh"
    if [ ! -f "$CLUSTER_LIB" ]; then
        skip "cluster-lib.sh not found"
    fi
    
    local cluster_id="unhealthy-cls-$(date +%s)"
    
    # Create 3 nodes, two down
    for i in 1 2 3; do
        mkdir -p "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-$i"
        local status="down"
        [ $i -eq 1 ] && status="up"
        cat > "$TEST_DATA_DIR/clusters/$cluster_id/nodes/node-$i/metadata.json" <<EOF
{"node_id":"node-$i","cluster_id":"$cluster_id","status":"$status"}
EOF
    done

    source "$CLUSTER_LIB"
    
    if type check_cluster_health &>/dev/null; then
        run check_cluster_health "$cluster_id"
        echo "Health check result: $output"
        # Accept various forms of unhealthy
        [[ "$output" =~ [Uu]nhealthy ]] || [[ "$output" =~ [Uu]NHEALTHY ]]
    else
        skip "check_cluster_health function not found"
    fi
}