#!/usr/bin/env bash
# =============================================================================
# session.sh — User-facing session model
# =============================================================================
#
# A session is a unit of work against an app or project.
# The user provides: target (app or project), name, description.
# kit-workspace handles branches, agents, and driver setup automatically.
#
# After a session ends, its type is inferred from commit messages:
#   feat:/feature:  → feature
#   fix:/bugfix:    → fix
#   refactor:       → refactor
#   docs:/chore:    → chore
#   (no commits)    → research
# =============================================================================

KWS_SESSIONS_DIR="${HOME}/.kit-workspace/sessions"

# ---------------------------------------------------------------------------
# session_create — Build a session.json and the internal job.json
#
# Usage: session_create <target> <name> <description>
#   target: app name (from .apps) or project name (from .projects)
#   name:   slug used for branch and file naming
#   description: what this session is about
#
# Returns: path to the generated job.json (ready to pass to meta_run_job)
# ---------------------------------------------------------------------------
session_create() {
  local target="$1"
  local name="$2"
  local description="$3"

  name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

  if [ -z "$target" ] || [ -z "$name" ] || [ -z "$description" ]; then
    log_error "session_create: target, name, and description are required"
    return 1
  fi

  workspace_load || return 1

  # Resolve target to a list of projects
  local projects=()

  # Check if target is an app group
  local app_projects
  app_projects=$(workspace_get_app_projects "$target" 2>/dev/null || true)
  if [ -n "$app_projects" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && projects+=("$p")
    done <<< "$app_projects"
  fi

  # Fall back to single project
  if [ ${#projects[@]} -eq 0 ]; then
    local resolved
    resolved=$(workspace_resolve_path "$target" 2>/dev/null || true)
    if [ -n "$resolved" ]; then
      projects+=("$target")
    else
      log_error "session_create: '$target' is not a registered app or project"
      return 1
    fi
  fi

  local session_id
  session_id="ses-$(date +%Y%m%d-%H%M%S)"

  # Build session.json (user-facing record)
  mkdir -p "$KWS_SESSIONS_DIR"
  local session_path="${KWS_SESSIONS_DIR}/${name}.json"

  local projects_json
  projects_json=$(printf '%s\n' "${projects[@]}" | jq -R . | jq -s .)

  jq -n \
    --arg id          "$session_id" \
    --arg name        "$name" \
    --arg description "$description" \
    --arg target      "$target" \
    --argjson projects "$projects_json" \
    --arg created     "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
      id:          $id,
      name:        $name,
      description: $description,
      target:      $target,
      projects:    $projects,
      created_at:  $created
    }' > "$session_path"

  log_step "Session saved: $session_path"

  # Convert to job.json for the engine
  local job_path
  job_path=$(session_to_job "$session_path")
  echo "$job_path"
}

# ---------------------------------------------------------------------------
# session_to_job — Convert a session.json to an internal job.json
#
# Auto-selects role and profile from each project's driver:
#   petfi-kit → role=frontend, profile=flutter
#   generic   → role=developer, profile=generic
# Branch name: session/{name}
# ---------------------------------------------------------------------------
session_to_job() {
  local session_path="$1"

  if [ ! -f "$session_path" ]; then
    log_error "session_to_job: file not found: $session_path"
    return 1
  fi

  local session_json
  session_json=$(cat "$session_path")

  local session_id name description
  session_id=$(echo "$session_json"  | jq -r '.id')
  name=$(echo "$session_json"        | jq -r '.name')
  description=$(echo "$session_json" | jq -r '.description')

  local repos_json="[]"

  while IFS= read -r project_name; do
    [ -z "$project_name" ] && continue

    local driver role profile
    driver=$(workspace_get_driver "$project_name" 2>/dev/null || echo "generic")

    case "$driver" in
      petfi-kit)
        role="frontend"
        profile="flutter"
        ;;
      *)
        role="developer"
        profile="generic"
        ;;
    esac

    repos_json=$(echo "$repos_json" | jq \
      --arg project     "$project_name" \
      --arg role        "$role" \
      --arg branch      "session/${name}" \
      --arg profile     "$profile" \
      --arg description "$description" \
      '. + [{
        "project": $project,
        "agents": [{
          "role":        $role,
          "branch":      $branch,
          "profile":     $profile,
          "description": $description
        }]
      }]')

  done < <(echo "$session_json" | jq -r '.projects[]')

  # Write job.json to a temp location the engine can pick up
  local job_path="/tmp/kws-job-${session_id}.json"

  jq -n \
    --arg id          "$session_id" \
    --arg name        "$name" \
    --arg description "$description" \
    --argjson repos   "$repos_json" \
    '{
      id:          $id,
      name:        $name,
      description: $description,
      repos:       $repos
    }' > "$job_path"

  echo "$job_path"
}

