#!/usr/bin/env bash
# =============================================================================
# drivers/generic.sh — Generic driver for any git repo (no kit required)
# =============================================================================
#
# Works in ANY git repository without any kit installed. Each agent gets its
# own worktree and runs `claude -p <prompt>` in it.
#
# Modes:
#   1 — Supervised  (tmux, user watches)
#   2 — Semi-auto   (tmux, auto-accept)
#   3 — Fire & Forget (headless claude -p)
#   4 — Agent Teams (headless, parallel)
#
# State is tracked in: {project-dir}/.kit-ws/state/{job-id}/
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# generic_run — Run all agents for a single repo
#
# Arguments:
#   $1: project_dir  — absolute path to the repo
#   $2: job_id       — workspace job ID
#   $3: repo_json    — JSON object for this repo (agents array, depends_on, etc.)
#   $4: mode         — 1|2|3|4 (optional, auto-selected if omitted)
#
# Returns 0 on success, 1 on failure
# ---------------------------------------------------------------------------
generic_run() {
  local project_dir="$1"
  local job_id="$2"
  local repo_json="$3"
  local mode="${4:-}"

  # Validate project_dir
  if [ ! -d "$project_dir" ]; then
    log_error "generic_run: project directory does not exist: $project_dir"
    return 1
  fi

  # Validate it's a git repo
  if ! git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
    log_error "generic_run: not a git repository: $project_dir"
    return 1
  fi

  local project_name
  project_name=$(basename "$project_dir")

  local state_dir="${project_dir}/.kit-ws/state/${job_id}"
  mkdir -p "$state_dir"

  log_info "generic_run: starting repo '$project_name' for job '$job_id'"

  # Auto-select mode if not provided
  if [ -z "$mode" ]; then
    local agent_count
    agent_count=$(echo "$repo_json" | jq '.agents | length')
    if [ "$agent_count" -gt 1 ]; then
      mode=4
    else
      mode=3
    fi
    log_debug "generic_run: auto-selected mode $mode"
  fi

  # Initialize checkpoint for this repo
  # checkpoint_init sets CHECKPOINT_DIR = $project_dir/.kit-ws/state
  # We then override it to point at the job-scoped state_dir
  checkpoint_init "$project_dir"
  CHECKPOINT_DIR="$state_dir"
  mkdir -p "$CHECKPOINT_DIR"

  # Process each agent
  local agent_idx=0
  while IFS= read -r agent_json; do
    local role branch profile description
    role=$(echo "$agent_json" | jq -r '.role // "developer"')
    branch=$(echo "$agent_json" | jq -r '.branch // "main"')
    profile=$(echo "$agent_json" | jq -r '.profile // "generic"')
    description=$(echo "$agent_json" | jq -r '.description // ""')

    log_step "Agent [$role] branch=$branch profile=$profile"

    # 1. Create worktree for this agent
    export PROJECT_DIR="$project_dir"
    worktree_create "$branch" || {
      log_error "generic_run: failed to create worktree for branch $branch"
      checkpoint_agent_failed "$job_id" "$role" "worktree creation failed"
      continue
    }
    local worktree_path
    worktree_path=$(worktree_path "$branch")

    # 2. Build the agent prompt
    local prompt
    prompt=$(_generic_build_prompt "$repo_json" "$agent_json" "$project_dir" "$job_id")

    # 3. Launch claude based on mode
    case "$mode" in
      1|2)
        _generic_launch_tmux "$worktree_path" "$prompt" "$job_id" "$role" "$mode" "$state_dir"
        ;;
      3|4)
        _generic_launch_headless "$worktree_path" "$prompt" "$job_id" "$role" "$state_dir"
        ;;
      *)
        log_error "generic_run: unknown mode $mode"
        return 1
        ;;
    esac

    agent_idx=$((agent_idx + 1))
  done < <(echo "$repo_json" | jq -c '.agents[]?')

  log_ok "generic_run: all agents launched for '$project_name'"
  return 0
}

