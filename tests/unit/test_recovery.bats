#!/usr/bin/env bats
# Unit Tests for Recovery Strategies (Ouroboros-inspired features)
# Tests: loop history, stagnation detection, recovery attempts, drift detection

load '../helpers/test_helper'

SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../lib"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-recovery.XXXXXX)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export RECOVERY_MAX_ATTEMPTS=2
    export DRIFT_THRESHOLD=15
    mkdir -p "$RALPH_DIR"

    # Source libraries
    source "$SCRIPT_DIR/date_utils.sh"
    source "$SCRIPT_DIR/circuit_breaker.sh"
    source "$SCRIPT_DIR/recovery.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: Create a mock response analysis file
create_mock_analysis() {
    local work_summary="${1:-did some work}"
    local files_modified="${2:-3}"
    local confidence="${3:-80}"
    cat > "$RALPH_DIR/.response_analysis" << EOF
{
    "analysis": {
        "work_summary": "$work_summary",
        "files_modified": $files_modified,
        "confidence": $confidence,
        "has_completion_signal": false,
        "exit_signal": false
    }
}
EOF
}

# Helper: Create loop history with specific hashes
create_history_with_hashes() {
    local json="["
    local i=0
    for hash in "$@"; do
        [[ $i -gt 0 ]] && json+=","
        json+="{\"loop\":$((i+1)),\"work_summary_hash\":\"$hash\",\"files_modified\":1,\"confidence\":50,\"error_hash\":\"\",\"timestamp\":\"2025-01-01T00:00:0${i}Z\"}"
        i=$((i+1))
    done
    json+="]"
    echo "$json" > "$RALPH_DIR/.loop_history"
}

# Helper: Create loop history with specific files_modified and confidence
create_history_with_stats() {
    # Args: pairs of "files_modified,confidence"
    local json="["
    local i=0
    for pair in "$@"; do
        local fm=$(echo "$pair" | cut -d, -f1)
        local conf=$(echo "$pair" | cut -d, -f2)
        [[ $i -gt 0 ]] && json+=","
        json+="{\"loop\":$((i+1)),\"work_summary_hash\":\"hash${i}\",\"files_modified\":$fm,\"confidence\":$conf,\"error_hash\":\"\",\"timestamp\":\"2025-01-01T00:00:0${i}Z\"}"
        i=$((i+1))
    done
    json+="]"
    echo "$json" > "$RALPH_DIR/.loop_history"
}

# =============================================================================
# record_loop_history tests
# =============================================================================

@test "record_loop_history: creates history file if missing" {
    rm -f "$RALPH_DIR/.loop_history"
    create_mock_analysis "test work" 2 70

    record_loop_history 1

    [[ -f "$RALPH_DIR/.loop_history" ]]
    local count=$(jq 'length' "$RALPH_DIR/.loop_history")
    [[ "$count" -eq 1 ]]
}

@test "record_loop_history: appends entries" {
    create_mock_analysis "work 1" 1 50
    record_loop_history 1
    create_mock_analysis "work 2" 2 60
    record_loop_history 2

    local count=$(jq 'length' "$RALPH_DIR/.loop_history")
    [[ "$count" -eq 2 ]]
}

@test "record_loop_history: caps at 10 entries" {
    for i in $(seq 1 12); do
        create_mock_analysis "work $i" $i $((i * 5))
        record_loop_history $i
    done

    local count=$(jq 'length' "$RALPH_DIR/.loop_history")
    [[ "$count" -eq 10 ]]
}

@test "record_loop_history: stores loop number correctly" {
    create_mock_analysis "my work" 3 80
    record_loop_history 42

    local loop=$(jq '.[0].loop' "$RALPH_DIR/.loop_history")
    [[ "$loop" -eq 42 ]]
}

@test "record_loop_history: stores files_modified from analysis" {
    create_mock_analysis "some work" 7 90
    record_loop_history 1

    local fm=$(jq '.[0].files_modified' "$RALPH_DIR/.loop_history")
    [[ "$fm" -eq 7 ]]
}

# =============================================================================
# detect_stagnation_pattern tests
# =============================================================================

@test "detect_stagnation_pattern: returns 1 with no history" {
    rm -f "$RALPH_DIR/.loop_history"
    run detect_stagnation_pattern
    [[ "$status" -eq 1 ]]
}

@test "detect_stagnation_pattern: returns 1 with too few entries" {
    create_history_with_hashes "a" "b"
    run detect_stagnation_pattern
    [[ "$status" -eq 1 ]]
}

