#!/usr/bin/env bash
# meta-orchestrator.sh — multi-repo job dispatch

# ---------------------------------------------------------------------------
# meta_session_id — Generate a workspace-level session/job ID
# Format: {YYYYMMDD-HHMMSS}-{4-hex}
# ---------------------------------------------------------------------------
meta_session_id() {
  local rand
  rand=$(head -c 2 /dev/urandom | od -An -tx1 | tr -d ' \n')
  echo "$(date +%Y%m%d-%H%M%S)-${rand}"
}

# ---------------------------------------------------------------------------
# meta_run_job — Main entry point: run a job across all repos
# Usage: meta_run_job "/path/to/job.json"
# Reads workspace config, dispatches each repo to its driver,
# runs repos in parallel (respecting depends_on), waits for all
# ---------------------------------------------------------------------------
meta_run_job() {
  local job_json_path="$1"

  if [ ! -f "$job_json_path" ]; then
    log_error "meta_run_job: job.json not found: $job_json_path"
    return 1
  fi

  if ! jq empty "$job_json_path" 2>/dev/null; then
    log_error "meta_run_job: invalid JSON: $job_json_path"
    return 1
  fi

  local job_json
  job_json=$(cat "$job_json_path")

  local job_id job_name
  job_id=$(echo "$job_json" | jq -r '.id // empty')
  [ -z "$job_id" ] && job_id=$(meta_session_id)
  job_name=$(echo "$job_json" | jq -r '.name // "unnamed"')

  log_info "meta_run_job: job=$job_id ($job_name)"

  # Create workspace-level job state directory
  local job_state_dir="${HOME}/.kit-workspace/state/${job_id}"
  mkdir -p "$job_state_dir"

  # Write initial state files
  echo "$job_json" > "${job_state_dir}/job.json"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${job_state_dir}/started_at"
  echo "running" > "${job_state_dir}/status"

  # Open workspace log
  local ws_log="${job_state_dir}/${job_id}.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) meta_run_job: job=$job_id name=$job_name" >> "$ws_log"

  # Build execution plan: array of waves respecting depends_on
  local plan
  plan=$(_meta_build_execution_plan "$job_json")

  local wave_count
  wave_count=$(echo "$plan" | jq 'length')
  local wave_idx=0

  while [ "$wave_idx" -lt "$wave_count" ]; do
    local wave_projects
    wave_projects=$(echo "$plan" | jq -r ".[$wave_idx][]")

    log_info "meta_run_job: wave $((wave_idx + 1))/$wave_count — repos: $(echo "$wave_projects" | tr '\n' ' ')"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) wave $((wave_idx + 1))/$wave_count start" >> "$ws_log"

    # Launch all repos in this wave in parallel; save PIDs
    local pids_file="${job_state_dir}/wave_${wave_idx}_pids"
    > "$pids_file"

    while IFS= read -r project_name; do
      [ -z "$project_name" ] && continue

      # Build per-repo task.json and create symlink into state dir
      local repo_json
      repo_json=$(echo "$job_json" | jq -c --arg p "$project_name" '.repos[] | select(.project == $p)')

      meta_build_repo_task "$job_json" "$project_name"

      local project_dir
      project_dir=$(workspace_resolve_path "$project_name" 2>/dev/null || echo "")

      # Create symlink for repo state directory
      if [ -n "$project_dir" ]; then
        local repo_state_link="${job_state_dir}/${project_name}"
        if [ ! -e "$repo_state_link" ]; then
          ln -sf "${project_dir}/.kit-ws/state/${job_id}" "$repo_state_link" 2>/dev/null || true
        fi
      fi

      _meta_run_repo "$project_name" "$job_id" "$repo_json" >> "$ws_log" 2>&1 &
      local pid=$!
      echo "$pid|$project_name" >> "$pids_file"
      log_step "  $project_name → PID $pid"
    done <<< "$wave_projects"

    # Wait for wave to complete
    meta_wait_all "$job_id" "$pids_file"
    local wave_rc=$?

    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) wave $((wave_idx + 1))/$wave_count done (rc=$wave_rc)" >> "$ws_log"

    if [ "$wave_rc" -ne 0 ]; then
      log_error "meta_run_job: wave $((wave_idx + 1)) had failures — aborting"
      echo "failed" > "${job_state_dir}/status"
      type notify_agent_failure &>/dev/null && \
        notify_agent_failure "meta-wave-$((wave_idx + 1))" "1" "" "$job_id"
      return 1
    fi

    wave_idx=$((wave_idx + 1))
  done

  echo "completed" > "${job_state_dir}/status"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${job_state_dir}/completed_at"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) meta_run_job: completed" >> "$ws_log"

  log_ok "meta_run_job: job '$job_id' completed"
  type notify_swarm_complete &>/dev/null && \
    notify_swarm_complete "$job_name" \
      "$(echo "$job_json" | jq '[.repos[].agents[]] | length')" \
      "0" "$job_id"
}

