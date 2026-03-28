#!/bin/bash
# =============================================================================
# notify.sh — Active notifications for agent events
# =============================================================================
#
# Sends system notifications when agents fail, stall, or complete.
# Solves the passive-escalation problem in Mode 3 (fire & forget) where
# humans may not check results for hours.
#
# Notification channels (in order of preference):
#   1. macOS Notification Center (osascript)
#   2. terminal-notifier (brew install terminal-notifier)
#   3. Terminal bell (fallback, always available)
#   4. Optional webhook (configurable)
#
# Configuration (kit-workspace.config.json):
#   "notifications": {
#     "enabled": true,
#     "on_failure": true,
#     "on_completion": false,
#     "on_boundary_violation": true,
#     "webhook_url": null,
#     "sound": true
#   }
#
# Integration:
#   - orchestrator.sh calls notify_agent_failure() from circuit breaker
#   - stall-sentinel.sh can call notify_agent_stall() on escalation
#   - orchestrator.sh can call notify_swarm_complete() when all agents finish
#
# =============================================================================

# ---------------------------------------------------------------------------
# Check if notifications are enabled in config
# ---------------------------------------------------------------------------
_notify_enabled() {
  local event_type="${1:-on_failure}"
  local config_file="${CONFIG_FILE:-}"

  # Whitelist valid event types to prevent jq filter injection
  case "$event_type" in
    on_failure|on_completion|on_boundary_violation|on_stall) ;;
    *) return 1 ;;
  esac

  # Default: enabled for failures and boundary violations
  if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
    [ "$event_type" = "on_failure" ] && return 0
    [ "$event_type" = "on_boundary_violation" ] && return 0
    [ "$event_type" = "on_stall" ] && return 0
    return 1
  fi

  local global_enabled
  global_enabled=$(jq -r '.notifications.enabled // true' "$config_file" 2>/dev/null)
  [ "$global_enabled" = "false" ] && return 1

  local event_enabled
  event_enabled=$(jq -r --arg evt "$event_type" '.notifications[$evt] // true' "$config_file" 2>/dev/null)
  [ "$event_enabled" = "false" ] && return 1

  return 0
}

# ---------------------------------------------------------------------------
# Send a system notification
# ---------------------------------------------------------------------------
_notify_send() {
  local title="$1"
  local message="$2"
  local sound="${3:-true}"

  # macOS: osascript (built-in, no extra dependencies)
  # Use argv injection to prevent AppleScript command injection
  if command -v osascript &>/dev/null; then
    if [ "$sound" = "true" ]; then
      osascript - "$title" "$message" <<'APPLESCRIPT' 2>/dev/null
on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name "Basso"
end run
APPLESCRIPT
    else
      osascript - "$title" "$message" <<'APPLESCRIPT' 2>/dev/null
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
    fi
    return 0
  fi

  # Linux: notify-send
  if command -v notify-send &>/dev/null; then
    notify-send "$title" "$message" --urgency=critical 2>/dev/null
    return 0
  fi

  # Fallback: terminal bell
  printf '\a'
  return 0
}

# ---------------------------------------------------------------------------
# Send webhook notification (optional, if configured)
# ---------------------------------------------------------------------------
_notify_webhook() {
  local title="$1"
  local message="$2"
  local config_file="${CONFIG_FILE:-}"

  [ -z "$config_file" ] || [ ! -f "$config_file" ] && return 0

  local webhook_url
  webhook_url=$(jq -r '.notifications.webhook_url // empty' "$config_file" 2>/dev/null)
  [ -z "$webhook_url" ] && return 0

  # Validate URL scheme to prevent SSRF (only https in production, http for local)
  case "$webhook_url" in
    https://*|http://localhost*|http://127.0.0.1*) ;;
    *) echo "WARN: webhook_url must be https:// (got: ${webhook_url%%://*}://...)" >&2; return 0 ;;
  esac

  # Fire and forget — don't block on webhook
  curl -s -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$title" --arg m "$message" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{title: $t, message: $m, timestamp: $ts, source: "kit-workspace"}')" \
    &>/dev/null & disown
}

# ---------------------------------------------------------------------------
# Notify: agent failure (called from circuit breaker)
# ---------------------------------------------------------------------------
notify_agent_failure() {
  local role="$1"
  local attempts="$2"
  local postmortem_file="${3:-}"
  local job_id="${4:-}"

  _notify_enabled "on_failure" || return 0

  local title="kit-workspace: Agent Failed"
  local message="$role failed after $attempts attempts. Review postmortem."
  [ -n "$job_id" ] && message="[$job_id] $message"

  _notify_send "$title" "$message" "true"
  _notify_webhook "$title" "$message"

  # Also log to summary (find the actual summary log file, don't use glob in redirect)
  local summary_log
  summary_log=$(ls -1t "$STATE_DIR/logs/"*_summary.log 2>/dev/null | head -1)
  [ -n "$summary_log" ] && echo "$(date +%Y-%m-%dT%H:%M:%S) NOTIFY: $role failure notification sent" >> "$summary_log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Notify: stall sentinel escalation
# ---------------------------------------------------------------------------
notify_agent_stall() {
  local role="$1"
  local stall_count="$2"
  local job_id="${3:-}"

  _notify_enabled "on_stall" || return 0

  local title="kit-workspace: Agent Stalled"
  local message="$role stuck in loop ($stall_count similar errors). Escalated."
  [ -n "$job_id" ] && message="[$job_id] $message"

  _notify_send "$title" "$message" "true"
  _notify_webhook "$title" "$message"
}

# ---------------------------------------------------------------------------
# Notify: boundary violation detected
# ---------------------------------------------------------------------------
notify_boundary_violation() {
  local role="$1"
  local violation_count="$2"
  local job_id="${3:-}"

  _notify_enabled "on_boundary_violation" || return 0

  local title="kit-workspace: Boundary Violation"
  local message="$role modified $violation_count file(s) outside scope. Review required."
  [ -n "$job_id" ] && message="[$job_id] $message"

  _notify_send "$title" "$message" "true"
  _notify_webhook "$title" "$message"
}

# ---------------------------------------------------------------------------
# Notify: all agents completed (optional, off by default)
# ---------------------------------------------------------------------------
notify_swarm_complete() {
  local task_name="$1"
  local agent_count="$2"
  local failed_count="${3:-0}"
  local job_id="${4:-}"

  _notify_enabled "on_completion" || return 0

  local title="kit-workspace: Swarm Complete"
  local message="$task_name: $agent_count agents finished"
  if [ "$failed_count" -gt 0 ]; then
    message+=", $failed_count failed"
  fi
  [ -n "$job_id" ] && message="[$job_id] $message"

  _notify_send "$title" "$message" "false"
  _notify_webhook "$title" "$message"
}
