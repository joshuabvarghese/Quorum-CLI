#!/usr/bin/env bash
################################################################################
# Docker Chaos Integration Test — Real iptables Network Partition
#
# Unlike the unit tests that simulate node failure by editing JSON, this test:
#   1. Spins up N Docker containers (one per node) on a dedicated bridge network
#   2. Uses real iptables DROP rules to isolate a minority partition
#   3. Verifies that quorum is LOST when too many nodes are cut off
#   4. Heals the partition and verifies quorum is RECOVERED
#   5. Cleans up all containers and iptables rules on exit (even on failure)
#
# Requirements:
#   - Docker (Engine or Desktop) with bridge networking
#   - iptables available on the host (Linux only; Docker Desktop on macOS uses
#     a Linux VM so iptables commands run inside a privileged container instead)
#   - Run as root or with sufficient CAP_NET_ADMIN privileges
#
# Usage:
#   sudo ./tests/docker-chaos-integration.sh [--nodes 5] [--verbose]
#
# Exit codes:
#   0  All assertions passed
#   1  One or more assertions failed
#   2  Setup/teardown error (Docker unavailable, etc.)
################################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NODES="${NODES:-5}"                     # Total cluster nodes
QUORUM=$(( NODES / 2 + 1 ))            # Majority quorum threshold
NETWORK_NAME="quorum-chaos-$$"         # Unique bridge per run
IMAGE="alpine:3.19"                     # Minimal image with sh + nc + iptables
CONTAINER_PREFIX="qnode-$$"
PARTITION_HEAL_WAIT=3                   # Seconds to wait after healing
IPTABLES_VERIFY_WAIT=1                  # Seconds for rules to propagate

# Colours
R=$'\033[0m' B=$'\033[1m' GN=$'\033[92m' RD=$'\033[91m' YL=$'\033[93m' CY=$'\033[96m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { printf "  ${CY}[INFO]${R}  %s\n" "$*"; }
ok()      { printf "  ${GN}[PASS]${R}  %s\n" "$*"; }
fail()    { printf "  ${RD}[FAIL]${R}  %s\n" "$*"; FAILURES=$(( FAILURES + 1 )); }
section() { printf "\n${B}%s${R}\n%s\n" "$*" "$(printf '─%.0s' {1..70})"; }

FAILURES=0
CONTAINERS=()
CONTAINER_IPS=()

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
    section "Checking prerequisites"

    if ! command -v docker &>/dev/null; then
        printf "${RD}ERROR:${R} Docker not found in PATH.\n"
        exit 2
    fi

    if ! docker info &>/dev/null; then
        printf "${RD}ERROR:${R} Docker daemon not reachable. Is Docker running?\n"
        exit 2
    fi

    # iptables may run inside a privileged helper container on macOS/non-Linux.
    # On Linux, check the host.
    if [[ "$(uname -s)" == "Linux" ]]; then
        if ! command -v iptables &>/dev/null; then
            printf "${RD}ERROR:${R} iptables not found. Install iptables or run as root.\n"
            exit 2
        fi
        if ! iptables -L -n &>/dev/null; then
            printf "${RD}ERROR:${R} Cannot list iptables rules — try running with sudo.\n"
            exit 2
        fi
    fi

    info "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'ok')"
    info "Nodes planned: ${NODES}  |  Quorum threshold: ${QUORUM}"
    ok "Prerequisites satisfied"
}

# ---------------------------------------------------------------------------
# Network + container lifecycle
# ---------------------------------------------------------------------------
create_network() {
    section "Creating Docker bridge network: ${NETWORK_NAME}"
    docker network create \
        --driver bridge \
        --subnet "172.28.0.0/24" \
        "$NETWORK_NAME" &>/dev/null
    info "Network created: ${NETWORK_NAME} (172.28.0.0/24)"
}

start_containers() {
    section "Starting ${NODES} node containers"

    for (( i=1; i<=NODES; i++ )); do
        local name="${CONTAINER_PREFIX}-node${i}"
        local ip="172.28.0.$(( 10 + i ))"

        docker run -d \
            --name "$name" \
            --network "$NETWORK_NAME" \
            --ip "$ip" \
            --cap-add NET_ADMIN \
            --cap-add NET_RAW \
            "$IMAGE" \
            sh -c "
                # Minimal quorum heartbeat listener on port 7000
                # Responds '1' (alive) to any TCP connection.
                while true; do
                    echo '1' | nc -l -p 7000 -q1 2>/dev/null || true
                done
            " &>/dev/null

        CONTAINERS+=( "$name" )
        CONTAINER_IPS+=( "$ip" )
        info "Started: ${name}  IP=${ip}"
    done
    ok "All ${NODES} containers running"
}