@test "detect_stagnation_pattern: detects oscillation (ABAB)" {
    create_history_with_hashes "alpha" "beta" "alpha" "beta"
    run detect_stagnation_pattern
    [[ "$status" -eq 0 ]]
    [[ "$output" == "oscillation" ]]
}

@test "detect_stagnation_pattern: no oscillation for ABAC" {
    create_history_with_hashes "alpha" "beta" "alpha" "gamma"
    run detect_stagnation_pattern
    [[ "$status" -eq 1 ]]
}

@test "detect_stagnation_pattern: detects spinning (AAA, no errors)" {
    create_history_with_hashes "same" "same" "same"
    run detect_stagnation_pattern
    [[ "$status" -eq 0 ]]
    [[ "$output" == "spinning" ]]
}

@test "detect_stagnation_pattern: no spinning when errors present" {
    local json='[
        {"loop":1,"work_summary_hash":"same","files_modified":1,"confidence":50,"error_hash":"error_1","timestamp":"2025-01-01T00:00:00Z"},
        {"loop":2,"work_summary_hash":"same","files_modified":1,"confidence":50,"error_hash":"error_2","timestamp":"2025-01-01T00:00:01Z"},
        {"loop":3,"work_summary_hash":"same","files_modified":1,"confidence":50,"error_hash":"error_3","timestamp":"2025-01-01T00:00:02Z"}
    ]'
    echo "$json" > "$RALPH_DIR/.loop_history"
    run detect_stagnation_pattern
    [[ "$status" -eq 1 ]]
}

@test "detect_stagnation_pattern: detects diminishing_returns" {
    # Previous 3: high stats, Recent 3: very low stats
    create_history_with_stats "10,80" "12,90" "11,85" "2,10" "1,5" "1,8"
    run detect_stagnation_pattern
    [[ "$status" -eq 0 ]]
    [[ "$output" == "diminishing_returns" ]]
}

@test "detect_stagnation_pattern: no diminishing_returns when stats are stable" {
    create_history_with_stats "5,50" "5,50" "5,50" "5,50" "5,50" "5,50"
    run detect_stagnation_pattern
    [[ "$status" -eq 1 ]]
}

# =============================================================================
# attempt_recovery tests
# =============================================================================

@test "attempt_recovery: first attempt succeeds" {
    run attempt_recovery "oscillation"
    [[ "$status" -eq 0 ]]
    [[ -f "$RALPH_DIR/.recovery_prompt" ]]
    [[ -f "$RALPH_DIR/.recovery_state" ]]
}

@test "attempt_recovery: writes correct prompt for oscillation" {
    attempt_recovery "oscillation"
    local prompt=$(cat "$RALPH_DIR/.recovery_prompt")
    [[ "$prompt" == *"alternating between two approaches"* ]]
}

@test "attempt_recovery: writes correct prompt for same_error" {
    attempt_recovery "same_error"
    local prompt=$(cat "$RALPH_DIR/.recovery_prompt")
    [[ "$prompt" == *"alternative root causes"* ]]
}

@test "attempt_recovery: writes correct prompt for no_progress" {
    attempt_recovery "no_progress"
    local prompt=$(cat "$RALPH_DIR/.recovery_prompt")
    [[ "$prompt" == *"smallest possible step"* ]]
}

@test "attempt_recovery: writes correct prompt for drift" {
    attempt_recovery "drift"
    local prompt=$(cat "$RALPH_DIR/.recovery_prompt")
    [[ "$prompt" == *"drifting from the goals"* ]]
}

@test "attempt_recovery: writes correct prompt for spinning" {
    attempt_recovery "spinning"
    local prompt=$(cat "$RALPH_DIR/.recovery_prompt")
    [[ "$prompt" == *"different part of the task"* ]]
}

@test "attempt_recovery: increments counter" {
    attempt_recovery "no_progress"
    local attempts=$(jq -r '.attempts' "$RALPH_DIR/.recovery_state")
    [[ "$attempts" -eq 1 ]]
}

@test "attempt_recovery: exhausts after max attempts" {
    export RECOVERY_MAX_ATTEMPTS=2
    attempt_recovery "no_progress"
    attempt_recovery "no_progress"

    run attempt_recovery "no_progress"
    [[ "$status" -eq 1 ]]
}

@test "attempt_recovery: second attempt still succeeds" {
    export RECOVERY_MAX_ATTEMPTS=2
    attempt_recovery "no_progress"

    run attempt_recovery "same_error"
    [[ "$status" -eq 0 ]]

    local attempts=$(jq -r '.attempts' "$RALPH_DIR/.recovery_state")
    [[ "$attempts" -eq 2 ]]
}

