#!/usr/bin/env bash

################################################################################
# Logger Library - Consistent logging across all scripts
# Includes JSON structured logging for ELK/Grafana Loki/Elasticsearch pipelines
################################################################################

set -euo pipefail
IFS=$'\n\t'

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# Log levels
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# Current log level (can be overridden)
LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# Log file (can be overridden)
LOG_FILE=${LOG_FILE:-"/tmp/cluster-manager.log"}

# JSON log file — separate stream for machine-readable output
JSON_LOG_FILE=${JSON_LOG_FILE:-"/tmp/cluster-manager.json.log"}

################################################################################
# Structured JSON logging — compatible with ELK / Grafana Loki
#
# Usage:   log_json "INFO" "Quorum achieved with 3/5 nodes"
# Output:  {"timestamp":"2026-02-22T10:00:00Z","level":"INFO","message":"..."}
#
# Pipe to Elasticsearch:
#   ./bin/cluster-manager.sh status 2>&1 | tee >(cat >&2) >> cluster.json.log
################################################################################
log_json() {
    local level="${1:-INFO}"
    local msg="${2:-}"
    printf '{"timestamp":"%s","level":"%s","message":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$level" \
        "$msg" >> "${JSON_LOG_FILE}"
}

################################################################################
# Human-readable logging functions
################################################################################

_log() {
    local level="$1"
    local level_num="$2"
    local color="$3"
    shift 3
    local message="$*"

    if [[ $level_num -lt $LOG_LEVEL ]]; then
        return
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "${color}[${level}]${COLOR_RESET} ${message}" >&2

    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    fi

    log_json "${level}" "${message}"
}

log_debug()   { _log "DEBUG"   "$LOG_LEVEL_DEBUG" "$COLOR_CYAN"    "$@"; }
log_info()    { _log "INFO "   "$LOG_LEVEL_INFO"  "$COLOR_BLUE"    "$@"; }
log_warn()    { _log "WARN "   "$LOG_LEVEL_WARN"  "$COLOR_YELLOW"  "$@"; }
log_error()   { _log "ERROR"   "$LOG_LEVEL_ERROR" "$COLOR_RED"     "$@"; }
log_success() { _log "SUCCESS" "$LOG_LEVEL_INFO"  "$COLOR_GREEN"   "$@"; }

################################################################################
# Progress indicators
################################################################################

show_spinner() {
    local pid=$1
    local message="${2:-Processing}"
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r[%c] %s" "$spinstr" "$message"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
    done
    printf "\r%s\n" "$(tput el)"
}

show_progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    printf "\r["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %d%%" "$percentage"
    if [[ $current -eq $total ]]; then echo ""; fi
}

################################################################################
# Section helpers
################################################################################

log_section() {
    local title="$1"
    echo ""
    echo "$(tput bold)═══════════════════════════════════════════════════════════════$(tput sgr0)"
    echo "$(tput bold)  $title$(tput sgr0)"
    echo "$(tput bold)═══════════════════════════════════════════════════════════════$(tput sgr0)"
    echo ""
}

log_separator() {
    echo "───────────────────────────────────────────────────────────────"
}

export -f log_debug log_info log_warn log_error log_success log_json
export -f show_spinner show_progress_bar log_section log_separator
