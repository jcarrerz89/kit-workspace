#!/bin/bash
# =============================================================================
# checkpoint.sh — Crash recovery state machine for agent sessions
# =============================================================================
#
# Persists execution state to disk so sessions can resume after crashes.
#
# State files:
#   .kit-ws/state/current.json   ← Active session state (who's running what)
#   .kit-ws/state/completed.json ← Completed tasks log (append-only)
#   .kit-ws/state/recovery.json  ← Crash recovery info (auto-generated)
#
# Integration:
#   - orchestrator.sh calls checkpoint_start/checkpoint_complete/checkpoint_fail
#   - kit-workspace CLI calls checkpoint_recover on startup to detect interrupted sessions
#
# Usage:
#   source lib/checkpoint.sh
#   checkpoint_init "$PROJECT_DIR"
#   checkpoint_start "$session_id" "$task_name" "$mode" "$agents_json"
#   checkpoint_agent_started "$session_id" "$role"
#   checkpoint_agent_completed "$session_id" "$role" "$scr"
#   checkpoint_agent_failed "$session_id" "$role" "$error"
#   checkpoint_complete "$session_id"
#   checkpoint_recover  # → prints recovery instructions if interrupted session found
#
# =============================================================================

set -euo pipefail

CHECKPOINT_DIR=""

# ---------------------------------------------------------------------------
# Lockfile helper — prevents race conditions when multiple agents write
# Uses mkdir-based portable lock (works on macOS + Linux, no flock needed)
# ---------------------------------------------------------------------------
_checkpoint_locked_update() {
  local jq_filter="$1"
  shift  # remaining args are --arg pairs for jq

  [ -z "$CHECKPOINT_DIR" ] || [ ! -f "$CHECKPOINT_DIR/current.json" ] && return 0

  local lockdir="$CHECKPOINT_DIR/.lock.d"
  local current="$CHECKPOINT_DIR/current.json"
  local tmp="${current}.tmp.$$"

  _lock_acquire "$lockdir" || return 1

  # Atomic read-modify-write: jq to tmp, validate, then mv
  if jq "$@" "$jq_filter" "$current" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    mv "$tmp" "$current"
  else
    log_warn "checkpoint: jq update failed, state unchanged"
    rm -f "$tmp"
  fi

  _lock_release "$lockdir"
}

# ---------------------------------------------------------------------------
# Initialize checkpoint directory
# ---------------------------------------------------------------------------
checkpoint_init() {
  local project_dir="${1:-.}"
  CHECKPOINT_DIR="$project_dir/.kit-ws/state"
  mkdir -p "$CHECKPOINT_DIR"

  # Initialize files if they don't exist
  [ -f "$CHECKPOINT_DIR/completed.json" ] || echo '[]' > "$CHECKPOINT_DIR/completed.json"
}

# ---------------------------------------------------------------------------
# Record session start
# ---------------------------------------------------------------------------
checkpoint_start() {
  local session_id="$1"
  local task_name="$2"
  local mode="$3"
  local agents_json="$4"  # JSON array of agent roles

  [ -z "$CHECKPOINT_DIR" ] && return 1

  jq -n \
    --arg sid "$session_id" \
    --arg task "$task_name" \
    --arg mode "$mode" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pid "$$" \
    --argjson agents "${agents_json:-[]}" \
    '{
      session_id: $sid,
      task: $task,
      mode: ($mode | tonumber),
      started_at: $started,
      pid: ($pid | tonumber),
      status: "running",
      agents: [($agents | if type == "array" then .[] else . end) | {
        role: (if type == "string" then . else .role end),
        status: "pending",
        started_at: null,
        completed_at: null,
        scr: null,
        error: null,
        teammate_name: null
      }]
    }' > "$CHECKPOINT_DIR/current.json"
}

# ---------------------------------------------------------------------------
# Record agent started within session (lock-safe)
# ---------------------------------------------------------------------------
checkpoint_agent_started() {
  local session_id="$1"
  local role="$2"
  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  _checkpoint_locked_update \
    '.agents = [.agents[] | if .role == $role then .status = "running" | .started_at = $now else . end]' \
    --arg role "$role" --arg now "$now"
}

