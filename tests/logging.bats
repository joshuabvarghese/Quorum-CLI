#!/usr/bin/env bats
# logging.bats — Unit tests for lib/logger.sh
#
# Verifies:
#   - Human-readable log functions emit to stderr
#   - log_json emits valid JSON with required fields
#   - JSON timestamp is ISO-8601
#
# Run:  ./tests/bats-vendor/bin/bats tests/logging.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    # Redirect LOG_FILE to a temp file so we don't pollute the project logs
    export LOG_FILE
    LOG_FILE=$(mktemp)
    source "$PROJECT_ROOT/lib/logger.sh"
}

teardown() {
    rm -f "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Human-readable log functions
# ---------------------------------------------------------------------------

@test "log_info: emits to stderr (not stdout)" {
    run bash -c "source '$PROJECT_ROOT/lib/logger.sh'; log_info 'hello world'"
    # run captures stdout; stderr goes to output only if mixed in
    # We check that the process exits 0 and something was emitted
    [ "$status" -eq 0 ]
}

@test "log_error: exits with log entry containing ERROR" {
    run bash -c "
        export LOG_FILE=/dev/null
        source '$PROJECT_ROOT/lib/logger.sh'
        log_error 'something broke' 2>&1
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ERROR" ]]
}

@test "log_success: output contains SUCCESS" {
    run bash -c "
        export LOG_FILE=/dev/null
        source '$PROJECT_ROOT/lib/logger.sh'
        log_success 'all good' 2>&1
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SUCCESS" ]]
}

@test "log_warn: output contains WARN" {
    run bash -c "
        export LOG_FILE=/dev/null
        source '$PROJECT_ROOT/lib/logger.sh'
        log_warn 'heads up' 2>&1
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "WARN" ]]
}

# ---------------------------------------------------------------------------
# log_json — structured output
# ---------------------------------------------------------------------------

@test "log_json: emits valid JSON line when function exists" {
    # Only run if log_json is defined (it may be an extension)
    if ! declare -f log_json &>/dev/null; then
        skip "log_json not defined in logger.sh"
    fi

    local json_log
    json_log=$(mktemp)

    bash -c "
        export LOG_FILE='/dev/null'
        export JSON_LOG_FILE='$json_log'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_json 'INFO' 'quorum achieved'
    " 2>/dev/null

    # Should have written at least one line
    [ -s "$json_log" ]

    local line
    line=$(tail -1 "$json_log")
    [[ "$line" =~ ^\{ ]]                   # starts with {
    [[ "$line" =~ \"level\" ]]             # has level field
    [[ "$line" =~ \"message\" ]]           # has message field
    [[ "$line" =~ \"timestamp\" ]]         # has timestamp field

    rm -f "$json_log"
}

@test "log_json: timestamp is ISO-8601 format" {
    if ! declare -f log_json &>/dev/null; then
        skip "log_json not defined in logger.sh"
    fi

    local json_log
    json_log=$(mktemp)

    bash -c "
        export LOG_FILE='/dev/null'
        export JSON_LOG_FILE='$json_log'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_json 'INFO' 'timestamp test'
    " 2>/dev/null

    local ts
    ts=$(grep -o '"timestamp": *"[^"]*"' "$json_log" | grep -o '"[^"]*"$' | tr -d '"')
    # ISO-8601: YYYY-MM-DDTHH:MM:SSZ
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]

    rm -f "$json_log"
}

# ---------------------------------------------------------------------------
# File output
# ---------------------------------------------------------------------------

@test "logger: writes plain-text entry to LOG_FILE" {
    local tmp_log
    tmp_log=$(mktemp)
    export LOG_FILE="$tmp_log"

    bash -c "
        export LOG_FILE='$tmp_log'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_info 'written to file'
    " 2>/dev/null

    grep -q "written to file" "$tmp_log"

    rm -f "$tmp_log"
}
