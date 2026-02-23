#!/usr/bin/env bash

################################################################################
# Network Checks Library — Modular network health and connectivity utilities
#
# ShellCheck: SC2155-clean, all locals declared separately
#
# Sourced by cluster-manager.sh and chaos-engineering.sh to perform
# real connectivity checks before attempting operations.
#
# Why this is a separate library:
#   Every call to ssh or iptables can fail for unrelated network reasons.
#   Centralising pre-flight connectivity checks here means:
#     1. Scripts fail fast with a clear message instead of a cryptic SSH error
#     2. The --dry-run mode can show what checks *would* run
#     3. Functions can be independently unit-tested (see tests/network_checks.bats)
################################################################################

set -euo pipefail
IFS=$'\n\t'

# Timeout for individual connectivity checks (seconds)
NETWORK_CHECK_TIMEOUT=${NETWORK_CHECK_TIMEOUT:-3}

################################################################################
# check_ssh_connectivity()
#
# Verify SSH access to a remote host before attempting any remote operation.
# Fails fast with an actionable error message.
#
# Usage:  check_ssh_connectivity <host> [port]
# Returns: 0 if reachable, 1 if not
#
# ShellCheck SC2029: variables in ssh commands are intentionally expanded locally.
################################################################################
check_ssh_connectivity() {
    local host="$1"
    local port="${2:-22}"

    # Use timeout + bash TCP pseudo-device for a port check without netcat
    if timeout "$NETWORK_CHECK_TIMEOUT" bash -c \
        "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

################################################################################
# check_cluster_reachability()
#
# Checks that all nodes in CLUSTER_NODES are SSH-reachable.
# Returns 0 only if ALL nodes pass. Logs individual failures.
#
# Usage:  check_cluster_reachability <node1> [node2 ...]
################################################################################
check_cluster_reachability() {
    local nodes=("$@")
    local failed=0

    for node in "${nodes[@]}"; do
        if check_ssh_connectivity "$node"; then
            log_info "  ✓ $node is reachable"
        else
            log_error "  ✗ $node is UNREACHABLE (SSH port closed or host down)"
            failed=$(( failed + 1 ))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed node(s) unreachable. Aborting to prevent partial operation."
        log_info "Troubleshooting:"
        log_info "  1. Verify nodes are running:  ping <node>"
        log_info "  2. Verify SSH port open:      nc -zv <node> 22"
        log_info "  3. Verify SSH key auth works: ssh -o BatchMode=yes <node> 'echo ok'"
        log_info "  4. Use --dry-run to preview commands without connecting"
        return 1
    fi
    return 0
}

################################################################################
# check_iptables_available()
#
# Verify that iptables is available and the caller has the necessary privilege.
# Required before any network partition operation.
################################################################################
check_iptables_available() {
    if ! command -v iptables >/dev/null 2>&1; then
        log_error "iptables not found — install iptables-persistent or run on Linux"
        log_info "  On Debian/Ubuntu: sudo apt-get install iptables"
        return 1
    fi

    # Check if we can actually list rules (requires CAP_NET_ADMIN)
    if ! iptables -L INPUT --line-numbers >/dev/null 2>&1; then
        log_error "Insufficient privileges for iptables (need root or CAP_NET_ADMIN)"
        log_info "  Run with: sudo $0"
        return 1
    fi

    return 0
}

################################################################################
# list_active_partition_rules()
#
# Show any DROP rules currently active that match cluster IPs.
# Used in diagnostics and in heal-partition pre-flight.
#
# Usage:  list_active_partition_rules [cluster_cidr]
################################################################################
list_active_partition_rules() {
    local cidr="${1:-}"
    local input_rules output_rules

    if ! command -v iptables >/dev/null 2>&1; then
        echo "  (iptables not available)"
        return 0
    fi

    if [[ -n "$cidr" ]]; then
        input_rules=$(iptables -L INPUT --line-numbers 2>/dev/null | grep "$cidr" | grep DROP || echo "  (none)")
        output_rules=$(iptables -L OUTPUT --line-numbers 2>/dev/null | grep "$cidr" | grep DROP || echo "  (none)")
    else
        input_rules=$(iptables -L INPUT --line-numbers 2>/dev/null | grep DROP || echo "  (none)")
        output_rules=$(iptables -L OUTPUT --line-numbers 2>/dev/null | grep DROP || echo "  (none)")
    fi

    echo "Active DROP rules (INPUT):"
    echo "$input_rules" | sed 's/^/  /'
    echo "Active DROP rules (OUTPUT):"
    echo "$output_rules" | sed 's/^/  /'
}

################################################################################
# check_node_port()
#
# Check if a specific cluster port (e.g. Cassandra 7001) is accepting
# connections on a remote host. Used for pre-flight before join operations.
#
# Usage:  check_node_port <host> <port>
################################################################################
check_node_port() {
    local host="$1"
    local port="$2"

    if timeout "$NETWORK_CHECK_TIMEOUT" bash -c \
        "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
        log_info "  ✓ $host:$port is open"
        return 0
    else
        log_warn "  ✗ $host:$port is not responding"
        return 1
    fi
}

################################################################################
# measure_latency()
#
# Measure round-trip latency to a host using ping.
# Returns the average RTT in milliseconds (integer).
# Returns 9999 if host is unreachable.
#
# Usage:  ms=$(measure_latency 192.168.1.101)
################################################################################
measure_latency() {
    local host="$1"
    local count="${2:-3}"
    local result

    result=$(ping -c "$count" -W "$NETWORK_CHECK_TIMEOUT" "$host" 2>/dev/null \
             | grep -oE 'avg[^/]*/[0-9.]+' | grep -oE '[0-9.]+$' || echo "9999")
    printf '%d' "${result%%.*}"
}

################################################################################
# pre_flight_checks()
#
# Master pre-flight check for any operation touching remote nodes.
# Runs all applicable checks and returns 1 if ANY check fails.
#
# Usage:  pre_flight_checks <node1> [node2 ...] or with CLUSTER_NODES env var
################################################################################
pre_flight_checks() {
    local nodes=("$@")
    local ok=true

    log_info "Running pre-flight connectivity checks..."

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_warn "No nodes specified for pre-flight check"
        return 0
    fi

    check_cluster_reachability "${nodes[@]}" || ok=false

    if [[ "$ok" == "false" ]]; then
        log_error "Pre-flight checks FAILED — aborting operation"
        log_info "Use --dry-run to preview the operation without connecting"
        return 1
    fi

    log_success "Pre-flight checks passed (${#nodes[@]} node(s) reachable)"
    return 0
}

# Export for sourcing scripts
export -f check_ssh_connectivity check_cluster_reachability
export -f check_iptables_available list_active_partition_rules
export -f check_node_port measure_latency pre_flight_checks
