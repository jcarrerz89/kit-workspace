#!/bin/bash
# =============================================================================
# log.sh — Structured logging with levels, timestamps, and caller context
# =============================================================================
#
# Replaces ad-hoc echo debugging with consistent, filterable output.
#
# Usage:
#   source lib/log.sh
#   LOG_LEVEL=debug kit-workspace run ...    ← verbose mode
#   LOG_LEVEL=warn  kit-workspace run ...    ← quiet mode (errors + warnings only)
#
# Levels (in order): debug < info < warn < error
# Default: info
#
# Stack traces:
#   Set PS4 and use `set -x` in specific functions for bash-level tracing:
#     PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
#
# =============================================================================

# Log level priority (higher = more severe)
# Uses simple case statement instead of associative array for nounset compatibility
LOG_LEVEL="${LOG_LEVEL:-info}"

_log_level_num() {
  case "$1" in
    debug) echo 0 ;; info) echo 1 ;; warn) echo 2 ;; error) echo 3 ;; *) echo 1 ;;
  esac
}

# Check if a message at $1 level should be printed given LOG_LEVEL
_log_should_print() {
  [ "$(_log_level_num "$1")" -ge "$(_log_level_num "$LOG_LEVEL")" ]
}

# Format: [LEVEL] HH:MM:SS caller:line message
_log_fmt() {
  local level="$1" color="$2"
  shift 2
  local ts
  ts=$(date +%H:%M:%S)
  # Caller context: who called the log function (2 frames up)
  local caller="${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}"
  echo -e "${color}[${level}]${NC} ${DIM}${ts} ${caller}${NC} $*" >&2
}

log_debug() { _log_should_print debug && _log_fmt DEBUG "$DIM"    "$@" || true; }
log_info()  { _log_should_print info  && _log_fmt INFO  "$CYAN"   "$@" || true; }
log_warn()  { _log_should_print warn  && _log_fmt WARN  "$YELLOW" "$@" || true; }
log_error() { _log_should_print error && _log_fmt ERROR "$RED"    "$@" || true; }

# Convenience: step-level output (always prints at info level, indented)
log_step() { _log_should_print info && echo -e "  ${DIM}→${NC} $*" >&2 || true; }
log_ok()   { _log_should_print info && echo -e "  ${GREEN}✓${NC} $*" >&2 || true; }
