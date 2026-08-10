#!/usr/bin/env bash

################################################################################
# Logger Library - Consistent logging across all scripts
################################################################################

# Guard against double-sourcing
[[ -n "${_LOGGER_SH_SOURCED:-}" ]] && return 0
readonly _LOGGER_SH_SOURCED=1

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_MAGENTA='\033[0;35m'
export COLOR_MAGENTA
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'
export COLOR_BOLD

# Log levels
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# Current log level (can be overridden)
LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# Log file (can be overridden)
LOG_FILE=${LOG_FILE:-"/tmp/cluster-manager.log"}

# JSON log file (can be overridden). Derived from LOG_FILE so
# logs/cluster/cluster-manager.log gets a logs/cluster/cluster-manager.json.log
# sibling automatically. Left unset for LOG_FILE=/dev/null (tests, --quiet
# runs) so _log doesn't try to write a stray "/dev/null.json.log".
if [[ -n "$LOG_FILE" && "$LOG_FILE" != "/dev/null" ]]; then
    JSON_LOG_FILE=${JSON_LOG_FILE:-"${LOG_FILE%.log}.json.log"}
else
    JSON_LOG_FILE=${JSON_LOG_FILE:-}
fi

################################################################################
# Logging functions
################################################################################

# json_escape <string>
#   Escapes backslashes and double quotes for embedding in a JSON string.
#   Not a full JSON encoder — log messages don't carry control characters
#   or unicode escapes, so this covers what actually shows up in practice.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# log_json <level> <message...>
#   Appends one line of {"timestamp","level","message"} to JSON_LOG_FILE.
#   Timestamp is UTC ISO-8601 (2026-02-22T10:00:00Z), independent of the
#   local-time format used in the plain-text log. Safe to call even when
#   JSON_LOG_FILE is unset or unwritable — never trips set -e.
log_json() {
    local level="$1"
    shift
    local message="$*"

    [[ -n "${JSON_LOG_FILE:-}" ]] || return 0

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local escaped
    escaped=$(json_escape "$message")

    { echo "{\"timestamp\":\"${timestamp}\",\"level\":\"${level}\",\"message\":\"${escaped}\"}" >> "$JSON_LOG_FILE"; } 2>/dev/null || true
}

_log() {
    local level="$1"
    local level_num="$2"
    local color="$3"
    shift 3
    local message="$*"
    
    # Check if we should log this level
    if [[ $level_num -lt $LOG_LEVEL ]]; then
        return
    fi
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Console output with color
    echo -e "${color}[${level}]${COLOR_RESET} ${message}" >&2
    
    # File output without color
    if [[ -n "$LOG_FILE" ]]; then
        echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    fi

    # Structured JSON sibling — same event, machine-readable
    log_json "${level% }" "$message"
}

log_debug() {
    _log "DEBUG" "$LOG_LEVEL_DEBUG" "$COLOR_CYAN" "$@"
}

log_info() {
    _log "INFO " "$LOG_LEVEL_INFO" "$COLOR_BLUE" "$@"
}

log_warn() {
    _log "WARN " "$LOG_LEVEL_WARN" "$COLOR_YELLOW" "$@"
}

log_error() {
    _log "ERROR" "$LOG_LEVEL_ERROR" "$COLOR_RED" "$@"
}

log_success() {
    _log "SUCCESS" "$LOG_LEVEL_INFO" "$COLOR_GREEN" "$@"
}

################################################################################
# Progress indicators
################################################################################

show_spinner() {
    local pid=$1
    local message="${2:-Processing}"
    local spinstr='/-\|'
    
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
    
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

################################################################################
# Helper functions
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

# Export functions
export -f log_debug log_info log_warn log_error log_success
export -f json_escape log_json
export -f show_spinner show_progress_bar
export -f log_section log_separator