# ---------------------------------------------------------------------------
# Record teammate name for an agent (for session resumption via SendMessage)
# ---------------------------------------------------------------------------
checkpoint_agent_set_teammate() {
  local session_id="$1"
  local role="$2"
  local teammate_name="$3"

  _checkpoint_locked_update \
    '.agents = [.agents[] | if .role == $role then .teammate_name = $name else . end]' \
    --arg role "$role" --arg name "$teammate_name"
}

# ---------------------------------------------------------------------------
# Get failed/interrupted agents with their teammate names (for resumption)
# Returns JSON array: [{"role":"flutter","teammate_name":"agent-flutter",...}]
# ---------------------------------------------------------------------------
checkpoint_get_resumable_agents() {
  local session_id="${1:-}"

  [ -z "$CHECKPOINT_DIR" ] || [ ! -f "$CHECKPOINT_DIR/current.json" ] && { echo '[]'; return; }

  jq '[.agents[]? | select(.status == "failed" or .status == "running") | {
    role: .role,
    status: .status,
    teammate_name: (.teammate_name // null),
    error: (.error // null)
  }]' "$CHECKPOINT_DIR/current.json" 2>/dev/null || echo '[]'
}

# ---------------------------------------------------------------------------
# Record agent completed (lock-safe)
# ---------------------------------------------------------------------------
checkpoint_agent_completed() {
  local session_id="$1"
  local role="$2"
  local scr="${3:-0}"
  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  _checkpoint_locked_update \
    '.agents = [.agents[] | if .role == $role then .status = "completed" | .completed_at = $now | .scr = ($scr | tonumber) else . end]' \
    --arg role "$role" --arg now "$now" --arg scr "$scr"
}

# ---------------------------------------------------------------------------
# Record agent failed (lock-safe)
# ---------------------------------------------------------------------------
checkpoint_agent_failed() {
  local session_id="$1"
  local role="$2"
  local error="$3"
  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  _checkpoint_locked_update \
    '.agents = [.agents[] | if .role == $role then .status = "failed" | .completed_at = $now | .error = $err else . end]' \
    --arg role "$role" --arg now "$now" --arg err "$error"
}

# ---------------------------------------------------------------------------
# Record session completed — move to completed.json, clear current
# ---------------------------------------------------------------------------
checkpoint_complete() {
  local session_id="$1"

  [ -z "$CHECKPOINT_DIR" ] || [ ! -f "$CHECKPOINT_DIR/current.json" ] && return 0

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local current="$CHECKPOINT_DIR/current.json"
  local lockdir="$CHECKPOINT_DIR/.lock.d"

  # Update status and timestamp (locked + atomic)
  _lock_acquire "$lockdir" || { log_error "checkpoint_complete: lock timeout"; return 1; }

  local tmp="${current}.tmp.$$"
  if jq --arg now "$now" '.status = "completed" | .completed_at = $now' \
     "$current" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$current"
  else
    rm -f "$tmp"
    log_error "checkpoint_complete: failed to update status"
  fi

  _lock_release "$lockdir"

  # Append to completed log (locked + atomic)
  _lock_acquire "$lockdir" || { log_error "checkpoint_complete: lock timeout (completed.json)"; return 1; }

  local ctmp="$CHECKPOINT_DIR/completed.json.tmp.$$"
  if jq --slurpfile entry "$current" '. + $entry' \
     "$CHECKPOINT_DIR/completed.json" > "$ctmp" 2>/dev/null && [ -s "$ctmp" ]; then
    mv "$ctmp" "$CHECKPOINT_DIR/completed.json"
  else
    rm -f "$ctmp"
    log_error "checkpoint_complete: failed to append to completed log"
  fi

  _lock_release "$lockdir"

  # Clear current
  rm -f "$current"
}