# ---------------------------------------------------------------------------
# Quorum probe: attempt TCP to port 7000 on each container
# Returns count of responding (reachable) nodes
# ---------------------------------------------------------------------------
probe_quorum() {
    local responding=0
    for ip in "${CONTAINER_IPS[@]}"; do
        if docker run --rm --network "$NETWORK_NAME" "$IMAGE" \
               sh -c "nc -z -w1 ${ip} 7000" &>/dev/null; then
            (( responding++ )) || true
        fi
    done
    echo "$responding"
}

# ---------------------------------------------------------------------------
# iptables partition helpers
# ---------------------------------------------------------------------------

# Drop all traffic FROM a set of IPs TO the rest of the cluster.
# This simulates a one-way network partition (split-brain scenario).
apply_partition() {
    local -a minority_ips=("$@")
    info "Applying iptables DROP rules for minority partition: ${minority_ips[*]}"

    for src_ip in "${minority_ips[@]}"; do
        for dst_ip in "${CONTAINER_IPS[@]}"; do
            # Skip self-to-self
            [[ "$src_ip" == "$dst_ip" ]] && continue
            # Only isolate minority → majority direction
            if ! printf '%s\n' "${minority_ips[@]}" | grep -q "^${dst_ip}$"; then
                iptables -I FORWARD -s "$src_ip" -d "$dst_ip" -j DROP 2>/dev/null || true
                iptables -I FORWARD -s "$dst_ip" -d "$src_ip" -j DROP 2>/dev/null || true
            fi
        done
    done
    sleep "$IPTABLES_VERIFY_WAIT"
}

# Remove the DROP rules we injected
heal_partition() {
    local -a minority_ips=("$@")
    info "Removing iptables DROP rules (healing partition)"

    for src_ip in "${minority_ips[@]}"; do
        for dst_ip in "${CONTAINER_IPS[@]}"; do
            [[ "$src_ip" == "$dst_ip" ]] && continue
            if ! printf '%s\n' "${minority_ips[@]}" | grep -q "^${dst_ip}$"; then
                iptables -D FORWARD -s "$src_ip" -d "$dst_ip" -j DROP 2>/dev/null || true
                iptables -D FORWARD -s "$dst_ip" -d "$src_ip" -j DROP 2>/dev/null || true
            fi
        done
    done
    sleep "$PARTITION_HEAL_WAIT"
}

# ---------------------------------------------------------------------------
# macOS / Docker Desktop: run iptables inside a privileged container instead
# of the host, since the host is a macOS Darwin kernel without iptables.
# ---------------------------------------------------------------------------
setup_iptables_fn() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        # Override apply_partition / heal_partition to run inside container
        apply_partition() {
            local -a minority_ips=("$@")
            info "[macOS mode] Using privileged container for iptables"
            for src_ip in "${minority_ips[@]}"; do
                for dst_ip in "${CONTAINER_IPS[@]}"; do
                    [[ "$src_ip" == "$dst_ip" ]] && continue
                    if ! printf '%s\n' "${minority_ips[@]}" | grep -q "^${dst_ip}$"; then
                        docker run --rm --privileged --network host alpine:3.19 \
                            sh -c "iptables -I FORWARD -s ${src_ip} -d ${dst_ip} -j DROP; \
                                   iptables -I FORWARD -s ${dst_ip} -d ${src_ip} -j DROP" \
                            2>/dev/null || true
                    fi
                done
            done
            sleep "$IPTABLES_VERIFY_WAIT"
        }

        heal_partition() {
            local -a minority_ips=("$@")
            info "[macOS mode] Removing iptables rules via privileged container"
            for src_ip in "${minority_ips[@]}"; do
                for dst_ip in "${CONTAINER_IPS[@]}"; do
                    [[ "$src_ip" == "$dst_ip" ]] && continue
                    if ! printf '%s\n' "${minority_ips[@]}" | grep -q "^${dst_ip}$"; then
                        docker run --rm --privileged --network host alpine:3.19 \
                            sh -c "iptables -D FORWARD -s ${src_ip} -d ${dst_ip} -j DROP 2>/dev/null; \
                                   iptables -D FORWARD -s ${dst_ip} -d ${src_ip} -j DROP 2>/dev/null" \
                            2>/dev/null || true
                    fi
                done
            done
            sleep "$PARTITION_HEAL_WAIT"
        }
    fi
}

# ---------------------------------------------------------------------------
# Cleanup — always runs, even on error
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    section "Cleanup"

    # Remove any lingering iptables rules we may have added
    for src_ip in "${CONTAINER_IPS[@]}"; do
        for dst_ip in "${CONTAINER_IPS[@]}"; do
            [[ "$src_ip" == "$dst_ip" ]] && continue
            iptables -D FORWARD -s "$src_ip" -d "$dst_ip" -j DROP 2>/dev/null || true
        done
    done

    # Stop and remove containers
    for name in "${CONTAINERS[@]}"; do
        docker rm -f "$name" &>/dev/null || true
        info "Removed container: ${name}"
    done

    # Remove network
    docker network rm "$NETWORK_NAME" &>/dev/null || true
    info "Removed network: ${NETWORK_NAME}"

    if [[ $FAILURES -eq 0 && $exit_code -eq 0 ]]; then
        printf "\n${GN}${B}✓ All assertions passed — chaos integration test PASSED${R}\n\n"
    else
        printf "\n${RD}${B}✗ %d assertion(s) failed — chaos integration test FAILED${R}\n\n" "$FAILURES"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test assertions
