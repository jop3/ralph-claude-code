#!/bin/bash
# Recovery Strategies for Ralph
# Ouroboros-inspired: smarter stagnation detection, recovery attempts before stopping, drift detection

# Source date utilities for cross-platform compatibility
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Recovery Configuration
RALPH_DIR="${RALPH_DIR:-.ralph}"
RECOVERY_MAX_ATTEMPTS=${RECOVERY_MAX_ATTEMPTS:-2}
DRIFT_THRESHOLD=${DRIFT_THRESHOLD:-15}

# State files
LOOP_HISTORY_FILE="$RALPH_DIR/.loop_history"
RECOVERY_STATE_FILE="$RALPH_DIR/.recovery_state"
RECOVERY_PROMPT_FILE="$RALPH_DIR/.recovery_prompt"
GOAL_KEYWORDS_FILE="$RALPH_DIR/.goal_keywords"

# =============================================================================
# FEATURE 1: LOOP HISTORY + STAGNATION DETECTION
# =============================================================================

# Record a loop's summary into rolling history (max 10 entries)
# Usage: record_loop_history <loop_number>
# Reads work_summary, files_modified, confidence from .response_analysis
record_loop_history() {
    local loop_number=$1

    # Ensure history file exists as JSON array
    if [[ ! -f "$LOOP_HISTORY_FILE" ]] || ! jq '.' "$LOOP_HISTORY_FILE" > /dev/null 2>&1; then
        echo '[]' > "$LOOP_HISTORY_FILE"
    fi

    # Extract data from response analysis
    local work_summary="" files_modified=0 confidence=0 error_hash=""
    local analysis_file="$RALPH_DIR/.response_analysis"

    if [[ -f "$analysis_file" ]]; then
        work_summary=$(jq -r '.analysis.work_summary // ""' "$analysis_file" 2>/dev/null || echo "")
        files_modified=$(jq -r '.analysis.files_modified // 0' "$analysis_file" 2>/dev/null || echo "0")
        confidence=$(jq -r '.analysis.confidence // 0' "$analysis_file" 2>/dev/null || echo "0")
    fi

    # Compute hashes for pattern detection
    local work_summary_hash=""
    if [[ -n "$work_summary" && "$work_summary" != "null" ]]; then
        work_summary_hash=$(printf '%s' "$work_summary" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$work_summary" | cksum | cut -d' ' -f1)
    fi

    # Compute error hash from output if errors present
    local cb_state_file="$RALPH_DIR/.circuit_breaker_state"
    if [[ -f "$cb_state_file" ]]; then
        local same_error_count
        same_error_count=$(jq -r '.consecutive_same_error // 0' "$cb_state_file" 2>/dev/null || echo "0")
        if [[ "$same_error_count" -gt 0 ]]; then
            error_hash="error_${same_error_count}"
        fi
    fi

    # Build entry
    local entry
    entry=$(jq -n \
        --argjson loop "$loop_number" \
        --arg work_summary_hash "$work_summary_hash" \
        --argjson files_modified "${files_modified:-0}" \
        --argjson confidence "${confidence:-0}" \
        --arg error_hash "$error_hash" \
        --arg timestamp "$(get_iso_timestamp)" \
        '{loop: $loop, work_summary_hash: $work_summary_hash, files_modified: $files_modified, confidence: $confidence, error_hash: $error_hash, timestamp: $timestamp}')

    # Append and cap at 10
    local history
    history=$(cat "$LOOP_HISTORY_FILE")
    history=$(echo "$history" | jq --argjson entry "$entry" '. += [$entry] | .[-10:]')
    echo "$history" > "$LOOP_HISTORY_FILE"
}

# Detect stagnation patterns in loop history
# Returns pattern name on stdout; exit 0 = detected, 1 = none
detect_stagnation_pattern() {
    if [[ ! -f "$LOOP_HISTORY_FILE" ]]; then
        return 1
    fi

    local history
    history=$(cat "$LOOP_HISTORY_FILE")
    local count
    count=$(echo "$history" | jq 'length')

    # Need at least 3 entries for any pattern
    if [[ "$count" -lt 3 ]]; then
        return 1
    fi

    # Pattern: oscillation — ABAB in last 4 work_summary hashes
    if [[ "$count" -ge 4 ]]; then
        local h1 h2 h3 h4
        h1=$(echo "$history" | jq -r '.[-4].work_summary_hash')
        h2=$(echo "$history" | jq -r '.[-3].work_summary_hash')
        h3=$(echo "$history" | jq -r '.[-2].work_summary_hash')
        h4=$(echo "$history" | jq -r '.[-1].work_summary_hash')

        if [[ -n "$h1" && -n "$h2" && "$h1" != "$h2" && "$h1" == "$h3" && "$h2" == "$h4" ]]; then
            echo "oscillation"
            return 0
        fi
    fi

    # Pattern: spinning — last 3 work_summary hashes identical, no errors
    local s1 s2 s3
    s1=$(echo "$history" | jq -r '.[-3].work_summary_hash')
    s2=$(echo "$history" | jq -r '.[-2].work_summary_hash')
    s3=$(echo "$history" | jq -r '.[-1].work_summary_hash')

    if [[ -n "$s1" && "$s1" == "$s2" && "$s2" == "$s3" ]]; then
        local e1 e2 e3
        e1=$(echo "$history" | jq -r '.[-3].error_hash')
        e2=$(echo "$history" | jq -r '.[-2].error_hash')
        e3=$(echo "$history" | jq -r '.[-1].error_hash')

        if [[ -z "$e1" && -z "$e2" && -z "$e3" ]]; then
            echo "spinning"
            return 0
        fi
    fi

    # Pattern: diminishing_returns — avg files_modified + confidence in last 3 < 50% of previous 3
    if [[ "$count" -ge 6 ]]; then
        local recent_avg prev_avg
        recent_avg=$(echo "$history" | jq '[.[-3:][].files_modified + .[-3:][].confidence] | add / length')
        prev_avg=$(echo "$history" | jq '[.[-6:-3][].files_modified + .[-6:-3][].confidence] | add / length')

        if [[ -n "$prev_avg" && -n "$recent_avg" ]]; then
            # Use awk for float comparison
            local is_diminishing
            is_diminishing=$(awk "BEGIN { print ($recent_avg < $prev_avg * 0.5) ? 1 : 0 }" 2>/dev/null || echo "0")
            if [[ "$is_diminishing" == "1" && "$prev_avg" != "0" ]]; then
                echo "diminishing_returns"
                return 0
            fi
        fi
    fi

    return 1
}

# =============================================================================
# FEATURE 2: RECOVERY STRATEGIES
# =============================================================================

# Recovery prompt templates per stagnation type
_get_recovery_prompt() {
    local stagnation_type=$1

    case "$stagnation_type" in
        oscillation)
            echo "RECOVERY: You are alternating between two approaches. Pick ONE and commit fully. Do not revert your previous changes."
            ;;
        same_error)
            echo "RECOVERY: Same error persists. List 3 alternative root causes you haven't tried. Try the most likely one."
            ;;
        no_progress)
            echo "RECOVERY: No files changed. Break your current task into the smallest possible step. Do only that step."
            ;;
        diminishing_returns)
            echo "RECOVERY: Progress is slowing. Focus on the single highest-value remaining change."
            ;;
        spinning)
            echo "RECOVERY: You keep doing the same work. Move to a different part of the task."
            ;;
        drift)
            echo "RECOVERY: You are drifting from the goals in PROMPT.md. Re-read it. Your next action must address an uncompleted goal."
            ;;
        *)
            echo "RECOVERY: You appear stuck. Re-read PROMPT.md, pick the most important uncompleted task, and take the smallest step toward it."
            ;;
    esac
}

