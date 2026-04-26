################################################################################
# ssh-hardening.sh — SSH configuration helpers for Quorum-CLI
#
# Provides:
#   ssh_run <host> <command>     — hardened SSH with connection pooling
#   scp_push <host> <src> <dst> — hardened SCP
#   ssh_check_reachable <host>  — liveness probe (exit 0 = reachable)
#
# Security decisions explained:
#
#   StrictHostKeyChecking=accept-new
#     Accepts a new host key on first connection and pins it to known_hosts.
#     Rejects changed keys (MITM protection) without requiring manual
#     intervention on first connect.  "no" is common but wrong — it silently
#     accepts key changes.
#
#   ControlMaster / ControlPath / ControlPersist
#     SSH connection multiplexing.  After the first connection to a host, all
#     subsequent ssh_run calls reuse the same TCP connection (no new TLS
#     handshake, no new password/key auth).  This is the "connection pooling"
#     equivalent for SSH.  ControlPersist=60 keeps the master alive 60 s
#     after the last session closes, covering burst scenarios.
#
#   ServerAliveInterval / ServerAliveCountMax
#     Sends a keepalive every 15 s; drops the connection after 3 missed
#     replies (45 s total).  Prevents silent hangs when a node goes away.
#
#   BatchMode=yes
#     Disables password prompts — any auth failure becomes an immediate error
#     rather than a blocking prompt.  Required for non-interactive scripts.
#
#   ConnectTimeout=5
#     Fails fast on unreachable hosts instead of waiting for the OS TCP
#     timeout (~75 s on Linux).  Tune down in LAN environments.
#
#   User / IdentityFile
#     Read from environment so callers can override without touching this
#     file.  Defaults are SSH_USER (default: current user) and SSH_KEY
#     (default: ~/.ssh/id_ed25519 then ~/.ssh/id_rsa).
################################################################################

# Guard against double-sourcing
[[ -n "${_SSH_HARDENING_SH_SOURCED:-}" ]] && return 0
readonly _SSH_HARDENING_SH_SOURCED=1

# ---------------------------------------------------------------------------
# Defaults — all overridable via environment
# ---------------------------------------------------------------------------
SSH_USER="${SSH_USER:-$(id -un)}"
SSH_PORT="${SSH_PORT:-22}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
SSH_SERVER_ALIVE_INTERVAL="${SSH_SERVER_ALIVE_INTERVAL:-15}"
SSH_SERVER_ALIVE_COUNT="${SSH_SERVER_ALIVE_COUNT:-3}"
SSH_CONTROL_PERSIST="${SSH_CONTROL_PERSIST:-60}"

# Key selection: prefer Ed25519, fall back to RSA
if [[ -z "${SSH_KEY:-}" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
        SSH_KEY="$HOME/.ssh/id_ed25519"
    elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
        SSH_KEY="$HOME/.ssh/id_rsa"
    else
        SSH_KEY=""
    fi
fi

# ControlPath socket directory — use runtime dir if available, else /tmp
_SSH_CONTROL_DIR="${XDG_RUNTIME_DIR:-/tmp}/quorum-ssh-mux"
mkdir -p "$_SSH_CONTROL_DIR"
chmod 700 "$_SSH_CONTROL_DIR"

# ---------------------------------------------------------------------------
# Base SSH options array — shared by ssh_run, scp_push, ssh_check_reachable
# ---------------------------------------------------------------------------
_ssh_base_opts() {
    local -a opts=(
        -o "StrictHostKeyChecking=accept-new"
        -o "BatchMode=yes"
        -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
        -o "ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL}"
        -o "ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT}"
        -o "ControlMaster=auto"
        -o "ControlPath=${_SSH_CONTROL_DIR}/%h_%p_%r"
        -o "ControlPersist=${SSH_CONTROL_PERSIST}"
        -p "$SSH_PORT"
        -l "$SSH_USER"
    )
    [[ -n "$SSH_KEY" ]] && opts+=( -i "$SSH_KEY" )
    printf '%s\n' "${opts[@]}"
}

# ---------------------------------------------------------------------------
# ssh_run <host> <command...>
# Runs <command> on <host> over a multiplexed SSH connection.
# ---------------------------------------------------------------------------
ssh_run() {
    local host="$1"; shift
    local -a opts
    mapfile -t opts < <(_ssh_base_opts)
    ssh "${opts[@]}" "$host" "$@"
}

# ---------------------------------------------------------------------------
# scp_push <host> <local_src> <remote_dst>
# ---------------------------------------------------------------------------
scp_push() {
    local host="$1" src="$2" dst="$3"
    local -a opts
    mapfile -t opts < <(_ssh_base_opts)
    scp "${opts[@]}" "$src" "${host}:${dst}"
}

# ---------------------------------------------------------------------------
# ssh_check_reachable <host>
# Returns 0 if host is reachable via SSH, 1 otherwise.
# Uses a very short timeout so callers can fan out health checks in parallel.
# ---------------------------------------------------------------------------
ssh_check_reachable() {
    local host="$1"
    local -a opts
    mapfile -t opts < <(_ssh_base_opts)
    # Override connect timeout to 3 s for health probes specifically
    local -a probe_opts=()
    for opt in "${opts[@]}"; do
        [[ "$opt" =~ ConnectTimeout ]] && continue
        probe_opts+=("$opt")
    done
    probe_opts+=( -o "ConnectTimeout=3" )

    ssh "${probe_opts[@]}" "$host" "exit 0" &>/dev/null
}

# ---------------------------------------------------------------------------
# ssh_run_parallel <command> <host1> [host2 ...]
# Runs <command> on all hosts concurrently; waits for all; returns 0 only if
# every host succeeded.
#
# Example:
#   ssh_run_parallel "systemctl restart cassandra" 10.0.0.1 10.0.0.2 10.0.0.3
# ---------------------------------------------------------------------------
ssh_run_parallel() {
    local cmd="$1"; shift
    local -a hosts=("$@")
    local -a pids=()
    local -a results=()

    for host in "${hosts[@]}"; do
        ssh_run "$host" "$cmd" &
        pids+=($!)
    done

    local all_ok=true
    local idx=0
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            results+=("${hosts[$idx]}: OK")
        else
            results+=("${hosts[$idx]}: FAILED")
            all_ok=false
        fi
        (( idx++ )) || true
    done

    for r in "${results[@]}"; do
        echo "  $r"
    done

    $all_ok
}

# ---------------------------------------------------------------------------
# ssh_close_mux <host>
# Explicitly closes the ControlMaster socket for <host>.
# Call during teardown to avoid leaving stale sockets.
# ---------------------------------------------------------------------------
ssh_close_mux() {
    local host="$1"
    local -a opts
    mapfile -t opts < <(_ssh_base_opts)
    ssh "${opts[@]}" -O exit "$host" &>/dev/null || true
}