# ---------------------------------------------------------------------------

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        ok "${label}: got ${actual} (expected ${expected})"
    else
        fail "${label}: got ${actual} (expected ${expected})"
    fi
}

assert_ge() {
    local label="$1" actual="$2" threshold="$3"
    if [[ "$actual" -ge "$threshold" ]]; then
        ok "${label}: ${actual} >= ${threshold}"
    else
        fail "${label}: ${actual} < ${threshold} (quorum not reached)"
    fi
}

assert_lt() {
    local label="$1" actual="$2" threshold="$3"
    if [[ "$actual" -lt "$threshold" ]]; then
        ok "${label}: ${actual} < ${threshold} (quorum correctly lost)"
    else
        fail "${label}: ${actual} >= ${threshold} (quorum should have been lost)"
    fi
}

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

run_tests() {
    # --- T1: Baseline — all nodes reachable ---
    section "T1: Baseline — all nodes should be reachable"
    local baseline
    baseline=$(probe_quorum)
    assert_eq "Reachable nodes (baseline)" "$baseline" "$NODES"

    # --- T2: Majority partition — quorum must still hold ---
    # Isolate a strict minority (floor(n/2) nodes).
    # The remaining majority can still achieve quorum.
    section "T2: Majority partition — quorum must survive"
    local minority_count=$(( NODES / 2 ))
    local -a minority_ips=()
    for (( i=0; i<minority_count; i++ )); do
        minority_ips+=( "${CONTAINER_IPS[$i]}" )
    done

    info "Partitioning ${minority_count} node(s) (minority): ${minority_ips[*]}"
    apply_partition "${minority_ips[@]}"

    local after_partition_majority
    after_partition_majority=$(probe_quorum)
    # Majority nodes are still reachable from the probe container
    assert_ge "Reachable nodes after majority partition" \
        "$after_partition_majority" "$QUORUM"

    heal_partition "${minority_ips[@]}"

    # --- T3: Minority partition — quorum must be LOST ---
    # Isolate enough nodes so that the remaining reachable count drops below
    # the quorum threshold.  We isolate QUORUM nodes (i.e. just over half).
    section "T3: Quorum-breaking partition — quorum must be LOST"
    local breaking_count=$QUORUM
    local -a breaking_ips=()
    for (( i=0; i<breaking_count; i++ )); do
        breaking_ips+=( "${CONTAINER_IPS[$i]}" )
    done

    info "Partitioning ${breaking_count} node(s) (quorum-breaking): ${breaking_ips[*]}"
    apply_partition "${breaking_ips[@]}"

    local after_breaking
    after_breaking=$(probe_quorum)
    assert_lt "Reachable nodes during quorum-breaking partition" \
        "$after_breaking" "$QUORUM"

    # --- T4: Heal — quorum must recover ---
    section "T4: Heal partition — quorum must RECOVER"
    heal_partition "${breaking_ips[@]}"

    local after_heal
    after_heal=$(probe_quorum)
    assert_ge "Reachable nodes after heal" "$after_heal" "$QUORUM"
    assert_eq "Full node recovery" "$after_heal" "$NODES"

    # --- T5: Single-node failure (kill container) ---
    section "T5: Single-node hard failure (docker stop) — quorum must survive"
    local victim="${CONTAINERS[$(( NODES - 1 ))]}"
    info "Stopping container: ${victim}"
    docker stop "$victim" &>/dev/null

    local after_kill
    after_kill=$(probe_quorum)
    assert_ge "Reachable nodes after single-node kill" "$after_kill" "$QUORUM"

    info "Restarting container: ${victim}"
    docker start "$victim" &>/dev/null
    sleep 1

    local after_restart
    after_restart=$(probe_quorum)
    assert_eq "Full recovery after node restart" "$after_restart" "$NODES"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Parse CLI flags
VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes) NODES="$2"; QUORUM=$(( NODES / 2 + 1 )); shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        *) printf "Unknown flag: %s\n" "$1"; exit 2 ;;
    esac
done

printf "\n${B}${CY}Quorum-CLI — Docker Chaos Integration Test${R}\n"
printf "Nodes: %d  |  Quorum threshold: %d\n\n" "$NODES" "$QUORUM"

check_prerequisites
setup_iptables_fn
create_network
start_containers
run_tests

# Exit code driven by FAILURES counter (cleanup prints final verdict)
exit $FAILURES