# ---------------------------------------------------------------------------
# session_infer_type — Infer session type from commit messages on the branch
#
# Usage: session_infer_type <job_id>
# Returns one of: feature / fix / refactor / chore / research
# ---------------------------------------------------------------------------
session_infer_type() {
  local job_id="$1"
  local job_state_dir="${HOME}/.kit-workspace/state/${job_id}"

  if [ ! -f "${job_state_dir}/job.json" ]; then
    echo "research"
    return 0
  fi

  local job_json
  job_json=$(cat "${job_state_dir}/job.json")

  local counts_feat=0 counts_fix=0 counts_refactor=0 counts_chore=0 total=0

  while IFS= read -r project_name; do
    [ -z "$project_name" ] && continue

    local project_dir branch
    project_dir=$(workspace_resolve_path "$project_name" 2>/dev/null || echo "")
    branch=$(echo "$job_json" | jq -r \
      --arg p "$project_name" \
      '.repos[] | select(.project == $p) | .agents[0].branch // empty' 2>/dev/null || true)

    [ -z "$project_dir" ] || [ -z "$branch" ] && continue
    [ ! -d "$project_dir/.git" ] && continue

    # List commits on this branch not on main
    local commits
    commits=$(git -C "$project_dir" log "main..${branch}" --oneline 2>/dev/null || true)
    [ -z "$commits" ] && continue

    while IFS= read -r line; do
      [ -z "$line" ] && continue
      total=$((total + 1))
      case "${line,,}" in
        *"feat("*|*"feat:"*|*"feature("*|*"feature:"*) counts_feat=$((counts_feat + 1)) ;;
        *"fix("*|*"fix:"*|*"bugfix("*|*"bugfix:"*|*"hotfix("*|*"hotfix:"*) counts_fix=$((counts_fix + 1)) ;;
        *"refactor("*|*"refactor:"*) counts_refactor=$((counts_refactor + 1)) ;;
        *"docs("*|*"docs:"*|*"chore("*|*"chore:"*|*"test("*|*"test:"*) counts_chore=$((counts_chore + 1)) ;;
      esac
    done <<< "$commits"

  done < <(echo "$job_json" | jq -r '.repos[].project')

  if [ "$total" -eq 0 ]; then
    echo "research"
    return 0
  fi

  # Pick whichever type has the most commits; feat wins ties
  local winner="chore"
  local max=$counts_chore

  [ $counts_refactor -gt $max ] && winner="refactor" && max=$counts_refactor
  [ $counts_fix      -gt $max ] && winner="fix"      && max=$counts_fix
  [ $counts_feat     -ge $max ] && winner="feature"

  echo "$winner"
}

# ---------------------------------------------------------------------------
# session_list — Print all sessions with id, name, status, type
# ---------------------------------------------------------------------------
session_list() {
  local state_dir="${HOME}/.kit-workspace/state"

  if [ ! -d "$state_dir" ] || [ -z "$(ls -A "$state_dir" 2>/dev/null)" ]; then
    log_info "No sessions yet."
    return 0
  fi

  printf "  %-28s  %-24s  %-10s  %-10s\n" "ID" "NAME" "STATUS" "TYPE"
  printf "  %-28s  %-24s  %-10s  %-10s\n" "----------------------------" "------------------------" "----------" "----------"

  # Sort newest first
  for session_dir in $(ls -1dt "${state_dir}"/*/  2>/dev/null); do
    local session_id status session_name session_type
    session_id=$(basename "$session_dir")
    status=$(cat "${session_dir}/status"     2>/dev/null | tr -d '[:space:]' || echo "unknown")
    session_name=$(jq -r '.name // "-"'      "${session_dir}/job.json" 2>/dev/null || echo "-")
    session_type=$(cat "${session_dir}/type" 2>/dev/null | tr -d '[:space:]' || echo "-")

    printf "  %-28s  %-24s  %-10s  %-10s\n" \
      "$session_id" \
      "${session_name:0:24}" \
      "$status" \
      "$session_type"
  done
}
