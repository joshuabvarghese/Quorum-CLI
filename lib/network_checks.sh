#!/usr/bin/env bash
# shellcheck shell=bash

################################################################################
# network_checks.sh — Pre-flight SSH reachability & port checks
#
# Usage (source this file, then call the functions):
#   source lib/network_checks.sh
#   pre_flight_checks 192.168.1.101 192.168.1.102
#
# Functions exported:
#   check_ssh_reachable  <host>           → 0 if SSH port open, 1 otherwise
#   check_node_port      <host> <port>    → 0 if TCP port open, 1 otherwise
#   pre_flight_checks    <host> [host…]   → summary of reachable/unreachable nodes
#   check_iptables_rules <host>           → 0 if no DROP rules present, 1 if partitioned
#   wait_for_port        <host> <port> <timeout_sec>  → polls until port is open
################################################################################

set -euo pipefail

# Ensure tput works in non-interactive (CI) environments
export TERM="${TERM:-dumb}"
IFS=$'\n\t'

# Default timeouts (override via env vars)
SSH_CONNECT_TIMEOUT=${SSH_CONNECT_TIMEOUT:-3}
PORT_CONNECT_TIMEOUT=${PORT_CONNECT_TIMEOUT:-2}
SSH_DEFAULT_PORT=${SSH_DEFAULT_PORT:-22}

# ---------------------------------------------------------------------------
# check_ssh_reachable <host>
#   Returns 0 if the SSH port on <host> is accepting TCP connections.
#   Does NOT authenticate — safe to call without credentials.
# ---------------------------------------------------------------------------
check_ssh_reachable() {
    local host="$1"

    if nc -z -w "${SSH_CONNECT_TIMEOUT}" "${host}" "${SSH_DEFAULT_PORT}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# check_node_port <host> <port>
#   Returns 0 if <host>:<port> accepts a TCP connection within PORT_CONNECT_TIMEOUT.
# ---------------------------------------------------------------------------
check_node_port() {
    local host="$1"
    local port="$2"

    if nc -z -w "${PORT_CONNECT_TIMEOUT}" "${host}" "${port}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# check_iptables_rules <host>
#   SSHes into <host> and checks for DROP rules that would indicate a
#   simulated network partition.  Returns 1 (partitioned) if DROP rules
#   matching the cluster subnet are found; 0 (clean) otherwise.
#
#   Note: requires SSH key-based auth or ssh-agent forwarding.
# ---------------------------------------------------------------------------
check_iptables_rules() {
    local host="$1"
    local ssh_user="${SSH_USER:-$(whoami)}"

    local rules
    # -o StrictHostKeyChecking=no is intentional for automation contexts;
    # in production, use known_hosts management instead.
    rules=$(ssh -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
                -o StrictHostKeyChecking=no \
                -o BatchMode=yes \
                "${ssh_user}@${host}" \
                "sudo iptables -S INPUT 2>/dev/null | grep DROP" 2>/dev/null || true)

    if [[ -n "$rules" ]]; then
        return 1   # Partitioned — DROP rules found
    else
        return 0   # Clean
    fi
}

# ---------------------------------------------------------------------------
# wait_for_port <host> <port> <timeout_sec>
#   Polls <host>:<port> every 2 seconds until it responds or <timeout_sec>
#   is reached.  Returns 0 on success, 1 on timeout.
#
#   This replaces fragile `sleep N` health checks with a real polling loop.
#   Example:
#     if ! wait_for_port 192.168.1.101 7001 60; then
#       log_error "Node did not recover within 60s"
#     fi
# ---------------------------------------------------------------------------
wait_for_port() {
    local host="$1"
    local port="$2"
    local timeout_sec="${3:-60}"
    local poll_interval=2
    local elapsed=0

    while [[ $elapsed -lt $timeout_sec ]]; do
        if check_node_port "${host}" "${port}"; then
            return 0
        fi
        sleep "${poll_interval}"
        elapsed=$(( elapsed + poll_interval ))
    done

    return 1   # Timed out
}

# ---------------------------------------------------------------------------
# pre_flight_checks <host> [host …]
#   Runs SSH + Cassandra-port (7000) reachability checks for every host
#   supplied.  Prints a summary table and returns 1 if any host is
#   unreachable, 0 if all are reachable.
#
#   Example output:
#     PRE-FLIGHT NODE REACHABILITY CHECK
#     ────────────────────────────────────────────────
#     HOST              SSH(22)   GOSSIP(7000)  STATUS
#     192.168.1.101     OK        OK            REACHABLE
#     192.168.1.102     OK        FAIL          DEGRADED
#     192.168.1.103     FAIL      FAIL          UNREACHABLE
#     ────────────────────────────────────────────────
#     Result: 1/3 hosts fully reachable — PREFLIGHT FAILED
# ---------------------------------------------------------------------------
pre_flight_checks() {
    local hosts=("$@")
    local total=${#hosts[@]}
    local ok_count=0

    echo ""
    printf "  %-20s %-12s %-14s %s\n" "HOST" "SSH(22)" "GOSSIP(7000)" "STATUS"
    echo "  ──────────────────────────────────────────────────────"

    for host in "${hosts[@]}"; do
        local ssh_ok="FAIL"
        local port_ok="FAIL"
        local row_status="UNREACHABLE"

        if check_ssh_reachable "${host}"; then
            ssh_ok="OK"
        fi

        if check_node_port "${host}" 7000; then
            port_ok="OK"
        fi

        if [[ "$ssh_ok" == "OK" && "$port_ok" == "OK" ]]; then
            row_status="REACHABLE"
            (( ok_count++ )) || true
        elif [[ "$ssh_ok" == "OK" || "$port_ok" == "OK" ]]; then
            row_status="DEGRADED"
        fi

        printf "  %-20s %-12s %-14s %s\n" "${host}" "${ssh_ok}" "${port_ok}" "${row_status}"
    done

    echo "  ──────────────────────────────────────────────────────"

    if [[ $ok_count -eq $total ]]; then
        echo "  Result: ${ok_count}/${total} hosts fully reachable — PREFLIGHT OK"
        echo ""
        return 0
    else
        echo "  Result: ${ok_count}/${total} hosts fully reachable — PREFLIGHT FAILED"
        echo ""
        return 1
    fi
}

# Export every function so child processes (BATS, subshells) can use them.
export -f check_ssh_reachable check_node_port check_iptables_rules
export -f wait_for_port pre_flight_checks