# ---------------------------------------------------------------------------
# meta_job_status — Get aggregated status for a running job
# Reads .kit-ws/state/ in each repo
# Outputs JSON: { "job_id": "...", "repos": [{ "project": "...", "status": "...", "agents": [...] }] }
# ---------------------------------------------------------------------------
meta_job_status() {
  local job_id="$1"
  local job_state_dir="${HOME}/.kit-workspace/state/${job_id}"

  if [ ! -d "$job_state_dir" ]; then
    log_error "meta_job_status: job not found: $job_id"
    return 1
  fi

  local overall_status
  overall_status=$(cat "${job_state_dir}/status" 2>/dev/null || echo "unknown")

  # Build repo status array
  local repos_json="[]"
  if [ -f "${job_state_dir}/job.json" ]; then
    while IFS= read -r project_name; do
      local project_dir
      project_dir=$(workspace_resolve_path "$project_name" 2>/dev/null || echo "")

      local repo_status="unknown"
      local agents_json="[]"

      if [ -n "$project_dir" ]; then
        local repo_state="${project_dir}/.kit-ws/state/${job_id}"

        if [ -f "${repo_state}/current.json" ]; then
          repo_status=$(jq -r '.status // "unknown"' "${repo_state}/current.json" 2>/dev/null || echo "unknown")
          agents_json=$(jq -c '.agents // []' "${repo_state}/current.json" 2>/dev/null || echo "[]")
        fi
      fi

      repos_json=$(echo "$repos_json" | jq \
        --arg project "$project_name" \
        --arg status "$repo_status" \
        --argjson agents "$agents_json" \
        '. + [{"project": $project, "status": $status, "agents": $agents}]')

    done < <(jq -r '.repos[].project' "${job_state_dir}/job.json" 2>/dev/null)
  fi

  jq -n \
    --arg job_id "$job_id" \
    --arg status "$overall_status" \
    --argjson repos "$repos_json" \
    '{"job_id": $job_id, "status": $status, "repos": $repos}'
}

# ---------------------------------------------------------------------------
# meta_wait_all — Wait for all repo subshells to finish, collect results
# Calls notify.sh on failures/stalls
# ---------------------------------------------------------------------------
meta_wait_all() {
  local job_id="$1"
  local pids_file="$2"

  if [ ! -f "$pids_file" ]; then
    return 0
  fi

  local any_failed=0

  while IFS='|' read -r pid project_name; do
    [ -z "$pid" ] && continue
    if ! wait "$pid" 2>/dev/null; then
      log_warn "meta_wait_all: $project_name (PID $pid) failed"
      any_failed=1
      type notify_agent_failure &>/dev/null && \
        notify_agent_failure "$project_name" "1" "" "$job_id"
    else
      log_step "meta_wait_all: $project_name (PID $pid) done"
    fi
  done < "$pids_file"

  return $any_failed
}

