#!/bin/bash
# =============================================================================
# Orchestrator — Runs tasks in the 4 modes
# =============================================================================

# Required variables from parent
: "${STATE_DIR:?STATE_DIR not set — source from kit-workspace}"
: "${TMUX_PREFIX:?TMUX_PREFIX not set — source from tmux-manager.sh}"

# ---------------------------------------------------------------------------
# Cleanup helper for fire-and-forget: kills background agent PIDs on interrupt
# ---------------------------------------------------------------------------
_ff_cleanup() {
  local sid="${1:-}"
  log_warn "Interrupt received — stopping background agents..."
  if [ -f "$STATE_DIR/active_pids" ]; then
    while IFS='|' read -r apid arole abranch; do
      [ -z "$apid" ] && continue
      if kill -0 "$apid" 2>/dev/null; then
        kill "$apid" 2>/dev/null || true
        log_step "Stopped: $arole (PID $apid)"
      fi
    done < "$STATE_DIR/active_pids"
  fi
  # Mark checkpoint as interrupted if possible
  if [ -n "$sid" ] && type checkpoint_agent_failed &>/dev/null; then
    log_step "Checkpoint marked as interrupted"
  fi
}

# ---------------------------------------------------------------------------
# Mode 1: Supervised
# tmux with panes, you control each agent manually
# ---------------------------------------------------------------------------
orchestrate_supervised() {
  local task_json="$1"
  local task_name=$(task_field "$task_json" "name")
  local session_name="${TMUX_PREFIX}-${task_name}"

  log_info "Mode 1: Supervised"
  echo ""

  if is_dry_run; then
    dry_run_log "━━━ Simulation Mode 1: Supervised ━━━"
    dry_run_log "tmux session: $session_name"
    worktrees_setup "$task_json"
    task_agents "$task_json" | while IFS= read -r agent; do
      local role=$(echo "$agent" | jq -r '.role')
      local branch=$(echo "$agent" | jq -r '.branch')
      dry_run_log "Pane: $role → worktree $branch → interactive claude"
    done
    dry_run_log "━━━ End simulation ━━━"
    return 0
  fi

  # Setup worktrees
  worktrees_setup "$task_json"

  # Build pane commands (process substitution to avoid subshell scoping)
  local -a cmds=()
  while IFS= read -r agent; do
    local role=$(echo "$agent" | jq -r '.role')
    local branch=$(echo "$agent" | jq -r '.branch')
    local wt=$(worktree_path "$branch")
    cmds+=("$(tmux_agent_cmd "$wt" "$role" "green")")
  done < <(task_agents "$task_json")

  if [ ${#cmds[@]} -eq 0 ]; then
    log_error "No agents found in task"
    return 1
  fi

  # Create tmux session
  tmux_create_session "$session_name" "${cmds[@]}"
  tmux_show_instructions "$session_name"

  echo "  Each pane has Claude Code open in its worktree."
  echo "  Type your prompt in each pane to start."
  echo ""
}

# ---------------------------------------------------------------------------
# Mode 2: Semi-auto
# tmux with panes, prompt sent automatically, Shift+Tab for auto-accept
# ---------------------------------------------------------------------------
orchestrate_semi_auto() {
  local task_json="$1"
  local task_name=$(task_field "$task_json" "name")
  local session_name="${TMUX_PREFIX}-${task_name}"

  log_info "Mode 2: Semi-auto"
  echo ""

  if is_dry_run; then
    dry_run_log "━━━ Simulation Mode 2: Semi-auto ━━━"
    dry_run_log "tmux session: $session_name"
    worktrees_setup "$task_json"
    task_agents "$task_json" | while IFS= read -r agent; do
      local role=$(echo "$agent" | jq -r '.role')
      local branch=$(echo "$agent" | jq -r '.branch')
      local profile_name=$(echo "$agent" | jq -r '.profile')
      dry_run_log "Pane: $role ($profile_name) → worktree $branch"
      dry_run_log "  Prompt would be saved at: \$STATE_DIR/prompts/${task_name}_${role}.txt"
    done
    dry_run_log "Allowlist would be applied to .claude/settings.json"
    dry_run_log "━━━ End simulation ━━━"
    return 0
  fi

  # Setup worktrees
  worktrees_setup "$task_json"

  # Kill existing session
  tmux kill-session -t "$session_name" 2>/dev/null || true

  local first=true
  local agent_idx=0

  while IFS= read -r agent; do
    local role=$(echo "$agent" | jq -r '.role')
    local branch=$(echo "$agent" | jq -r '.branch')
    local profile_name=$(echo "$agent" | jq -r '.profile')
    local wt=$(worktree_path "$branch")

    # Build the prompt for this agent
    local prompt=$(build_agent_prompt "$task_json" "$agent")

    # Create prompt file (safer than sending via tmux keys)
    local prompt_file="$STATE_DIR/prompts/${task_name}_${role}.txt"
    mkdir -p "$(dirname "$prompt_file")"
    echo "$prompt" > "$prompt_file"

    local launch_cmd="cd '$wt' && echo -e '\\033[1;33m🤖 $role (semi-auto)\\033[0m' && echo 'Prompt saved at: $prompt_file' && echo 'Tip: Shift+Tab for auto-accept' && claude"

    if $first; then
      tmux new-session -d -s "$session_name" -n "agents"
      tmux send-keys -t "$session_name:agents" "$launch_cmd" C-m
      first=false
    else
      tmux split-window -t "$session_name:agents" -v
      tmux send-keys -t "$session_name:agents" "$launch_cmd" C-m
    fi

    # Wait for claude to start, then load the prompt from file
    sleep 3
    # Use tmux load-buffer + paste-buffer to send full multi-line prompt
    tmux load-buffer "$prompt_file" 2>/dev/null && \
      tmux paste-buffer -t "$session_name:agents" 2>/dev/null && \
      tmux send-keys -t "$session_name:agents" C-m 2>/dev/null || {
        log_warn "Could not send prompt to $role — copy it manually from: $prompt_file"
      }

    agent_idx=$((agent_idx + 1))
  done < <(task_agents "$task_json")

  tmux select-layout -t "$session_name:agents" tiled
  tmux_show_instructions "$session_name"

  echo -e "  ${YELLOW}IMPORTANT:${NC} In each pane, press ${BOLD}Shift+Tab${NC} for auto-accept."
  echo ""
  echo "  Full prompts are in:"
  ls "$STATE_DIR/prompts/${task_name}_"*.txt 2>/dev/null | while read -r f; do
    echo "    $f"
  done
  echo ""
  echo "  If the prompt was not sent correctly, copy and paste from the file."
  echo ""
}

# ---------------------------------------------------------------------------
# Mode 3: Fire & Forget
# Headless background, no supervision, results in JSON
# ---------------------------------------------------------------------------
orchestrate_fire_forget() {
  local task_json="$1"
  local task_name=$(task_field "$task_json" "name")
  local sid=$(session_id)

  log_info "Mode 3: Fire & Forget"
  echo ""

  # Trap: on interrupt, kill background agent processes and clean up
  trap '_ff_cleanup "$sid"' INT TERM

  # Checkpoint: record session start for crash recovery
  if type checkpoint_init &>/dev/null; then
    checkpoint_init "${PROJECT_DIR:-.}"
    local agents_roles
    agents_roles=$(echo "$task_json" | jq -c '[.agents[].role]')
    checkpoint_start "$sid" "$task_name" "3" "$agents_roles"
  fi

  if is_dry_run; then
    dry_run_log "━━━ Simulation Mode 3: Fire & Forget ━━━"
    dry_run_log "Session ID: $sid"
    worktrees_setup "$task_json"
    task_agents "$task_json" | while IFS= read -r agent; do
      local role=$(echo "$agent" | jq -r '.role')
      local branch=$(echo "$agent" | jq -r '.branch')
      dry_run_log "Headless agent: $role → worktree $branch"
      dry_run_log "  Log: \$STATE_DIR/logs/${sid}_${role}.log"
      dry_run_log "  Result: \$STATE_DIR/results/${sid}_${role}.json"
      dry_run_log "  Command: claude -p <prompt> --dangerously-skip-permissions --output-format json"
    done
    dry_run_log "━━━ End simulation ━━━"
    return 0
  fi

  # Initialize contracts directory
  if type contracts_init &>/dev/null; then
    contracts_init
  fi

  # Setup worktrees
  worktrees_setup "$task_json"

  # Clear previous PIDs (ensure state dir exists)
  mkdir -p "$STATE_DIR"
  > "$STATE_DIR/active_pids"

  local agent_count=0

  # Resolve execution order: agents with depends_on run after their dependencies
  local has_deps
  has_deps=$(echo "$task_json" | jq '[.agents[] | select(.depends_on)] | length')

  if [ "$has_deps" -gt 0 ] && type resolve_agent_order &>/dev/null; then
    log_step "Dependency ordering detected — launching in groups"
    _ff_launch_ordered "$task_json" "$sid"
    return $?
  fi

  # Determine permission strategy for Mode 3
  local ff_strategy="skip-all"
  if type safety_ff_permission_strategy &>/dev/null; then
    ff_strategy=$(safety_ff_permission_strategy "$CONFIG_FILE")
  fi

  # No dependencies: launch all agents in parallel (original behavior)
  while IFS= read -r agent; do
    local role=$(echo "$agent" | jq -r '.role')
    local branch=$(echo "$agent" | jq -r '.branch')
    local wt=$(worktree_path "$branch")

    # Build prompt with boundary enforcement injected
    local prompt=$(build_agent_prompt "$task_json" "$agent")
    if type boundary_inject_prompt &>/dev/null; then
      prompt+=$(boundary_inject_prompt "$role" "$CONFIG_FILE")
    fi

    # Apply permission strategy
    if [ "$ff_strategy" = "allowlist" ] && type safety_apply_worktree_allowlist &>/dev/null; then
      safety_apply_worktree_allowlist "$wt" "$role"
    fi

    # Paths
    local log_file="$STATE_DIR/logs/${sid}_${role}.log"
    local result_file="$STATE_DIR/results/${sid}_${role}.json"

    log_step "Launching: $role → PID..."

    # Read retry + timeout config
    local max_retries=$(jq -r '.retry.max_retries // 2' "$CONFIG_FILE" 2>/dev/null || echo "2")
    local cooldown=$(jq -r '.retry.cooldown_seconds // 5' "$CONFIG_FILE" 2>/dev/null || echo "5")
    local agent_timeout=$(jq -r '.timeout.agent_seconds // 1800' "$CONFIG_FILE" 2>/dev/null || echo "1800")

    # Ensure state dirs exist
    mkdir -p "$STATE_DIR/logs" "$STATE_DIR/results"

    # Launch headless claude in background with diagnose-and-adapt retry
    (
      safe_cd "$wt" || exit 1
      attempt=0
      success=false
      last_error=""

      # Claude CLI flags based on permission strategy
      claude_flags="--output-format json"
      if [ "$ff_strategy" = "skip-all" ]; then
        claude_flags="--dangerously-skip-permissions --output-format json"
      fi

      # Read known-fixes for error diagnosis
      known_fixes_file="$PROJECT_DIR/.kit-ws/known-fixes.json"

      while [ "$attempt" -lt "$max_retries" ] && [ "$success" = "false" ]; do
        attempt=$((attempt + 1))
        current_prompt="$prompt"

        if [ "$attempt" -gt 1 ]; then
          echo "$(date +%Y-%m-%dT%H:%M:%S) $role retry $attempt/$max_retries (diagnose-and-adapt)" >> "$STATE_DIR/logs/${sid}_summary.log"

          # Stall Sentinel: check if agent is stuck in a loop before retrying
          if type sentinel_check &>/dev/null; then
            if ! sentinel_check "$role" "$log_file" "$STATE_DIR"; then
              echo "$(date +%Y-%m-%dT%H:%M:%S) STALL-SENTINEL: $role stopped — repeated similar errors detected" >> "$STATE_DIR/logs/${sid}_summary.log"
              success=false
              break  # Exit retry loop, fall through to circuit breaker
            fi
          fi

          # Exponential backoff: cooldown * attempt
          sleep $((cooldown * attempt))

          # --- Diagnose-and-adapt: enrich prompt with error context ---
          last_error=$(tail -50 "$log_file" 2>/dev/null || echo 'no log')
          adapt_context="

--- RETRY CONTEXT (attempt $attempt/$max_retries) ---
Previous attempt failed. Error:

\`\`\`
$last_error
\`\`\`
"
          # Check known-fixes for matching patterns
          if [ -f "$known_fixes_file" ]; then
            matched_fix=$(jq -r --arg err "$last_error" '
              .[] | select(.pattern as $p | $err | test($p; "i"))
              | "KNOWN FIX for \(.pattern): \(.fix)"
            ' "$known_fixes_file" 2>/dev/null | head -3)
            if [ -n "$matched_fix" ]; then
              adapt_context+="
Relevant known fixes:
$matched_fix
"
            fi
          fi

          adapt_context+="
INSTRUCTION: Use a DIFFERENT approach from the previous attempt. If the error suggests a specific problem, address it directly. Do not repeat the same strategy that failed.
--- END RETRY CONTEXT ---"

          current_prompt="${prompt}${adapt_context}"
        fi

        # Run with timeout to prevent hangs
        timeout "${agent_timeout}s" claude -p "$current_prompt" \
          $claude_flags \
          > "$result_file" 2>"$log_file"

        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
          success=true
          echo "$(date +%Y-%m-%dT%H:%M:%S) $role completed (attempt $attempt)" >> "$STATE_DIR/logs/${sid}_summary.log"

          # Boundary guard: validate agent stayed within scope
          if type boundary_check &>/dev/null; then
            if ! boundary_check "$role" "$(pwd)" "$CONFIG_FILE"; then
              echo "$(date +%Y-%m-%dT%H:%M:%S) BOUNDARY-GUARD: $role modified files outside scope" >> "$STATE_DIR/logs/${sid}_summary.log"
            fi
          fi

          # Clear sentinel state on success
          type sentinel_reset &>/dev/null && sentinel_reset "$role" "$STATE_DIR"
          # Checkpoint: mark agent completed
          type checkpoint_agent_completed &>/dev/null && checkpoint_agent_completed "$sid" "$role" "0"
        elif [ $exit_code -eq 124 ]; then
          echo "$(date +%Y-%m-%dT%H:%M:%S) $role attempt $attempt TIMEOUT after ${agent_timeout}s" >> "$STATE_DIR/logs/${sid}_summary.log"
        else
          echo "$(date +%Y-%m-%dT%H:%M:%S) $role attempt $attempt failed (exit $exit_code)" >> "$STATE_DIR/logs/${sid}_summary.log"
        fi
      done

      # Circuit breaker: if all retries failed → structured post-mortem with diagnosis
      if [ "$success" = "false" ]; then
        echo "$(date +%Y-%m-%dT%H:%M:%S) CIRCUIT-BREAKER: $role failed after $max_retries attempts" >> "$STATE_DIR/logs/${sid}_summary.log"
        # Save post-mortem with full diagnosis for human review
        jq -n \
          --arg role "$role" \
          --arg attempts "$max_retries" \
          --arg log "$(tail -50 "$log_file" 2>/dev/null || echo 'no log')" \
          --arg ts "$(date +%Y-%m-%dT%H:%M:%S)" \
          --arg diagnosis "Agent failed $max_retries attempts with diagnose-and-adapt. Last error attached. Recommend: review in Mode 1 (supervised) or check known-fixes.json." \
          '{role: $role, attempts: ($attempts | tonumber), last_error: $log, timestamp: $ts, diagnosis: $diagnosis, escalation: "mode-1"}' \
          > "$STATE_DIR/results/${sid}_${role}_postmortem.json"
        # Checkpoint: mark agent failed
        type checkpoint_agent_failed &>/dev/null && checkpoint_agent_failed "$sid" "$role" "exhausted $max_retries retries"

        # Active notification on failure
        type notify_agent_failure &>/dev/null && notify_agent_failure "$role" "$max_retries" "$STATE_DIR/results/${sid}_${role}_postmortem.json"
      fi
    ) &

    local pid=$!
    echo "$pid|$role|$branch" >> "$STATE_DIR/active_pids"
    log_step "  $role → PID $pid"

    # Checkpoint: mark agent started
    type checkpoint_agent_started &>/dev/null && checkpoint_agent_started "$sid" "$role"

    agent_count=$((agent_count + 1))
  done < <(task_agents "$task_json")

  # Checkpoint: background waiter to mark session complete when all agents finish
  (
    # Wait for all agent PIDs to finish
    while IFS='|' read -r apid arole abranch; do
      wait "$apid" 2>/dev/null || true
    done < "$STATE_DIR/active_pids"

    # Cross-agent contract validation
    if type contracts_validate_cross_agent &>/dev/null; then
      if ! contracts_validate_cross_agent; then
        echo "$(date +%Y-%m-%dT%H:%M:%S) CONTRACT-VALIDATOR: cross-agent conflicts detected" >> "$STATE_DIR/logs/${sid}_summary.log"
        type notify_agent_failure &>/dev/null && notify_agent_failure "contract-validator" "0" ""
      fi
    fi

    # Swarm completion notification
    local failed_count
    failed_count=$(grep -c "CIRCUIT-BREAKER\|STALL-SENTINEL" "$STATE_DIR/logs/${sid}_summary.log" 2>/dev/null) || failed_count=0
    type notify_swarm_complete &>/dev/null && notify_swarm_complete "$task_name" "$agent_count" "$failed_count"

    # Checkpoint complete
    type checkpoint_complete &>/dev/null && checkpoint_complete "$sid"
  ) &

  # Save session info
  cat > "$STATE_DIR/current_session.json" << EOF
{
  "id": "$sid",
  "task": "$task_name",
  "mode": 3,
  "agents": $agent_count,
  "started": "$(date +%Y-%m-%dT%H:%M:%S)"
}
EOF

  echo ""
  log_ok "$agent_count agents launched in background"
  echo ""
  echo -e "  ${CYAN}Monitor:${NC}"
  echo "    kit-workspace status"
  echo "    tail -f $STATE_DIR/logs/${sid}_*.log"
  echo ""
  echo -e "  ${CYAN}Results (when done):${NC}"
  echo "    ls $STATE_DIR/results/${sid}_*"
  echo "    cat $STATE_DIR/results/${sid}_<role>.json | jq '.result'"
  echo ""
  echo -e "  ${CYAN}If something goes wrong:${NC}"
  echo "    kit-workspace stop"
  echo "    git reset --hard HEAD  # in each worktree"
  echo ""
  echo -e "  ${CYAN}Review changes:${NC}"
  task_agents "$task_json" | while IFS= read -r agent; do
    local branch=$(echo "$agent" | jq -r '.branch')
    local role=$(echo "$agent" | jq -r '.role')
    echo "    cd $(worktree_path "$branch") && git diff HEAD~1  # $role"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# _ff_launch_ordered — Fire & Forget with dependency ordering
# Launches agents in groups: group 0 first, wait, then group 1, etc.
# Contracts written by group N are available to group N+1.
# ---------------------------------------------------------------------------
_ff_launch_ordered() {
  local task_json="$1"
  local sid="$2"
  local task_name=$(task_field "$task_json" "name")

  local groups
  groups=$(resolve_agent_order "$task_json")

  local total_groups=$(echo "$groups" | jq 'length')
  local agent_count=0

  # Determine permission strategy once (not per group)
  local ff_strategy="skip-all"
  if type safety_ff_permission_strategy &>/dev/null; then
    ff_strategy=$(safety_ff_permission_strategy "$CONFIG_FILE")
  fi

  for group_idx in $(seq 0 $((total_groups - 1))); do
    local level=$(echo "$groups" | jq ".[$group_idx].level")
    local group_agents=$(echo "$groups" | jq -c ".[$group_idx].agents[]")

    log_step "Group $level: launching agents..."

    local group_pids=()

    while IFS= read -r agent; do
      [ -z "$agent" ] && continue
      local role=$(echo "$agent" | jq -r '.role')
      local branch=$(echo "$agent" | jq -r '.branch')
      local wt=$(worktree_path "$branch")

      # Build prompt with boundary enforcement injected
      local prompt=$(build_agent_prompt "$task_json" "$agent")
      if type boundary_inject_prompt &>/dev/null; then
        prompt+=$(boundary_inject_prompt "$role" "$CONFIG_FILE")
      fi

      # Apply permission strategy
      if [ "$ff_strategy" = "allowlist" ] && type safety_apply_worktree_allowlist &>/dev/null; then
        safety_apply_worktree_allowlist "$wt" "$role"
      fi

      local log_file="$STATE_DIR/logs/${sid}_${role}.log"
      local result_file="$STATE_DIR/results/${sid}_${role}.json"
      mkdir -p "$STATE_DIR/logs" "$STATE_DIR/results"

      local max_retries=$(jq -r '.retry.max_retries // 2' "$CONFIG_FILE" 2>/dev/null || echo "2")
      local cooldown=$(jq -r '.retry.cooldown_seconds // 5' "$CONFIG_FILE" 2>/dev/null || echo "5")
      local agent_timeout=$(jq -r '.timeout.agent_seconds // 1800' "$CONFIG_FILE" 2>/dev/null || echo "1800")

      (
        safe_cd "$wt" || exit 1
        attempt=0
        success=false
        known_fixes_file="$PROJECT_DIR/.kit-ws/known-fixes.json"

        # Claude CLI flags based on permission strategy
        claude_flags="--output-format json"
        if [ "$ff_strategy" = "skip-all" ]; then
          claude_flags="--dangerously-skip-permissions --output-format json"
        fi

        while [ "$attempt" -lt "$max_retries" ] && [ "$success" = "false" ]; do
          attempt=$((attempt + 1))
          current_prompt="$prompt"

          if [ "$attempt" -gt 1 ]; then
            echo "$(date +%Y-%m-%dT%H:%M:%S) $role retry $attempt/$max_retries" >> "$STATE_DIR/logs/${sid}_summary.log"

            if type sentinel_check &>/dev/null; then
              if ! sentinel_check "$role" "$log_file" "$STATE_DIR"; then
                break
              fi
            fi

            sleep $((cooldown * attempt))

            last_error=$(tail -50 "$log_file" 2>/dev/null || echo 'no log')
            adapt_context="
--- RETRY CONTEXT (attempt $attempt/$max_retries) ---
Previous attempt failed:
\`\`\`
$last_error
\`\`\`"
            # Check known-fixes for matching patterns (diagnose-and-adapt)
            if [ -f "$known_fixes_file" ]; then
              matched_fix=$(jq -r --arg err "$last_error" '
                .[] | select(
                  (.pattern as $p | $err | test($p; "i")) or
                  (.tags != null and ([.tags[] | select($err | test(.; "i"))] | length) > 0)
                ) | "KNOWN FIX for \(.pattern): \(.fix)"
              ' "$known_fixes_file" 2>/dev/null | head -3)
              if [ -n "$matched_fix" ]; then
                adapt_context+="
Relevant known fixes:
$matched_fix"
              fi
            fi
            adapt_context+="
Use a DIFFERENT approach. Do not repeat the same strategy.
--- END RETRY CONTEXT ---"
            current_prompt="${prompt}${adapt_context}"
          fi

          timeout "${agent_timeout}s" claude -p "$current_prompt" \
            $claude_flags \
            > "$result_file" 2>"$log_file"

          if [ $? -eq 0 ]; then
            success=true
            echo "$(date +%Y-%m-%dT%H:%M:%S) $role completed (attempt $attempt)" >> "$STATE_DIR/logs/${sid}_summary.log"

            # Boundary guard: validate agent stayed within scope
            if type boundary_check &>/dev/null; then
              if ! boundary_check "$role" "$(pwd)" "$CONFIG_FILE"; then
                echo "$(date +%Y-%m-%dT%H:%M:%S) BOUNDARY-GUARD: $role modified files outside scope" >> "$STATE_DIR/logs/${sid}_summary.log"
              fi
            fi

            type sentinel_reset &>/dev/null && sentinel_reset "$role" "$STATE_DIR"
            type checkpoint_agent_completed &>/dev/null && checkpoint_agent_completed "$sid" "$role" "0"
          fi
        done

        if [ "$success" = "false" ]; then
          echo "$(date +%Y-%m-%dT%H:%M:%S) CIRCUIT-BREAKER: $role failed after $max_retries attempts" >> "$STATE_DIR/logs/${sid}_summary.log"
          jq -n \
            --arg role "$role" \
            --arg attempts "$max_retries" \
            --arg log "$(tail -50 "$log_file" 2>/dev/null || echo 'no log')" \
            --arg ts "$(date +%Y-%m-%dT%H:%M:%S)" \
            --arg diagnosis "Agent failed $max_retries attempts with diagnose-and-adapt. Last error attached. Recommend: review in Mode 1 (supervised) or check known-fixes.json." \
            '{role: $role, attempts: ($attempts | tonumber), last_error: $log, timestamp: $ts, diagnosis: $diagnosis, escalation: "mode-1"}' \
            > "$STATE_DIR/results/${sid}_${role}_postmortem.json"
          type checkpoint_agent_failed &>/dev/null && checkpoint_agent_failed "$sid" "$role" "exhausted $max_retries retries"

          # Active notification on failure
          type notify_agent_failure &>/dev/null && notify_agent_failure "$role" "$max_retries" "$STATE_DIR/results/${sid}_${role}_postmortem.json"
        fi
      ) &

      local pid=$!
      echo "$pid|$role|$branch" >> "$STATE_DIR/active_pids"
      group_pids+=("$pid")
      log_step "  $role → PID $pid (group $level)"

      type checkpoint_agent_started &>/dev/null && checkpoint_agent_started "$sid" "$role"
      agent_count=$((agent_count + 1))
    done <<< "$group_agents"

    # Wait for this group to finish before launching next group
    if [ $group_idx -lt $((total_groups - 1)) ]; then
      log_step "Waiting for group $level before launching group $((level + 1))..."
      for pid in "${group_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done
      log_ok "Group $level completed — contracts available for group $((level + 1))"
    fi
  done

  # Background waiter for checkpoint completion + contract validation
  (
    while IFS='|' read -r apid arole abranch; do
      wait "$apid" 2>/dev/null || true
    done < "$STATE_DIR/active_pids"

    # Cross-agent contract validation
    if type contracts_validate_cross_agent &>/dev/null; then
      if ! contracts_validate_cross_agent; then
        echo "$(date +%Y-%m-%dT%H:%M:%S) CONTRACT-VALIDATOR: cross-agent conflicts detected" >> "$STATE_DIR/logs/${sid}_summary.log"
        type notify_agent_failure &>/dev/null && notify_agent_failure "contract-validator" "0" ""
      fi
    fi

    # Swarm completion notification
    local failed_count
    failed_count=$(grep -c "CIRCUIT-BREAKER\|STALL-SENTINEL" "$STATE_DIR/logs/${sid}_summary.log" 2>/dev/null) || failed_count=0
    type notify_swarm_complete &>/dev/null && notify_swarm_complete "$task_name" "$agent_count" "$failed_count"

    # Checkpoint complete
    type checkpoint_complete &>/dev/null && checkpoint_complete "$sid"
  ) &

  # Save session info
  cat > "$STATE_DIR/current_session.json" << EOF
{
  "id": "$sid",
  "task": "$task_name",
  "mode": 3,
  "agents": $agent_count,
  "ordered": true,
  "groups": $total_groups,
  "started": "$(date +%Y-%m-%dT%H:%M:%S)"
}
EOF

  echo ""
  log_ok "$agent_count agents launched in $total_groups group(s)"
  echo ""
}

# ---------------------------------------------------------------------------
# Mode 4: Agent Teams (native Claude Code)
# Uses Agent Teams API: shared task list, inter-agent messaging, team lead
# ---------------------------------------------------------------------------
orchestrate_agent_teams() {
  local task_json="$1"
  local task_name=$(task_field "$task_json" "name")
  local task_type=$(task_field "$task_json" "type")
  local task_desc=$(task_field "$task_json" "description")
  local task_phase=$(echo "$task_json" | jq -r '.phase // "build"')

  log_info "Mode 4: Agent Teams (native)"
  echo ""

  if is_dry_run; then
    dry_run_log "━━━ Simulation Mode 4: Agent Teams (native) ━━━"
    dry_run_log "Team: kws-${task_name}"
    dry_run_log "Requires: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
    task_agents "$task_json" | while IFS= read -r agent; do
      local role=$(echo "$agent" | jq -r '.role')
      local profile_name=$(echo "$agent" | jq -r '.profile')
      dry_run_log "Teammate: $role ($profile_name)"
    done
    dry_run_log "Native features:"
    dry_run_log "  - Shared task list with dependencies"
    dry_run_log "  - Direct messaging between teammates"
    dry_run_log "  - Team lead consolidates automatically"
    dry_run_log "  - Plan approval for high-risk tasks"
    dry_run_log "  - TeammateIdle + TaskCompleted hooks"
    dry_run_log "Prompt would be saved at: \$STATE_DIR/prompts/${task_name}_agent-teams.txt"
    dry_run_log "━━━ End simulation ━━━"
    return 0
  fi

  # Verify Agent Teams is enabled
  local at_enabled="${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-0}"
  if [ "$at_enabled" != "1" ]; then
    log_error "Agent Teams is not enabled."
    echo "  Add to .claude/settings.json:"
    echo '  { "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }'
    echo ""
    echo "  Or export: export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
    echo ""
    echo "  Fallback: running as Mode 2 (Semi-auto) instead..."
    orchestrate_semi_auto "$task_json"
    return $?
  fi

  # Resolve team lead — explicit field or first agent as default
  local team_lead=$(echo "$task_json" | jq -r '.team_lead // empty')
  if [ -z "$team_lead" ]; then
    team_lead=$(echo "$task_json" | jq -r '.agents[0].role // "first-agent"')
    log_step "team_lead not defined in task.json — assigning: $team_lead"
  fi

  # Determine if plan approval is needed (high risk or deploy phase)
  local risk=$(task_field "$task_json" "risk")
  local require_plan_approval="false"
  if [ "$risk" = "high" ] || [ "$task_phase" = "deploy" ]; then
    require_plan_approval="true"
  fi

  # Build task list with dependencies from the task definition
  local task_list=""
  local task_deps=$(echo "$task_json" | jq -r '.dependencies // {} | to_entries[] | "\(.key):\(.value | join(","))"' 2>/dev/null)

  # Build the Agent Teams prompt from the task definition
  local team_prompt=""
  team_prompt+="Create an agent team named \"kws-${task_name}\"."
  team_prompt+=$'\n\n'
  team_prompt+="Description: ${task_desc}"
  team_prompt+=$'\n\n'
  team_prompt+="**Phase:** ${task_phase}"
  team_prompt+=$'\n\n'

  # Teammate specifications with model preference
  local model_pref="Sonnet"
  [ "$task_phase" = "spec" ] && model_pref="Opus"

  team_prompt+="Spawn the following teammates with ${model_pref}:"
  team_prompt+=$'\n'

  local idx=1
  local agent_roles=""
  while IFS= read -r agent; do
    local role=$(echo "$agent" | jq -r '.role')
    local profile_name=$(echo "$agent" | jq -r '.profile')
    local profile_content=$(get_agent_profile "$profile_name")
    local scope_line=""
    local lead_marker=""

    # Accumulate roles
    [ -n "$agent_roles" ] && agent_roles+=", "
    agent_roles+="$role"

    # Mark the team lead
    [ "$role" = "$team_lead" ] && lead_marker=" (LEAD)"

    # Get scope from config
    if [ -f "$CONFIG_FILE" ]; then
      local dirs=$(jq -r ".boundaries.${profile_name} // [] | join(\", \")" "$CONFIG_FILE" 2>/dev/null)
      [ -n "$dirs" ] && scope_line="(scope: $dirs)"
    fi

    team_prompt+=$'\n'
    team_prompt+="${idx}. **${role}**${lead_marker} ${scope_line}"
    team_prompt+=$'\n'
    team_prompt+="   Prompt: \"$(echo "$profile_content" | head -5 | tr '\n' ' ')\""

    idx=$((idx + 1))
  done < <(task_agents "$task_json")

  # Plan approval gate
  if [ "$require_plan_approval" = "true" ]; then
    team_prompt+=$'\n\n'
    team_prompt+="**Plan approval required:** Each teammate must plan before implementing."
    team_prompt+="Only approve plans that:"
    team_prompt+=$'\n'
    team_prompt+="- Respect file boundaries for their scope"
    team_prompt+=$'\n'
    team_prompt+="- Include tests or verification"
    team_prompt+=$'\n'
    team_prompt+="- Do not violate project domain rules"
  fi

  # Shared task list with dependencies
  team_prompt+=$'\n\n'
  team_prompt+="**Shared task list:**"
  team_prompt+=$'\n'
  team_prompt+="Create the following tasks for the team:"
  team_prompt+=$'\n'

  local tidx=1
  while IFS= read -r agent; do
    local role=$(echo "$agent" | jq -r '.role')
    local profile_name=$(echo "$agent" | jq -r '.profile')

    # Check if this agent has dependencies
    local deps=""
    if [ -n "$task_deps" ]; then
      deps=$(echo "$task_deps" | grep "^${role}:" | cut -d: -f2)
    fi

    if [ "$task_phase" = "review" ]; then
      team_prompt+="  ${tidx}. Review ${profile_name} — assigned to ${role}"
    else
      team_prompt+="  ${tidx}. Implement scope ${profile_name} — assigned to ${role}"
    fi

    if [ -n "$deps" ]; then
      team_prompt+=" (depends on: ${deps})"
    fi
    team_prompt+=$'\n'

    tidx=$((tidx + 1))
  done < <(task_agents "$task_json")

  # Add consolidation task for team lead
  team_prompt+="  ${tidx}. Consolidate results — assigned to ${team_lead} (depends on: all previous)"
  team_prompt+=$'\n'

  # Inter-agent messaging rules
  team_prompt+=$'\n'
  team_prompt+="**Coordination rules (messaging):**"
  team_prompt+=$'\n'
  team_prompt+="- When an agent finds something affecting another layer, it must message the affected teammate"
  team_prompt+=$'\n'
  team_prompt+="- If an agent modifies a contract (.kit-ws/contracts/), it must broadcast to all"
  team_prompt+=$'\n'
  team_prompt+="- The team lead must wait for everyone to finish before consolidating"
  team_prompt+=$'\n'
  team_prompt+="- Do NOT broadcast unnecessarily — only for changes that affect everyone"
  team_prompt+=$'\n'

  # Report template for reviews
  if [ "$task_phase" = "review" ]; then
    team_prompt+=$'\n'
    team_prompt+="**Report template per reviewer:**"
    team_prompt+=$'\n'
    team_prompt+='```'
    team_prompt+=$'\n'
    team_prompt+="### Critical"
    team_prompt+=$'\n'
    team_prompt+="**[file:line] Title**"
    team_prompt+=$'\n'
    team_prompt+="Description. Suggested fix."
    team_prompt+=$'\n'
    team_prompt+="### Important"
    team_prompt+=$'\n'
    team_prompt+="..."
    team_prompt+=$'\n'
    team_prompt+="### Suggestion"
    team_prompt+=$'\n'
    team_prompt+="..."
    team_prompt+=$'\n'
    team_prompt+='```'
    team_prompt+=$'\n'
    team_prompt+=$'\n'
    team_prompt+="The team lead must de-duplicate findings and produce a consolidated report"
    team_prompt+=" with severity: Critical first, then Important, then Suggestion."
  fi

  # Add project rules from config
  if [ -f "$CONFIG_FILE" ]; then
    local rules=$(jq -r '
      .rules | to_entries[]
      | select(.value == true)
      | "- \(.key)"
    ' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$rules" ]; then
      team_prompt+=$'\n\n'
      team_prompt+="**Project rules:**"
      team_prompt+=$'\n'
      team_prompt+="$rules"
    fi
  fi

  # Save prompt to file
  local prompt_file="$STATE_DIR/prompts/${task_name}_agent-teams.txt"
  mkdir -p "$(dirname "$prompt_file")"
  echo "$team_prompt" > "$prompt_file"

  # Copy to clipboard if possible
  if command -v pbcopy &>/dev/null; then
    echo "$team_prompt" | pbcopy
    log_ok "Prompt copied to clipboard (Cmd+V to paste)"
  elif command -v xclip &>/dev/null; then
    echo "$team_prompt" | xclip -selection clipboard
    log_ok "Prompt copied to clipboard"
  fi

  echo ""
  echo -e "${YELLOW}━━━ Agent Teams (native): kws-${task_name} ━━━${NC}"
  echo ""
  echo "  Team lead:        $team_lead"
  echo "  Teammates:        $agent_roles"
  echo "  Phase:            $task_phase"
  echo "  Plan approval:    $require_plan_approval"
  echo "  Task list:        $((tidx)) tasks with dependencies"
  echo ""
  echo -e "${YELLOW}━━━ Prompt for Agent Teams ━━━${NC}"
  echo "$team_prompt"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  Prompt saved at: $prompt_file"
  echo ""
  echo -e "  ${CYAN}Launching Claude Code with Agent Teams...${NC}"
  echo ""

  # Launch claude with teammate mode
  local teammate_mode="${KWS_TEAMMATE_MODE:-auto}"
  if [ -z "${TMUX:-}" ]; then
    tmux new-session -s "${TMUX_PREFIX}-teams-${task_name}" \
      "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --teammate-mode ${teammate_mode}" \
      2>/dev/null || \
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --teammate-mode "$teammate_mode"
  else
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --teammate-mode "$teammate_mode"
  fi
}