# ---------------------------------------------------------------------------
# generic_status — Get status for a repo within a job
#
# Returns JSON: { "project": "...", "status": "...", "agents": [...] }
# ---------------------------------------------------------------------------
generic_status() {
  local project_dir="$1"
  local job_id="$2"

  local project_name
  project_name=$(basename "$project_dir")

  local state_dir="${project_dir}/.kit-ws/state/${job_id}"

  if [ ! -d "$state_dir" ]; then
    echo "{\"project\": \"${project_name}\", \"status\": \"unknown\", \"agents\": []}"
    return 0
  fi

  # Return basic status JSON from state_dir
  local status="unknown"
  [ -f "${state_dir}/current.json" ] && status=$(jq -r '.status // "unknown"' "${state_dir}/current.json" 2>/dev/null || echo "unknown")
  echo "{\"project\": \"${project_name}\", \"status\": \"${status}\", \"agents\": []}"
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Discover available Claude sub-agents for a project directory.
# Checks project/.claude/agents/ and parent/.claude/agents/ (for nested repos).
# Returns formatted text listing @agent-name: description, one per line.
_generic_discover_agents() {
  local project_dir="$1"
  local result=""

  local parent_dir
  parent_dir="$(dirname "$project_dir")"

  local agent_dirs=()
  [ -d "${project_dir}/.claude/agents" ] && agent_dirs+=("${project_dir}/.claude/agents")
  [ -d "${parent_dir}/.claude/agents"  ] && agent_dirs+=("${parent_dir}/.claude/agents")

  for agent_dir in "${agent_dirs[@]}"; do
    for f in "$agent_dir"/*.md; do
      [ -f "$f" ] || continue
      local agent_name
      agent_name=$(basename "$f" .md)
      # Prefer frontmatter description:, else first non-blank non-header line
      local desc
      desc=$(grep -m1 '^description:' "$f" 2>/dev/null | sed 's/^description:[[:space:]]*//')
      if [ -z "$desc" ]; then
        desc=$(grep -m1 '^[^#[:space:]-]' "$f" 2>/dev/null | cut -c1-100 || true)
      fi
      result+="  - @${agent_name}${desc:+: ${desc}}\n"
    done
  done

  printf '%b' "$result"
}

# Build prompt string for an agent
_generic_build_prompt() {
  local repo_json="$1"
  local agent_json="$2"
  local project_dir="$3"
  local job_id="$4"

  local profile role description branch
  profile=$(echo "$agent_json"  | jq -r '.profile     // "generic"')
  role=$(echo "$agent_json"     | jq -r '.role        // "developer"')
  description=$(echo "$agent_json" | jq -r '.description // ""')
  branch=$(echo "$agent_json"   | jq -r '.branch      // "main"')

  # Collect any file boundaries defined in agent JSON
  local boundaries=""
  local raw_boundaries
  raw_boundaries=$(echo "$agent_json" | jq -r '.boundaries // [] | .[]' 2>/dev/null || true)
  if [ -n "$raw_boundaries" ]; then
    boundaries="File scope (stay within these paths only):
${raw_boundaries}"
  fi

  # Collect acceptance criteria if present
  local criteria=""
  local raw_criteria
  raw_criteria=$(echo "$agent_json" | jq -r '.acceptance_criteria // [] | .[]' 2>/dev/null || true)
  if [ -n "$raw_criteria" ]; then
    criteria="Acceptance criteria (all must be met before you are done):
${raw_criteria}"
  fi

  # Discover sub-agents available in this project
  local agents_section=""
  local discovered
  discovered=$(_generic_discover_agents "$project_dir")
  if [ -n "$discovered" ]; then
    agents_section="Available sub-agents — delegate to them by calling @agent-name in your prompt:
${discovered}
Use these for specialised work: e.g. @product-owner for requirements, @ux for UI decisions,
@webapp for frontend implementation, @devops for infrastructure changes."
  fi

  # Build prompt
  cat << EOF
You are a ${profile} agent working in the kit-workspace multi-agent system.

Your role: ${role}
Your branch: ${branch}
Job ID: ${job_id}

Task description:
${description}

${boundaries:+${boundaries}

}${criteria:+${criteria}

}${agents_section:+${agents_section}

}Instructions:
1. Read the project CLAUDE.md (if present) for project-specific context and constraints.
2. Use the sub-agents listed above where their expertise applies — delegate, don't do everything alone.
3. Analyse the current state of the code within your scope.
4. Execute the task described above.
5. Make descriptive commits with the prefix [${role}].
6. Do NOT touch files or branches outside your scope.
7. When done, output a brief summary of what was changed and which sub-agents were used.
EOF
}

# Launch claude in a tmux session (Mode 1/2)
_generic_launch_tmux() {
  local worktree_path="$1"
  local prompt="$2"
  local job_id="$3"
  local role="$4"
  local mode="$5"
  local state_dir="$6"

  local session_name="kws-${job_id}-${role}"

  # Build claude flags based on mode
  local claude_flags=""
  if [ "$mode" = "2" ]; then
    claude_flags="--dangerously-skip-permissions"
  fi

  local log_file="${state_dir}/${role}.log"

  # Create tmux session running claude in the worktree
  tmux new-session -d -s "$session_name" \
    -c "$worktree_path" \
    "claude -p $(printf '%q' "$prompt") $claude_flags 2>&1 | tee $(printf '%q' "$log_file"); echo \$? > $(printf '%q' "${state_dir}/${role}.exit")" \
    2>/dev/null || {
      log_warn "tmux session '$session_name' may already exist; attaching"
    }

  checkpoint_agent_started "$job_id" "$role"
  log_step "Launched tmux session: $session_name (Mode $mode)"
}

# Launch claude headlessly in background (Mode 3/4)
_generic_launch_headless() {
  local worktree_path="$1"
  local prompt="$2"
  local job_id="$3"
  local role="$4"
  local state_dir="$5"

  local log_file="${state_dir}/${role}.log"
  local pid_file="${state_dir}/${role}.pid"
  local exit_file="${state_dir}/${role}.exit"

  # Run claude in background, capturing PID
  (
    cd "$worktree_path"
    claude -p "$prompt" --dangerously-skip-permissions >"$log_file" 2>&1
    echo $? >"$exit_file"
  ) &

  local pid=$!
  echo "$pid" >"$pid_file"

  checkpoint_agent_started "$job_id" "$role"
  log_step "Launched headless agent [$role] PID=$pid → $log_file"
}
