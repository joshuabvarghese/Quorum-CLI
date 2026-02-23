#!/usr/bin/env bash
# ============================================================================
# logging.bats — Tests for the logging framework
# ============================================================================

setup() {
    export BATS_TMPDIR
    BATS_TMPDIR=$(mktemp -d)
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
    export LOG_FILE="$BATS_TMPDIR/test.log"
    export JSON_LOG_FILE="$BATS_TMPDIR/test.json.log"
}

teardown() {
    rm -rf "$BATS_TMPDIR"
}

@test "logger: log_json emits valid JSON" {
    bash -c "
        export LOG_FILE='$LOG_FILE'
        export JSON_LOG_FILE='$JSON_LOG_FILE'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_json 'INFO' 'Quorum achieved with 3/5 nodes'
    "
    run cat "$JSON_LOG_FILE"
    assert_success
    assert_output '"level":"INFO"'
    assert_output '"message":"Quorum achieved with 3/5 nodes"'
}

@test "logger: log_json includes timestamp in ISO8601 format" {
    bash -c "
        export LOG_FILE='$LOG_FILE'
        export JSON_LOG_FILE='$JSON_LOG_FILE'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_json 'WARN' 'node-2 is unreachable'
    "
    run cat "$JSON_LOG_FILE"
    assert_success
    # Should match "timestamp":"2026-..." pattern
    assert_output '"timestamp":"20'
}

@test "logger: log_info writes to human log file" {
    bash -c "
        export LOG_FILE='$LOG_FILE'
        export JSON_LOG_FILE='$JSON_LOG_FILE'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_info 'test message from bats'
    " 2>/dev/null
    run cat "$LOG_FILE"
    assert_success
    assert_output "test message from bats"
}

@test "logger: log_warn writes to human log file" {
    bash -c "
        export LOG_FILE='$LOG_FILE'
        export JSON_LOG_FILE='$JSON_LOG_FILE'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_warn 'warning from bats'
    " 2>/dev/null
    run cat "$LOG_FILE"
    assert_success
    assert_output "warning from bats"
}

@test "logger: multiple log_json calls produce multiple JSON lines" {
    bash -c "
        export LOG_FILE='$LOG_FILE'
        export JSON_LOG_FILE='$JSON_LOG_FILE'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_json 'INFO' 'line one'
        log_json 'WARN' 'line two'
        log_json 'ERROR' 'line three'
    "
    local count
    count=$(wc -l < "$JSON_LOG_FILE")
    [[ $count -eq 3 ]]
}

@test "logger: log_json handles special characters in message" {
    bash -c "
        export LOG_FILE='$LOG_FILE'
        export JSON_LOG_FILE='$JSON_LOG_FILE'
        source '$PROJECT_ROOT/lib/logger.sh'
        log_json 'INFO' 'cluster cls-001: 3/5 nodes healthy'
    "
    run cat "$JSON_LOG_FILE"
    assert_output "cls-001"
}
