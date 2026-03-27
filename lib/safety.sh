#!/bin/bash
# Safety — preflight checks and permission management

safety_preflight() {
  local mode="$1"

  # Always check dependencies
  local missing=()
  command -v tmux   >/dev/null 2>&1 || missing+=("tmux")
  command -v claude >/dev/null 2>&1 || missing+=("claude")
  command -v git    >/dev/null 2>&1 || missing+=("git")
  command -v jq     >/dev/null 2>&1 || missing+=("jq")

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing dependencies: ${missing[*]}"
    echo "  brew install ${missing[*]}"
    exit 1
  fi

  # For mode 3 (fire & forget): ensure git is clean
  if [ "$mode" = "3" ]; then
    safety_ensure_committed
    # Only warn about skip-permissions if that's the active strategy
    local ff_strat
    ff_strat=$(safety_ff_permission_strategy "$CONFIG_FILE" 2>/dev/null || echo "skip-all")
    if [ "$ff_strat" = "skip-all" ]; then
      safety_log_permission_warning
    fi
  fi

  # Apply permission allowlist if available (mode 2)
  if [ "$mode" = "2" ]; then
    safety_apply_allowlist
  fi

  # For mode 4 (agent teams): verify flag is enabled
  if [ "$mode" = "4" ]; then
    safety_check_agent_teams
  fi
}

safety_ensure_committed() {
  if is_dry_run; then
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      dry_run_log "Would create git checkpoint (uncommitted changes detected)"
    fi
    return 0
  fi

  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    log_warn "Uncommitted changes detected. Creating checkpoint..."
    git add -A
    git commit -m "kit-checkpoint: pre fire-and-forget $(date +%Y%m%d-%H%M%S)" || true
    log_ok "Checkpoint created — revert with: git reset --soft HEAD~1"
  fi
}

safety_apply_allowlist() {
  local allowlist="$PROJECT_DIR/.kit-ws/permissions/allowlist.json"
  local target="$PROJECT_DIR/.claude/settings.json"

  if [ ! -f "$allowlist" ]; then
    log_step "No allowlist found — Claude will prompt for permissions normally"
    return 0
  fi

  # Validate allowlist is valid JSON
  if ! jq empty "$allowlist" 2>/dev/null; then
    log_error "Invalid allowlist (malformed JSON): $allowlist"
    return 1
  fi

  # Create .claude dir if needed
  mkdir -p "$(dirname "$target")"

  # Atomic merge: write to tmp then mv
  local tmp_target="${target}.tmp.$$"

  if [ -f "$target" ]; then
    # Validate existing settings is valid JSON
    if ! jq empty "$target" 2>/dev/null; then
      log_warn "Existing settings.json is invalid — replacing with allowlist"
      cp "$allowlist" "$tmp_target" && mv "$tmp_target" "$target"
      log_step "Allowlist applied (replacement) to .claude/settings.json"
      return 0
    fi
    # Merge permissions into existing (atomic write with validation)
    if jq -s '.[0] * .[1]' "$target" "$allowlist" > "$tmp_target" 2>/dev/null \
       && [ -s "$tmp_target" ] \
       && jq empty "$tmp_target" 2>/dev/null; then
      mv "$tmp_target" "$target"
      log_step "Allowlist applied to .claude/settings.json"
    else
      rm -f "$tmp_target"
      log_error "Error merging allowlist with settings.json (result empty or invalid)"
      return 1
    fi
  else
    cp "$allowlist" "$target"
    log_step "Allowlist created at .claude/settings.json"
  fi
}

# ---------------------------------------------------------------------------
# Log explicit warning when Mode 3 uses --dangerously-skip-permissions
# Transparency: user should know what permissions are bypassed
# ---------------------------------------------------------------------------
safety_log_permission_warning() {
  log_warn "Mode 3 uses --dangerously-skip-permissions (all tool permissions bypassed)"
  echo "  Mitigations active:"
  echo "    - Git worktree isolation (changes are in separate branch)"
  echo "    - Boundary guard (post-completion scope validation)"
  echo "    - Stall sentinel (stuck loop detection)"
  echo "    - Ghost guard (phantom completion detection)"
  echo ""
  echo "  To use allowlist-based permissions instead (requires terminal):"
  echo "    Set permissions.fire_forget: \"allowlist\" in .kit-ws/config.json"
  echo ""
}

# ---------------------------------------------------------------------------
# Determine permission strategy for Mode 3
# Returns: "skip-all" (default, headless) or "allowlist" (terminal required)
# ---------------------------------------------------------------------------
safety_ff_permission_strategy() {
  local config_file="${1:-}"
  local strategy="skip-all"

  if [ -n "$config_file" ] && [ -f "$config_file" ]; then
    local configured
    configured=$(jq -r '.permissions.fire_forget // "skip-all"' "$config_file" 2>/dev/null)
    if [ "$configured" = "allowlist" ]; then
      strategy="allowlist"
    fi
  fi

  echo "$strategy"
}

# ---------------------------------------------------------------------------
# Apply scope-restricted settings to a worktree for Mode 3 allowlist mode
# Creates a .claude/settings.json in the worktree with pre-approved tools
# ---------------------------------------------------------------------------
safety_apply_worktree_allowlist() {
  local worktree_path="$1"
  local role="$2"

  if [ -z "$worktree_path" ] || [ -z "$role" ]; then
    log_error "safety_apply_worktree_allowlist: missing worktree_path or role"
    return 1
  fi

  # Use project allowlist as base, or create a default one
  local project_allowlist="$PROJECT_DIR/.kit-ws/permissions/allowlist.json"
  local wt_settings="$worktree_path/.claude/settings.json"
  mkdir -p "$(dirname "$wt_settings")"

  if [ -f "$project_allowlist" ]; then
    cp "$project_allowlist" "$wt_settings"
    log_step "Allowlist applied to worktree for $role"
  else
    # Default generic allowlist for fire-and-forget
    cat > "$wt_settings" << 'ALLOWLIST'
{
  "permissions": {
    "allow": [
      "Read(**)",
      "Write(**)",
      "Bash(git add*)",
      "Bash(git commit*)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Bash(git status*)",
      "Bash(ls*)",
      "Bash(cat*)",
      "Bash(mkdir*)"
    ],
    "deny": [
      "Bash(rm -rf*)",
      "Bash(git push*)",
      "Bash(git reset --hard*)",
      "Bash(curl*)",
      "Bash(wget*)"
    ]
  }
}
ALLOWLIST
    log_step "Default generic allowlist created for $role"
  fi
}

safety_check_agent_teams() {
  local settings="$HOME/.claude/settings.json"

  if [ ! -f "$settings" ] || ! grep -q "agentTeams" "$settings" 2>/dev/null; then
    log_warn "Agent Teams not enabled"
    echo ""
    echo "  Run once:"
    echo "    claude config set experiments.agentTeams true"
    echo ""
    read -p "  Continue anyway? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_error "Aborted: Agent Teams not enabled"
      exit 1
    fi
  fi
}
