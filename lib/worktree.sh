#!/bin/bash
# Git worktree management

set -euo pipefail

: "${KWS_DIR:?KWS_DIR not set — source from kit-workspace}"

# Lazily validate PROJECT_DIR and derive WORKTREE_ROOT — called at the top of each worktree function
_worktree_ensure_env() {
  : "${PROJECT_DIR:?PROJECT_DIR not set — must be set before calling worktree functions}"
  WORKTREE_ROOT="${WORKTREE_ROOT:-$(dirname "$PROJECT_DIR")/kit-worktrees}"
}

# Create a worktree for a branch
worktree_create() {
  _worktree_ensure_env
  local branch="$1"
  local worktree_path="$WORKTREE_ROOT/$branch"

  if is_dry_run; then
    if [ -d "$worktree_path" ]; then
      dry_run_log "Worktree already exists: $worktree_path"
    else
      dry_run_log "Would create worktree: $worktree_path ($branch)"
    fi
    return 0
  fi

  if [ -d "$worktree_path" ]; then
    log_step "Worktree exists: $branch"
    # Still sync .claude/ in case it changed
    worktree_sync_claude "$worktree_path"
    return 0
  fi

  # Create branch if needed
  if ! git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    if ! git branch "$branch" 2>/dev/null; then
      log_error "Could not create branch: $branch"
      return 1
    fi
  fi

  mkdir -p "$(dirname "$worktree_path")" || {
    log_error "Could not create directory for worktree: $(dirname "$worktree_path")"
    return 1
  }

  local wt_output
  wt_output=$(git worktree add "$worktree_path" "$branch" 2>&1)
  local wt_exit=$?

  if [ $wt_exit -ne 0 ]; then
    # Check if it failed because it already exists (not a real error)
    if [ -d "$worktree_path" ] && git worktree list 2>/dev/null | grep -q "$worktree_path"; then
      log_step "Worktree reused: $branch"
      worktree_sync_claude "$worktree_path"
      return 0
    else
      log_error "Error creating worktree ($branch): $wt_output"
      return 1
    fi
  fi

  # Sync .claude/ config to worktree
  worktree_sync_claude "$worktree_path"

  log_step "Worktree created: $branch"
}

# Copy .claude/ (settings, skills, commands) from kit-workspace install dir to worktree
worktree_sync_claude() {
  _worktree_ensure_env
  local worktree_path="$1"
  local source_claude="$KWS_DIR/.claude"

  [ -d "$source_claude" ] || return 0

  mkdir -p "$worktree_path/.claude"

  # Copy settings (allowlist, permissions)
  if [ -f "$source_claude/settings.json" ]; then
    cp "$source_claude/settings.json" "$worktree_path/.claude/settings.json"
  fi

  # Symlink skills (follows project symlink or resolves to source)
  if [ -d "$source_claude/skills" ]; then
    local skills_real
    skills_real=$(cd "$source_claude/skills" 2>/dev/null && pwd -P) || {
      log_warn "Cannot resolve skills directory: $source_claude/skills"
      skills_real=""
    }
    [ -n "$skills_real" ] && ln -sf "$skills_real" "$worktree_path/.claude/skills"
  fi

  # Symlink commands (follows project symlink or resolves to source)
  if [ -d "$source_claude/commands" ]; then
    local cmds_real
    cmds_real=$(cd "$source_claude/commands" 2>/dev/null && pwd -P) || {
      log_warn "Cannot resolve commands directory: $source_claude/commands"
      cmds_real=""
    }
    [ -n "$cmds_real" ] && ln -sf "$cmds_real" "$worktree_path/.claude/commands"
  fi

  # Copy CLAUDE.md if exists
  if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    cp "$PROJECT_DIR/CLAUDE.md" "$worktree_path/CLAUDE.md"
  fi

  # Copy .kit-ws/ config if exists
  if [ -d "$PROJECT_DIR/.kit-ws" ]; then
    cp -r "$PROJECT_DIR/.kit-ws" "$worktree_path/"
  fi
}

# Remove a worktree
worktree_remove() {
  _worktree_ensure_env
  local branch="$1"
  local worktree_path="$WORKTREE_ROOT/$branch"

  if [ -d "$worktree_path" ]; then
    if ! git worktree remove "$worktree_path" --force 2>/dev/null; then
      log_warn "Could not cleanly remove worktree: $branch — attempting rm"
      rm -rf "$worktree_path"
      git worktree prune 2>/dev/null
    fi
    log_step "Worktree removed: $branch"
  fi
}

# Get worktree path for a branch
worktree_path() {
  _worktree_ensure_env
  local branch="$1"
  echo "$WORKTREE_ROOT/$branch"
}

# Create all worktrees for a task
worktrees_setup() {
  _worktree_ensure_env
  local task_json="$1"

  log_info "Setting up worktrees..."

  # Validate no duplicate branches
  local branches=()
  local dupes=""
  while IFS= read -r agent; do
    local branch=$(echo "$agent" | jq -r '.branch')
    for existing in "${branches[@]}"; do
      if [ "$existing" = "$branch" ]; then
        dupes+="$branch "
      fi
    done
    branches+=("$branch")
  done < <(task_agents "$task_json")

  if [ -n "$dupes" ]; then
    log_error "Duplicate branches detected: $dupes"
    log_error "Each agent needs its own branch to avoid conflicts"
    return 1
  fi

  while IFS= read -r agent; do
    local branch=$(echo "$agent" | jq -r '.branch')
    worktree_create "$branch"
  done < <(task_agents "$task_json")
}