# ---------------------------------------------------------------------------
# meta_dashboard — Render the unified dashboard to stdout
# Shows all active jobs from ~/.kit-workspace/state/
# ---------------------------------------------------------------------------
meta_dashboard() {
  local state_dir="${HOME}/.kit-workspace/state"

  if [ ! -d "$state_dir" ] || [ -z "$(ls -A "$state_dir" 2>/dev/null)" ]; then
    log_info "No jobs found. Run: kit-workspace run <job.json>"
    return 0
  fi

  echo ""
  echo "kit-workspace — Job Dashboard"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "%-28s %-12s %-22s %-6s\n" "JOB ID" "STATUS" "STARTED" "REPOS"
  echo "────────────────────────────────────────────────────────────"

  for job_dir in "${state_dir}"/*/; do
    [ -d "$job_dir" ] || continue
    local jid status started repo_count
    jid=$(basename "$job_dir")
    status=$(cat "${job_dir}/status" 2>/dev/null || echo "unknown")
    started=$(cat "${job_dir}/started_at" 2>/dev/null | cut -c1-19 || echo "—")
    repo_count="—"

    if [ -f "${job_dir}/job.json" ]; then
      repo_count=$(jq '.repos | length' "${job_dir}/job.json" 2>/dev/null || echo "?")
    fi

    printf "%-28s %-12s %-22s %-6s\n" "$jid" "$status" "$started" "$repo_count"
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ---------------------------------------------------------------------------
# meta_build_repo_task — Translate job.json repo+agents section into per-repo task.json
# Used by petfi-kit driver; saved to /tmp/kws-task-{job_id}-{project}.json
# ---------------------------------------------------------------------------
meta_build_repo_task() {
  local job_json="$1"
  local project_name="$2"

  # Accept job_json as a file path or an inline JSON string
  local job_data
  if [ -f "$job_json" ]; then
    job_data=$(cat "$job_json")
  else
    job_data="$job_json"
  fi

  local job_id job_name job_desc
  job_id=$(echo "$job_data" | jq -r '.id // "job-unknown"')
  job_name=$(echo "$job_data" | jq -r '.name // "unnamed"')
  job_desc=$(echo "$job_data" | jq -r '.description // ""')

  local repo_entry
  repo_entry=$(echo "$job_data" | jq -c --arg p "$project_name" \
    '.repos[] | select(.project == $p)')

  if [ -z "$repo_entry" ]; then
    log_error "meta_build_repo_task: project '$project_name' not found in job.json"
    return 1
  fi

  local task_file="/tmp/kws-task-${job_id}-${project_name}.json"

  jq -n \
    --arg job_id "$job_id" \
    --arg name "$job_name" \
    --arg description "$job_desc" \
    --arg project "$project_name" \
    --argjson repo "$repo_entry" \
    '{
      id: $job_id,
      name: $name,
      description: $description,
      project: $project,
      agents: $repo.agents,
      depends_on: ($repo.depends_on // [])
    }' > "$task_file"

  echo "$task_file"
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Dispatch a single repo to the correct driver
_meta_run_repo() {
  local project_name="$1"
  local job_id="$2"
  local repo_json="$3"

  local project_dir driver
  project_dir=$(workspace_resolve_path "$project_name" 2>/dev/null) || {
    log_error "_meta_run_repo: cannot resolve path for '$project_name'"
    return 1
  }
  driver=$(workspace_get_driver "$project_name" 2>/dev/null || echo "generic")

  log_step "_meta_run_repo: $project_name → driver=$driver path=$project_dir"

  # Ensure per-repo state directory exists
  mkdir -p "${project_dir}/.kit-ws/state/${job_id}"

  local driver_file="${KWS_DIR}/drivers/${driver}.sh"
  if [ ! -f "$driver_file" ]; then
    log_error "_meta_run_repo: driver not found: $driver_file"
    return 1
  fi

  # shellcheck source=/dev/null
  source "$driver_file"

  case "$driver" in
    generic)
      generic_run "$project_dir" "$job_id" "$repo_json"
      ;;
    petfi-kit)
      petfi_kit_run "$project_dir" "$job_id" "$repo_json"
      ;;
    *)
      log_error "_meta_run_repo: unknown driver: $driver"
      return 1
      ;;
  esac
}

# Build an execution plan: array of waves, each wave is an array of project names.
# Repos with no depends_on go in wave 0; others wait for their deps (topological sort).
_meta_build_execution_plan() {
  local job_json="$1"

  echo "$job_json" | jq '
    .repos as $repos |
    ($repos | map({
      name: .project,
      deps: (.depends_on // [])
    })) as $nodes |

    # Assign wave levels via iterative relaxation
    reduce range(50) as $_ (
      { assigned: {} };
      . as $state |
      reduce $nodes[] as $n (
        $state;
        if (.assigned[$n.name] | not) and
           ($n.deps | all(. as $dep | $state.assigned[$dep] != null)) then
          ($n.deps | if length == 0 then 0
            else map($state.assigned[.]) | max + 1
            end) as $level |
          .assigned[$n.name] = $level
        else . end
      )
    ) |
    .assigned as $levels |
    ($levels | to_entries | map(.value) | unique | sort) as $unique_levels |
    [
      $unique_levels[] |
      . as $lv |
      [$levels | to_entries[] | select(.value == $lv) | .key]
    ]
  '
}
