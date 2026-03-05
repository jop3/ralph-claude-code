#!/usr/bin/env bats
# Unit Tests for Ralph Scheduling (--start / --stop flags)

load '../helpers/test_helper'

SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-sched.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"

    # Source just the functions we need from ralph_loop.sh
    # We extract them to avoid running the full script
    source "${SCRIPT_DIR}/lib/date_utils.sh"

    # Define the functions inline by sourcing the relevant section
    # parse_time_hhmm, current_time_seconds, should_stop_for_schedule
    eval "$(sed -n '/^parse_time_hhmm()/,/^}/p' "${SCRIPT_DIR}/ralph_loop.sh")"
    eval "$(sed -n '/^current_time_seconds()/,/^}/p' "${SCRIPT_DIR}/ralph_loop.sh")"
    eval "$(sed -n '/^should_stop_for_schedule()/,/^}/p' "${SCRIPT_DIR}/ralph_loop.sh")"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# =============================================================================
# parse_time_hhmm tests
# =============================================================================

@test "parse_time_hhmm: parses 23:00 correctly" {
    run parse_time_hhmm "23:00"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 82800 ]]
}

@test "parse_time_hhmm: parses 00:00 correctly" {
    run parse_time_hhmm "00:00"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 0 ]]
}

@test "parse_time_hhmm: parses 06:30 correctly" {
    run parse_time_hhmm "06:30"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 23400 ]]
}

@test "parse_time_hhmm: parses single-digit hour 9:15" {
    run parse_time_hhmm "9:15"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 33300 ]]
}

@test "parse_time_hhmm: rejects invalid format" {
    run parse_time_hhmm "2300"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Invalid time format"* ]]
}

@test "parse_time_hhmm: rejects hours > 23" {
    run parse_time_hhmm "25:00"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Invalid time"* ]]
}

@test "parse_time_hhmm: rejects minutes > 59" {
    run parse_time_hhmm "12:60"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Invalid time"* ]]
}

@test "parse_time_hhmm: rejects text input" {
    run parse_time_hhmm "noon"
    [[ "$status" -eq 1 ]]
}

# =============================================================================
# current_time_seconds tests
# =============================================================================

@test "current_time_seconds: returns a number" {
    run current_time_seconds
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "current_time_seconds: returns value in valid range" {
    local result=$(current_time_seconds)
    [[ $result -ge 0 ]]
    [[ $result -lt 86400 ]]
}

# =============================================================================
# should_stop_for_schedule tests
# =============================================================================

@test "should_stop_for_schedule: returns 1 when no stop time set" {
    export SCHEDULE_STOP=""
    run should_stop_for_schedule
    [[ "$status" -eq 1 ]]
}

@test "should_stop_for_schedule: same-day stop — returns 0 when past stop time" {
    export SCHEDULE_START=""
    # Set stop to 00:01 (1 minute past midnight) — current time is always >= 00:01 unless running at midnight
    # Use a time that's definitely in the past
    local now_h=$(date +%H)
    local now_m=$(date +%M)
    # Stop time = 1 minute ago
    if [[ $((10#$now_m)) -gt 0 ]]; then
        export SCHEDULE_STOP="${now_h}:$(printf '%02d' $((10#$now_m - 1)))"
    else
        # At :00, use previous hour
        local prev_h=$(printf '%02d' $(( (10#$now_h + 23) % 24 )))
        export SCHEDULE_STOP="${prev_h}:59"
    fi

    run should_stop_for_schedule
    [[ "$status" -eq 0 ]]
}

@test "should_stop_for_schedule: same-day stop — returns 1 when before stop time" {
    export SCHEDULE_START=""
    export SCHEDULE_STOP="23:59"

    # Only expect this to pass if we're not at 23:59
    local now_secs=$(current_time_seconds)
    local stop_secs=$((23 * 3600 + 59 * 60))
    if [[ $now_secs -lt $stop_secs ]]; then
        run should_stop_for_schedule
        [[ "$status" -eq 1 ]]
    else
        skip "Running too close to 23:59"
    fi
}

@test "should_stop_for_schedule: overnight — correctly handles wrap-around" {
    # Simulate overnight run: start=23:00, stop=06:00
    export SCHEDULE_START="23:00"
    export SCHEDULE_STOP="06:00"

    # If current time is between 06:00 and 23:00, should stop
    local now_secs=$(current_time_seconds)
    local stop_secs=$((6 * 3600))
    local start_secs=$((23 * 3600))

    if [[ $now_secs -ge $stop_secs && $now_secs -lt $start_secs ]]; then
        run should_stop_for_schedule
        [[ "$status" -eq 0 ]]
    else
        # During the active window, should NOT stop
        run should_stop_for_schedule
        [[ "$status" -eq 1 ]]
    fi
}