# Attempt recovery before halting
# Usage: attempt_recovery <stagnation_type>
# Returns 0 if recovery attempted (writes .recovery_prompt), 1 if exhausted
attempt_recovery() {
    local stagnation_type=${1:-unknown}

    # Read/initialize recovery state
    local attempts=0 max_attempts=$RECOVERY_MAX_ATTEMPTS

    if [[ -f "$RECOVERY_STATE_FILE" ]] && jq '.' "$RECOVERY_STATE_FILE" > /dev/null 2>&1; then
        attempts=$(jq -r '.attempts // 0' "$RECOVERY_STATE_FILE" 2>/dev/null || echo "0")
    fi
    attempts=$((attempts + 0))

    # Check if exhausted
    if [[ $attempts -ge $max_attempts ]]; then
        return 1
    fi

    # Increment attempts
    attempts=$((attempts + 1))

    # Write recovery state
    jq -n \
        --argjson attempts "$attempts" \
        --argjson max_attempts "$max_attempts" \
        --arg last_type "$stagnation_type" \
        --arg timestamp "$(get_iso_timestamp)" \
        '{attempts: $attempts, max_attempts: $max_attempts, last_type: $last_type, timestamp: $timestamp}' \
        > "$RECOVERY_STATE_FILE"

    # Write recovery prompt file
    local prompt
    prompt=$(_get_recovery_prompt "$stagnation_type")
    echo "$prompt" > "$RECOVERY_PROMPT_FILE"

    return 0
}

