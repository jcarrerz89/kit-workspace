#!/usr/bin/env bash
# =============================================================================
# drivers/petfi-kit.sh — Driver that delegates to the petfi-kit CLI
# =============================================================================
#
# Translates a kit-workspace job.json repo entry into a petfi-kit task.json,
# runs petfi-kit, then symlinks petfi-kit's state back into kit-workspace state.
#
# Requires petfi-kit CLI to be installed and on PATH.
#
# State mapping:
#   petfi-kit  → {project-dir}/.kit-petfi/state/
#   kit-ws     → {project-dir}/.kit-ws/state/{job-id}/
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# petfi_kit_run — Run a repo's agents via petfi-kit
#
# Arguments:
#   $1: project_dir  — absolute path to the repo
#   $2: job_id       — workspace job ID
#   $3: repo_json    — JSON object for this repo from job.json
#   $4: mode         — 1|2|3|4 (optional, auto-selected if omitted)
#
# Returns 0 on success, 1 on failure
# ---------------------------------------------------------------------------
petfi_kit_run() {
  local project_dir="$1"
  local job_id="$2"
  local repo_json="$3"
  local mode="${4:-}"

  # Validate
  if [ ! -d "$project_dir" ]; then
    log_error "petfi_kit_run: project directory does not exist: $project_dir"
    return 1
  fi

  if ! command -v petfi-kit &>/dev/null; then
    log_error "petfi_kit_run: petfi-kit is not installed or not on PATH"
    return 1
  fi

  local project_name
  project_name=$(basename "$project_dir")

  local state_dir="${project_dir}/.kit-ws/state/${job_id}"
  mkdir -p "$state_dir"

  log_info "petfi_kit_run: starting repo '$project_name' for job '$job_id'"

  # 1. Translate repo_json → petfi-kit task.json
  local task_file="/tmp/kws-task-${job_id}-${project_name}.json"
  _petfi_build_task_json "$repo_json" "$job_id" "$project_name" > "$task_file"

  log_step "Task file: $task_file"
  log_debug "Task JSON: $(cat "$task_file")"

  # 2. Build petfi-kit run flags
  local run_flags=""
  if [ -n "$mode" ]; then
    run_flags="--mode $mode"
  fi

  # 3. Run petfi-kit in the project directory
  checkpoint_init "$state_dir" "$job_id" "$project_name"

  (
    cd "$project_dir"
    PROJECT_DIR="$project_dir" petfi-kit run "$task_file" $run_flags
  ) &

  local pid=$!
  echo "$pid" > "${state_dir}/petfi-kit.pid"

  checkpoint_agent_start "$state_dir" "petfi-kit" "petfi-kit:${pid}" "$pid"

  # 4. Set up symlink: forward petfi-kit state into kit-ws state
  _petfi_link_state "$project_dir" "$job_id" "$project_name" "$state_dir"

  log_ok "petfi_kit_run: petfi-kit launched for '$project_name' (PID=$pid)"
  return 0
}

# ---------------------------------------------------------------------------
# petfi_kit_status — Get status for a repo within a job
#
# Returns JSON: { "project": "...", "status": "...", "agents": [...] }
# ---------------------------------------------------------------------------
petfi_kit_status() {
  local project_dir="$1"
  local job_id="$2"

  local project_name
  project_name=$(basename "$project_dir")

  local state_dir="${project_dir}/.kit-ws/state/${job_id}"
  local petfi_state_dir="${project_dir}/.kit-petfi/state"

  if [ ! -d "$state_dir" ]; then
    echo "{\"project\": \"${project_name}\", \"status\": \"unknown\", \"agents\": []}"
    return 0
  fi

  # If petfi-kit has its own state, merge it into the checkpoint view
  if [ -d "$petfi_state_dir" ]; then
    _petfi_sync_state "$project_dir" "$job_id" "$project_name" "$state_dir" "$petfi_state_dir"
  fi

  checkpoint_status "$state_dir" "$job_id" "$project_name"
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Build petfi-kit task.json from repo_json
_petfi_build_task_json() {
  local repo_json="$1"
  local job_id="$2"
  local project_name="$3"

  local description
  description=$(echo "$repo_json" | jq -r '.description // "No description provided"')

  local iso_ts
  iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Map kit-workspace agent profiles to petfi agent profiles
  # petfi profiles: flutter, firebase, web, generic
  local mapped_agents
  mapped_agents=$(echo "$repo_json" | jq -c '
    .agents // [] | map({
      role:        .role,
      profile:     (
        if   .profile == "frontend" then "flutter"
        elif .profile == "backend"  then "firebase"
        elif .profile == "web"      then "web"
        else .profile               # pass-through (generic, etc.)
        end
      ),
      branch:      .branch,
      description: .description
    })
  ')

  jq -n \
    --arg name        "${job_id}-${project_name}" \
    --arg description "$description" \
    --arg created     "$iso_ts" \
    --argjson agents  "$mapped_agents" \
    '{
      "name":        $name,
      "type":        "feature",
      "scope":       "single_feature",
      "risk":        "medium",
      "description": $description,
      "agents":      $agents,
      "created":     $created
    }'
}

# Symlink petfi-kit state directory into kit-ws state
_petfi_link_state() {
  local project_dir="$1"
  local job_id="$2"
  local project_name="$3"
  local state_dir="$4"

  local petfi_state="${project_dir}/.kit-petfi/state"
  local link_target="${state_dir}/petfi-state"

  # Create symlink once petfi-kit initialises its state directory
  # (we try a few times since petfi-kit may not have written it yet)
  local attempts=0
  while [ ! -d "$petfi_state" ] && [ "$attempts" -lt 5 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done

  if [ -d "$petfi_state" ] && [ ! -L "$link_target" ]; then
    ln -sf "$petfi_state" "$link_target"
    log_step "Linked petfi-kit state: $link_target → $petfi_state"
  fi
}

# Read petfi-kit state and update kit-ws checkpoint
_petfi_sync_state() {
  local project_dir="$1"
  local job_id="$2"
  local project_name="$3"
  local state_dir="$4"
  local petfi_state_dir="$5"

  # Check petfi-kit PID
  local pid_file="${state_dir}/petfi-kit.pid"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    if ! kill -0 "$pid" 2>/dev/null; then
      # Process finished — check exit code
      local exit_file="${state_dir}/petfi-kit.exit"
      local exit_code=0
      [ -f "$exit_file" ] && exit_code=$(cat "$exit_file")

      if [ "$exit_code" = "0" ]; then
        checkpoint_agent_complete "$state_dir" "petfi-kit"
      else
        checkpoint_fail "$state_dir" "petfi-kit" "exit code $exit_code"
      fi
    fi
  fi
}
