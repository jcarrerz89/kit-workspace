#!/bin/bash
# tmux session management

set -euo pipefail

TMUX_PREFIX="${TMUX_PREFIX:-kit}"

# Create a tmux session with multiple panes
tmux_create_session() {
  local session_name="$1"
  shift
  local pane_commands=("$@")

  if is_dry_run; then
    dry_run_log "Would create tmux session: $session_name"
    dry_run_log "  Panes: ${#pane_commands[@]}"
    for cmd in "${pane_commands[@]}"; do
      dry_run_log "  → $cmd"
    done
    return 0
  fi

  # Kill existing session
  tmux kill-session -t "$session_name" 2>/dev/null || true

  local first=true
  local pane_idx=0
  for cmd in "${pane_commands[@]}"; do
    if $first; then
      tmux new-session -d -s "$session_name" -n "agents"
      # Target first pane explicitly
      tmux send-keys -t "$session_name:agents.0" "$cmd" C-m
      first=false
    else
      tmux split-window -t "$session_name:agents"
      # Small delay to let pane initialize before sending keys
      sleep 0.2
      # Target the newest pane explicitly
      pane_idx=$((pane_idx + 1))
      tmux send-keys -t "$session_name:agents.${pane_idx}" "$cmd" C-m
    fi
  done

  # Apply tiled layout after all panes are created
  tmux select-layout -t "$session_name:agents" tiled
}

# Print tmux attach instructions
tmux_show_instructions() {
  local session_name="$1"

  echo ""
  log_ok "tmux session ready: ${BOLD}$session_name${NC}"
  echo ""
  echo -e "  ${GREEN}tmux attach -t $session_name${NC}"
  echo ""
  echo "  ┌──────────────────────────────────────────────────┐"
  echo "  │ Ctrl+B → ↑↓←→       Navigate between panes      │"
  echo "  │ Ctrl+B → z           Zoom pane (toggle)          │"
  echo "  │ Ctrl+B → d           Detach (keeps running)      │"
  echo "  │ Shift+Tab            Auto-accept (inside Claude) │"
  echo "  └──────────────────────────────────────────────────┘"
  echo ""
}

# Build the command string for launching claude in a pane
tmux_agent_cmd() {
  local worktree="$1"
  local agent_name="$2"
  local color="$3"  # green, yellow, red

  local color_code="32"
  case "$color" in
    yellow) color_code="33" ;;
    red)    color_code="31" ;;
    cyan)   color_code="36" ;;
  esac

  echo "cd '$worktree' && echo -e '\\033[1;${color_code}m🤖 $agent_name\\033[0m' && claude"
}
