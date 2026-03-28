#!/usr/bin/env bash
# =============================================================================
# refine.sh — Pre-run refinement phase using a planner agent
# =============================================================================
#
# Invokes a product-owner, planner, or architect sub-agent in the project
# directory to expand a rough job spec into a detailed, per-agent breakdown
# before any implementation agents run.
#
# Usage:
#   refine_job <job_json_path> [output_path]
#
# If no planner agent is found, copies the original job spec unchanged.
# =============================================================================

# ---------------------------------------------------------------------------
# _refine_find_planner — Locate a planner agent .md file for a project dir
# Checks: project/.claude/agents/, parent/.claude/agents/
# Returns: agent name (no extension) or empty string
# ---------------------------------------------------------------------------
_refine_find_planner() {
  local project_dir="$1"
  local parent_dir
  parent_dir="$(dirname "$project_dir")"

  for candidate in product-owner planner architect; do
    if [ -f "${project_dir}/.claude/agents/${candidate}.md" ]; then
      echo "$candidate"
      return 0
    fi
    if [ -f "${parent_dir}/.claude/agents/${candidate}.md" ]; then
      echo "$candidate"
      return 0
    fi
  done

  echo ""
}

# ---------------------------------------------------------------------------
# _refine_extract_json — Try to pull valid JSON out of raw agent output
# Tries: (1) whole output is JSON, (2) ```json code fence, (3) first {...} block
# ---------------------------------------------------------------------------
_refine_extract_json() {
  local raw="$1"

  # Try 1: whole output is valid JSON
  if echo "$raw" | jq -e '.' >/dev/null 2>&1; then
    echo "$raw" | jq '.'
    return 0
  fi

  # Try 2: extract from ```json ... ``` fence
  local fenced
  fenced=$(echo "$raw" | sed -n '/^```json/,/^```/p' | grep -v '^```' | head -200)
  if [ -n "$fenced" ] && echo "$fenced" | jq -e '.' >/dev/null 2>&1; then
    echo "$fenced" | jq '.'
    return 0
  fi

  # Try 3: extract from ``` ... ``` fence (language-agnostic)
  fenced=$(echo "$raw" | sed -n '/^```$/,/^```$/p' | grep -v '^```' | head -200)
  if [ -n "$fenced" ] && echo "$fenced" | jq -e '.' >/dev/null 2>&1; then
    echo "$fenced" | jq '.'
    return 0
  fi

  # Try 4: find first { ... } block spanning multiple lines
  local extracted
  extracted=$(echo "$raw" | awk '/^\{/{p=1} p{print} /^\}/{if(p){p=0; exit}}')
  if [ -n "$extracted" ] && echo "$extracted" | jq -e '.' >/dev/null 2>&1; then
    echo "$extracted" | jq '.'
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# refine_job — Run a planner agent to expand a rough job spec
#
# Arguments:
#   $1: job_path  — path to original job.json
#   $2: out_path  — where to write refined spec (default: job-refined.json)
#
# Returns 0 on success (even if refinement was skipped), 1 on hard failure
# ---------------------------------------------------------------------------
refine_job() {
  local job_path="$1"
  local out_path="${2:-${job_path%.json}-refined.json}"

  if [ ! -f "$job_path" ]; then
    log_error "refine_job: job file not found: $job_path"
    return 1
  fi

  local job_json
  job_json=$(cat "$job_path")

  # Resolve first project's directory — run the agent in that context
  local first_project
  first_project=$(echo "$job_json" | jq -r '.repos[0].project // empty')
  if [ -z "$first_project" ]; then
    log_warn "refine_job: no repos in job — copying as-is"
    cp "$job_path" "$out_path"
    return 0
  fi

  local project_dir
  project_dir=$(workspace_resolve_path "$first_project")
  if [ -z "$project_dir" ] || [ ! -d "$project_dir" ]; then
    log_error "refine_job: cannot resolve path for project '$first_project'"
    return 1
  fi

  # Find a planner agent
  local planner_agent
  planner_agent=$(_refine_find_planner "$project_dir")

  if [ -z "$planner_agent" ]; then
    log_warn "refine_job: no planner agent found (checked: product-owner, planner, architect) — running original spec unchanged"
    cp "$job_path" "$out_path"
    return 0
  fi

  log_info "refine_job: using @${planner_agent} to elaborate job spec…"

  # Build the refinement prompt
  local refine_prompt
  refine_prompt=$(cat << EOF
Use the @${planner_agent} agent to review and expand the feature spec below.

Current job spec (JSON):
$(echo "$job_json" | jq .)

Instructions for @${planner_agent}:
1. Review the feature name, description, and list of agents.
2. For EACH agent in repos[].agents[], expand the fields:
   - "description": make it detailed and actionable (what to build, which files, how)
   - "boundaries": add an array of file/directory paths the agent should stay within
   - "acceptance_criteria": add an array of concrete, testable conditions
3. Keep the overall JSON structure identical — only enrich the agent objects.
4. Output ONLY the updated JSON with no prose before or after.
EOF
)

  # Run claude in the project directory (no worktree — this is planning only)
  log_step "  Running @${planner_agent} in $project_dir …"
  local refined_raw
  refined_raw=$(
    cd "$project_dir"
    claude -p "$refine_prompt" --dangerously-skip-permissions 2>&1
  )
  local claude_exit=$?

  if [ $claude_exit -ne 0 ]; then
    log_warn "refine_job: claude exited $claude_exit — using original spec"
    cp "$job_path" "$out_path"
    return 0
  fi

  # Extract JSON from agent output
  local refined_json
  if refined_json=$(_refine_extract_json "$refined_raw"); then
    echo "$refined_json" > "$out_path"
    log_ok "Refined spec saved: $out_path"
  else
    log_warn "refine_job: could not parse agent output as JSON"
    echo "$refined_raw" > "${out_path%.json}.raw.txt"
    log_warn "  Raw output saved to: ${out_path%.json}.raw.txt"
    log_warn "  Falling back to original spec"
    cp "$job_path" "$out_path"
  fi

  return 0
}