# ---------------------------------------------------------------------------
# Detect and report interrupted sessions (call on CLI startup)
# Returns 0 if clean, 1 if interrupted session found
# ---------------------------------------------------------------------------
checkpoint_recover() {
  [ -z "$CHECKPOINT_DIR" ] && return 0
  [ ! -f "$CHECKPOINT_DIR/current.json" ] && return 0

  local current="$CHECKPOINT_DIR/current.json"

  # Validate JSON integrity before reading fields
  if ! jq empty "$current" 2>/dev/null; then
    log_error "Corrupted checkpoint state: $current"
    echo ""
    echo "  Checkpoint state file is corrupted."
    echo "  To discard: rm $current"
    echo ""
    return 1
  fi

  local status
  status=$(jq -r '.status // empty' "$current") || return 0
  [ "$status" != "running" ] && return 0

  # Check if the recorded PID is still alive
  local recorded_pid
  recorded_pid=$(jq -r '.pid // empty' "$current") || recorded_pid=""
  if [ -n "$recorded_pid" ] && kill -0 "$recorded_pid" 2>/dev/null; then
    # Process still running — not a crash
    return 0
  fi

  # Interrupted session detected — read all fields with validation
  local task mode started completed_agents failed_agents pending_agents
  task=$(jq -r '.task // "unknown"' "$current")
  mode=$(jq -r '.mode // "?"' "$current")
  started=$(jq -r '.started_at // "?"' "$current")
  completed_agents=$(jq '[.agents[]? | select(.status == "completed")] | length' "$current")
  failed_agents=$(jq '[.agents[]? | select(.status == "failed")] | length' "$current")
  pending_agents=$(jq '[.agents[]? | select(.status == "pending" or .status == "running")] | length' "$current")

  # Write recovery file
  jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {detected_at: $now, recovery_type: "crash"}' \
    "$CHECKPOINT_DIR/current.json" > "$CHECKPOINT_DIR/recovery.json"

  # Output recovery instructions to stdout
  echo ""
  echo "━━━ Checkpoint: interrupted session detected ━━━"
  echo ""
  echo "  Task:      $task"
  echo "  Mode:      $mode"
  echo "  Started:   $started"
  echo "  Agents:    $completed_agents completed, $failed_agents failed, $pending_agents interrupted"
  echo ""

  # Show per-agent status
  jq -r '.agents[] | "  [\(.status | if . == "completed" then "✅" elif . == "failed" then "❌" else "⏸️ " end)] \(.role)\(if .error then " — " + .error else "" end)"' \
    "$CHECKPOINT_DIR/current.json"

  # Show teammate names for resumable agents (if available)
  local resumable
  resumable=$(jq -c '[.agents[]? | select((.status == "failed" or .status == "running") and .teammate_name != null)]' "$current" 2>/dev/null)
  local resumable_count
  resumable_count=$(echo "$resumable" | jq 'length' 2>/dev/null || echo 0)

  echo ""
  echo "  Options:"
  echo "    1. Resume pending agents:  kit-workspace run <task.json> --resume"
  echo "    2. Discard and start over: kit-workspace run <task.json> --clean"
  echo "    3. Review in Mode 1:       kit-workspace run <task.json> --mode 1"

  if [ "$resumable_count" -gt 0 ]; then
    echo ""
    echo "  Resumable sessions (Mode 4 / Agent Teams):"
    echo "$resumable" | jq -r '.[] | "    SendMessage(to: \"\(.teammate_name)\") — role: \(.role)\(if .error then " — last error: " + .error else "" end)"' 2>/dev/null
    echo ""
    echo "  Using SendMessage preserves agent context and saves ~70% tokens."
  fi
  echo ""

  return 1
}

# ---------------------------------------------------------------------------
# Clean up interrupted session (user chose to discard)
# ---------------------------------------------------------------------------
checkpoint_discard() {
  [ -z "$CHECKPOINT_DIR" ] && return 0

  local current="$CHECKPOINT_DIR/current.json"
  local lockdir="$CHECKPOINT_DIR/.lock.d"

  if [ -f "$current" ]; then
    # Move to completed as "discarded" (locked + atomic)
    _lock_acquire "$lockdir" || { log_error "checkpoint_discard: lock timeout"; return 1; }

    local tmp="${current}.tmp.$$"
    if jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "discarded" | .completed_at = $now' \
       "$current" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$current"
    else
      rm -f "$tmp"
    fi

    local ctmp="$CHECKPOINT_DIR/completed.json.tmp.$$"
    if jq --slurpfile entry "$current" '. + $entry' \
       "$CHECKPOINT_DIR/completed.json" > "$ctmp" 2>/dev/null && [ -s "$ctmp" ]; then
      mv "$ctmp" "$CHECKPOINT_DIR/completed.json"
    else
      rm -f "$ctmp"
    fi

    _lock_release "$lockdir"

    rm -f "$current"
  fi

  rm -f "$CHECKPOINT_DIR/recovery.json"
}