# =============================================================================
# reset_recovery tests
# =============================================================================

@test "reset_recovery: clears state on progress" {
    attempt_recovery "no_progress"
    [[ -f "$RALPH_DIR/.recovery_state" ]]

    reset_recovery

    [[ ! -f "$RALPH_DIR/.recovery_state" ]]
    [[ ! -f "$RALPH_DIR/.recovery_prompt" ]]
}

@test "reset_recovery: safe to call when no state exists" {
    run reset_recovery
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# detect_drift tests
# =============================================================================

@test "detect_drift: returns 1 with empty work summary" {
    run detect_drift ""
    [[ "$status" -eq 1 ]]
}

@test "detect_drift: returns 1 when no PROMPT.md exists" {
    run detect_drift "working on authentication module"
    [[ "$status" -eq 1 ]]
}

@test "detect_drift: detects on-track work (returns 1)" {
    cat > "$RALPH_DIR/PROMPT.md" << 'EOF'
Implement user authentication with password hashing and session management.
Add login endpoint and registration endpoint.
EOF
    # Force rebuild keywords
    rm -f "$RALPH_DIR/.goal_keywords"

    run detect_drift "implemented authentication login endpoint with password hashing"
    [[ "$status" -eq 1 ]]
}

@test "detect_drift: detects drifting work (returns 0)" {
    cat > "$RALPH_DIR/PROMPT.md" << 'EOF'
Implement user authentication with password hashing and session management.
EOF
    rm -f "$RALPH_DIR/.goal_keywords"

    export DRIFT_THRESHOLD=50
    run detect_drift "refactored database migration scripts for logging system"
    [[ "$status" -eq 0 ]]
}

@test "detect_drift: caches goal keywords" {
    cat > "$RALPH_DIR/PROMPT.md" << 'EOF'
Build a complete testing framework with integration tests.
EOF
    rm -f "$RALPH_DIR/.goal_keywords"

    detect_drift "testing framework integration" || true

    [[ -f "$RALPH_DIR/.goal_keywords" ]]
    local keyword_count=$(wc -l < "$RALPH_DIR/.goal_keywords")
    [[ "$keyword_count" -gt 0 ]]
}

@test "detect_drift: includes fix_plan.md keywords" {
    cat > "$RALPH_DIR/PROMPT.md" << 'EOF'
Build authentication.
EOF
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
- [ ] Add password validation
- [ ] Implement token refresh
EOF
    rm -f "$RALPH_DIR/.goal_keywords"

    _build_goal_keywords
    local keywords=$(cat "$RALPH_DIR/.goal_keywords")
    [[ "$keywords" == *"password"* ]]
    [[ "$keywords" == *"validation"* ]]
    [[ "$keywords" == *"token"* ]]
}

# =============================================================================
# _extract_keywords tests
# =============================================================================

@test "_extract_keywords: filters short words" {
    local result=$(_extract_keywords "the big authentication module is ready")
    [[ "$result" == *"authentication"* ]]
    [[ "$result" == *"module"* ]]
    [[ "$result" == *"ready"* ]]
    # Use grep -x for exact line match (not substring) since "the" appears inside "authentication"
    ! echo "$result" | grep -qx "the"
    ! echo "$result" | grep -qx "big"
    ! echo "$result" | grep -qx "is"
}

@test "_extract_keywords: lowercases all words" {
    local result=$(_extract_keywords "AUTHENTICATION Module Ready")
    [[ "$result" == *"authentication"* ]]
    [[ "$result" == *"module"* ]]
    [[ "$result" != *"AUTHENTICATION"* ]]
}

@test "_extract_keywords: deduplicates" {
    local result=$(_extract_keywords "authentication authentication authentication")
    local count=$(echo "$result" | grep -c "authentication")
    [[ "$count" -eq 1 ]]
}

# =============================================================================
# _get_recovery_prompt tests
# =============================================================================

@test "_get_recovery_prompt: returns prompt for each known type" {
    for type in oscillation same_error no_progress diminishing_returns spinning drift; do
        local prompt=$(_get_recovery_prompt "$type")
        [[ -n "$prompt" ]]
        [[ "$prompt" == RECOVERY:* ]]
    done
}

@test "_get_recovery_prompt: returns fallback for unknown type" {
    local prompt=$(_get_recovery_prompt "unknown_type")
    [[ "$prompt" == RECOVERY:* ]]
    [[ "$prompt" == *"appear stuck"* ]]
}
