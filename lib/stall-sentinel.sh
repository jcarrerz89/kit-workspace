#!/bin/bash
# =============================================================================
# stall-sentinel.sh — Sliding-window stuck detection for agent loops
# =============================================================================
#
# Detects when an agent is stuck in a retry loop producing the same errors.
# Uses a sliding window over the last N log entries to find repeated patterns.
#
# Integration points:
#   - Called by orchestrator.sh (Mode 3) between retries
#   - Can be sourced by quality-gate-task-completed.sh for Mode 4
#   - Writes escalation files to .kit-ws/escalations/ for human review
#
# Usage:
#   source lib/stall-sentinel.sh
#   sentinel_check "$role" "$log_file" "$STATE_DIR"
#     → returns 0 if OK, 1 if stalled (should stop retrying)
#
# =============================================================================

: "${PROJECT_DIR:?PROJECT_DIR not set — source from kit-workspace}"

# Default config (overridable via kit-workspace.config.json)
SENTINEL_WINDOW_SIZE="${SENTINEL_WINDOW_SIZE:-3}"      # Compare last N error snapshots
SENTINEL_SIMILARITY_THRESHOLD="${SENTINEL_SIMILARITY_THRESHOLD:-70}"  # % similarity to flag as stuck
SENTINEL_ESCALATION_DIR="${SENTINEL_ESCALATION_DIR:-.kit-ws/escalations}"

# ---------------------------------------------------------------------------
# Extract error signature from log tail
# Strips timestamps, paths, and line numbers to compare error "shape"
# ---------------------------------------------------------------------------
sentinel_error_signature() {
  local log_tail="$1"
  echo "$log_tail" \
    | grep -iE 'error|fail|exception|denied|timeout|refused' \
    | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+//g' \
    | sed -E 's/line [0-9]+/line N/g' \
    | sed -E 's/:[0-9]+:/:N:/g' \
    | sed -E 's|/[^ ]*\/||g' \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u \
    | head -20
}

# ---------------------------------------------------------------------------
# Compare two error signatures for similarity (0-100%)
# Uses line-level intersection over union
# ---------------------------------------------------------------------------
sentinel_similarity() {
  local sig_a="$1"
  local sig_b="$2"

  # Empty signatures = no errors = not stalled
  [ -z "$sig_a" ] || [ -z "$sig_b" ] && echo "0" && return

  local lines_a=$(echo "$sig_a" | wc -l | tr -d ' ')
  local lines_b=$(echo "$sig_b" | wc -l | tr -d ' ')
  local common=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$sig_b" | grep -qF "$line"; then
      common=$((common + 1))
    fi
  done <<< "$sig_a"

  # Jaccard-ish: common / max(a, b) * 100
  local max=$lines_a
  [ "$lines_b" -gt "$max" ] && max=$lines_b
  [ "$max" -eq 0 ] && echo "0" && return

  echo $(( (common * 100) / max ))
}

# ---------------------------------------------------------------------------
# Record error snapshot for sliding window
# ---------------------------------------------------------------------------
sentinel_record_snapshot() {
  local role="$1"
  local log_file="$2"
  local state_dir="$3"

  local snapshot_dir="$state_dir/sentinel/${role}"
  mkdir -p "$snapshot_dir"

  local tail_content=$(tail -30 "$log_file" 2>/dev/null || echo "")
  local signature=$(sentinel_error_signature "$tail_content")
  local snapshot_file="$snapshot_dir/$(date +%s).sig"

  echo "$signature" > "$snapshot_file"

  # Keep only last WINDOW_SIZE snapshots
  local count=$(ls -1 "$snapshot_dir"/*.sig 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt "$SENTINEL_WINDOW_SIZE" ]; then
    ls -1t "$snapshot_dir"/*.sig | tail -n +$((SENTINEL_WINDOW_SIZE + 1)) | xargs rm -f
  fi
}

# ---------------------------------------------------------------------------
# Check if agent is stalled (main entry point)
# Returns 0 if OK, 1 if stalled
# ---------------------------------------------------------------------------
sentinel_check() {
  local role="$1"
  local log_file="$2"
  local state_dir="$3"

  # Record current error snapshot
  sentinel_record_snapshot "$role" "$log_file" "$state_dir"

  local snapshot_dir="$state_dir/sentinel/${role}"
  local snapshots=()
  while IFS= read -r snap; do
    [ -n "$snap" ] && snapshots+=("$snap")
  done < <(ls -1t "$snapshot_dir"/*.sig 2>/dev/null)

  # Need at least 2 snapshots to compare
  [ "${#snapshots[@]}" -lt 2 ] && return 0

  # Compare consecutive snapshots in the window
  local stall_count=0
  local i=0
  while [ $i -lt $((${#snapshots[@]} - 1)) ]; do
    local sig_current=$(cat "${snapshots[$i]}" 2>/dev/null)
    local sig_previous=$(cat "${snapshots[$((i + 1))]}" 2>/dev/null)
    local similarity=$(sentinel_similarity "$sig_current" "$sig_previous")

    if [ "$similarity" -ge "$SENTINEL_SIMILARITY_THRESHOLD" ]; then
      stall_count=$((stall_count + 1))
    fi
    i=$((i + 1))
  done

  # If ALL consecutive pairs in window are similar → stalled
  local pairs=$((${#snapshots[@]} - 1))
  if [ "$stall_count" -ge "$pairs" ] && [ "$pairs" -ge 2 ]; then
    sentinel_escalate "$role" "$log_file" "$state_dir" "$stall_count"
    # Active notification for stall detection
    type notify_agent_stall &>/dev/null && notify_agent_stall "$role" "$stall_count"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Escalate: write structured escalation file for human review
# ---------------------------------------------------------------------------
sentinel_escalate() {
  local role="$1"
  local log_file="$2"
  local state_dir="$3"
  local stall_count="$4"

  # Resolve escalation dir relative to project
  local esc_dir="${PROJECT_DIR:-.}/$SENTINEL_ESCALATION_DIR"
  mkdir -p "$esc_dir"

  local esc_file="$esc_dir/${role}_$(date +%Y%m%dT%H%M%S).json"
  local last_error=$(tail -30 "$log_file" 2>/dev/null | head -50 || echo "no log available")

  jq -n \
    --arg role "$role" \
    --arg stalls "$stall_count" \
    --arg error "$last_error" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg recommendation "Agent $role is stuck in a loop ($stall_count consecutive similar errors). Recommend: 1) Review in Mode 1 (supervised), 2) Check known-fixes.json, 3) Simplify the task scope." \
    '{
      agent: $role,
      type: "stall-sentinel",
      consecutive_stalls: ($stalls | tonumber),
      last_error: $error,
      timestamp: $ts,
      recommendation: $recommendation,
      escalation: "mode-1"
    }' > "$esc_file"

  # Log to summary if available
  local summary_log="$state_dir/logs/"*"_summary.log" 2>/dev/null
  if ls $summary_log &>/dev/null; then
    echo "$(date +%Y-%m-%dT%H:%M:%S) STALL-SENTINEL: $role stuck after $stall_count similar errors → escalated to $esc_file" >> $(ls -1 $summary_log | head -1)
  fi
}

# ---------------------------------------------------------------------------
# Reset sentinel state for a role (call after successful completion)
# ---------------------------------------------------------------------------
sentinel_reset() {
  local role="$1"
  local state_dir="$2"

  rm -rf "$state_dir/sentinel/${role}" 2>/dev/null || true
}
