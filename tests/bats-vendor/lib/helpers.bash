#!/usr/bin/env bash
# bats helpers — sourced into each test's subshell

# Re-export the core assertion functions
assert_success() {
    if [[ $status -ne 0 ]]; then
        echo "Expected success but got exit status $status"
        [[ -n "${output:-}" ]] && echo "Output was: $output"
        return 1
    fi
}

assert_failure() {
    if [[ $status -eq 0 ]]; then
        echo "Expected failure but command succeeded"
        [[ -n "${output:-}" ]] && echo "Output was: $output"
        return 1
    fi
}

assert_output() {
    local expected="${1:-}"
    if [[ "$output" != *"$expected"* ]]; then
        printf "Expected output to contain:\n  %s\nActual output:\n  %s\n" "$expected" "$output"
        return 1
    fi
}

assert_output_not() {
    local unexpected="${1:-}"
    if [[ "$output" == *"$unexpected"* ]]; then
        printf "Expected output NOT to contain:\n  %s\nActual output:\n  %s\n" "$unexpected" "$output"
        return 1
    fi
}

assert_equal() {
    if [[ "$1" != "$2" ]]; then
        printf "Expected '%s' to equal '%s'\n" "$1" "$2"
        return 1
    fi
}

assert_file_exists() {
    if [[ ! -f "$1" ]]; then
        echo "Expected file to exist: $1"
        return 1
    fi
}

assert_dir_exists() {
    if [[ ! -d "$1" ]]; then
        echo "Expected directory to exist: $1"
        return 1
    fi
}

assert_line() {
    local expected="$1"
    local found=false
    for line in "${lines[@]:-}"; do
        if [[ "$line" == *"$expected"* ]]; then
            found=true
            break
        fi
    done
    if [[ "$found" == "false" ]]; then
        echo "Expected a line containing: $expected"
        echo "Lines were:"
        printf '  %s\n' "${lines[@]:-}"
        return 1
    fi
}

run() {
    local cmd=("$@")
    output=""
    status=0
    set +e
    output=$("${cmd[@]}" 2>&1)
    status=$?
    set -e
    IFS=$'\n' read -ra lines <<< "$output" 2>/dev/null || lines=("$output")
}

skip() {
    echo "SKIP: ${1:-}"
    exit 0
}
