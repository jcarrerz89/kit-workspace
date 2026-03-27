#!/bin/bash
# =============================================================================
# common.sh — Safe wrappers for fragile shell patterns
# =============================================================================
#
# Provides:
#   safe_jq     — jq with exit code validation and error logging
#   safe_cd     — cd with error check (for use in subshells / hot paths)
#   atomic_write — write to tmp then mv (prevents partial writes)
#   locked_exec  — flock-based critical section (replaces noclobber spin-wait)
#
# =============================================================================

# ---------------------------------------------------------------------------
# safe_jq — Run jq with error handling
#
# Usage:
#   result=$(safe_jq -r '.field' "$file")              ← exits 1 on error
#   result=$(safe_jq -r '.field // "default"' "$file")  ← jq default if missing
#   safe_jq -e '.field' "$file" || echo "field missing" ← -e checks null/false
#
# On failure: logs the error and returns 1 (caller decides how to handle)
# ---------------------------------------------------------------------------
safe_jq() {
  local result exit_code
  result=$(jq "$@" 2>&1)
  exit_code=$?

  if [ $exit_code -ne 0 ]; then
    # Extract the file argument (last arg) for context
    local last_arg="${*: -1}"
    log_error "jq failed (exit $exit_code) on: $last_arg"
    log_debug "jq args: $*"
    log_debug "jq output: $result"
    return 1
  fi

  echo "$result"
}

# ---------------------------------------------------------------------------
# safe_cd — cd with error check, for use inside subshells
#
# Usage:
#   safe_cd "$worktree_path" || return 1
# ---------------------------------------------------------------------------
safe_cd() {
  local target="$1"
  if [ ! -d "$target" ]; then
    log_error "safe_cd: directory does not exist: $target"
    return 1
  fi
  cd "$target" || {
    log_error "safe_cd: failed to cd to: $target"
    return 1
  }
}

# ---------------------------------------------------------------------------
# atomic_write — Write content to file atomically (tmp + mv)
#
# Usage:
#   echo '{"key":"val"}' | atomic_write "$target_file"
#   jq '.x = 1' "$file" | atomic_write "$file"
#
# Reads from stdin, writes to tmp, validates non-empty, then mv.
# If stdin is empty or write fails, target is NOT modified.
# ---------------------------------------------------------------------------
atomic_write() {
  local target="$1"
  local tmp="${target}.tmp.$$"

  # Read stdin to tmp
  cat > "$tmp"

  # Validate: non-empty file
  if [ ! -s "$tmp" ]; then
    log_error "atomic_write: refusing to write empty content to: $target"
    rm -f "$tmp"
    return 1
  fi

  # Atomic rename
  mv "$tmp" "$target" || {
    log_error "atomic_write: mv failed for: $target"
    rm -f "$tmp"
    return 1
  }
}

# ---------------------------------------------------------------------------
# _lock_acquire / _lock_release — Portable advisory locking
#
# Uses mkdir (atomic on all POSIX systems, works on macOS + Linux).
# Falls back to flock if available.
# Stale lock detection via PID file.
#
# Usage:
#   _lock_acquire "$lockdir" || return 1
#   # ... critical section ...
#   _lock_release "$lockdir"
# ---------------------------------------------------------------------------
_lock_acquire() {
  local lockdir="$1"
  local timeout="${LOCK_TIMEOUT:-10}"
  local waited=0

  while ! mkdir "$lockdir" 2>/dev/null; do
    # Check for stale lock (owner PID no longer running)
    if [ -f "$lockdir/pid" ]; then
      local owner_pid
      owner_pid=$(cat "$lockdir/pid" 2>/dev/null) || owner_pid=""
      if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
        # Stale lock — owner is dead, force acquire
        rm -rf "$lockdir"
        continue
      fi
    fi

    sleep 0.5
    waited=$((waited + 1))
    if [ "$waited" -ge "$((timeout * 2))" ]; then
      log_error "lock: timeout after ${timeout}s on: $lockdir"
      return 1
    fi
  done

  # Record our PID for stale detection by others
  echo $$ > "$lockdir/pid"
}

_lock_release() {
  local lockdir="$1"
  rm -rf "$lockdir"
}