# Reset recovery state (call when progress is made)
reset_recovery() {
    rm -f "$RECOVERY_STATE_FILE" "$RECOVERY_PROMPT_FILE"
}

# Get current recovery attempt count
get_recovery_attempts() {
    if [[ -f "$RECOVERY_STATE_FILE" ]] && jq '.' "$RECOVERY_STATE_FILE" > /dev/null 2>&1; then
        jq -r '.attempts // 0' "$RECOVERY_STATE_FILE" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# =============================================================================
# FEATURE 3: DRIFT DETECTION
# =============================================================================

# Extract keywords (words >4 chars, lowercased, deduped) from text
_extract_keywords() {
    local text="$1"
    echo "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alpha:]' '\n' | awk 'length > 4' | sort -u
}

# Build or refresh goal keywords cache from PROMPT.md + fix_plan.md
_build_goal_keywords() {
    local prompt_file="$RALPH_DIR/PROMPT.md"
    local fix_plan_file="$RALPH_DIR/fix_plan.md"
    local text=""

    if [[ -f "$prompt_file" ]]; then
        text+=$(cat "$prompt_file")
        text+=$'\n'
    fi

    if [[ -f "$fix_plan_file" ]]; then
        text+=$(cat "$fix_plan_file")
    fi

    if [[ -z "$text" ]]; then
        return 1
    fi

    _extract_keywords "$text" > "$GOAL_KEYWORDS_FILE"
}

# Detect drift from goals
# Usage: detect_drift <work_summary>
# Returns 0 = drift detected, 1 = on track
detect_drift() {
    local work_summary="$1"

    if [[ -z "$work_summary" ]]; then
        return 1  # No summary to check, can't determine drift
    fi

    # Build/refresh goal keywords if not cached
    if [[ ! -f "$GOAL_KEYWORDS_FILE" ]] || [[ ! -s "$GOAL_KEYWORDS_FILE" ]]; then
        _build_goal_keywords || return 1
    fi

    # Extract keywords from work summary
    local summary_keywords
    summary_keywords=$(_extract_keywords "$work_summary")

    if [[ -z "$summary_keywords" ]]; then
        return 1  # No keywords to compare
    fi

    # Count total summary keywords and matching goal keywords
    local total_summary_words=0 matching=0
    local goal_keywords
    goal_keywords=$(cat "$GOAL_KEYWORDS_FILE")

    while IFS= read -r word; do
        total_summary_words=$((total_summary_words + 1))
        if echo "$goal_keywords" | grep -qx "$word"; then
            matching=$((matching + 1))
        fi
    done <<< "$summary_keywords"

    if [[ $total_summary_words -eq 0 ]]; then
        return 1
    fi

    # Compute overlap percentage
    local overlap
    overlap=$(awk "BEGIN { printf \"%.0f\", ($matching / $total_summary_words) * 100 }" 2>/dev/null || echo "0")

    if [[ $overlap -lt $DRIFT_THRESHOLD ]]; then
        return 0  # Drift detected
    else
        return 1  # On track
    fi
}

# Export functions
export -f record_loop_history
export -f detect_stagnation_pattern
export -f attempt_recovery
export -f reset_recovery
export -f get_recovery_attempts
export -f detect_drift
export -f _get_recovery_prompt
export -f _extract_keywords
export -f _build_goal_keywords
