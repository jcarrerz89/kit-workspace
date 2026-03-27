#!/bin/bash
# General utilities

set -euo pipefail

: "${KWS_DIR:?KWS_DIR not set — source from kit-workspace}"

DRY_RUN="${DRY_RUN:-false}"

# Dry-run guard — returns 0 if dry-run is active (caller should skip side-effect)
is_dry_run() {
  [ "$DRY_RUN" = "true" ]
}

dry_run_log() {
  echo -e "${DIM}[dry-run]${NC} $1"
}

mode_name() {
  case "$1" in
    1) echo -e "${CYAN}Mode 1 — Supervised${NC}" ;;
    2) echo -e "${YELLOW}Mode 2 — Semi-auto${NC}" ;;
    3) echo -e "${RED}Mode 3 — Fire & Forget${NC}" ;;
    4) echo -e "${GREEN}Mode 4 — Agent Teams${NC}" ;;
    *) echo "Unknown" ;;
  esac
}

# Read a field from task JSON
task_field() {
  local json="$1" field="$2"
  if [ -z "$json" ]; then
    log_debug "task_field: empty JSON input for field '$field'"
    return 1
  fi
  echo "$json" | jq -r ".$field // empty" 2>/dev/null
}

# Read agent array from task JSON
task_agents() {
  local json="$1"
  if [ -z "$json" ]; then
    log_debug "task_agents: empty JSON input"
    return 1
  fi
  echo "$json" | jq -c '.agents[]?' 2>/dev/null
}

# Read agent count
task_agent_count() {
  local json="$1"
  echo "$json" | jq '.agents | length' 2>/dev/null || echo "0"
}

# Get agent profile content
get_agent_profile() {
  local profile_name="$1"
  local profile_file="$KWS_DIR/agents/${profile_name}.md"

  if [ -f "$profile_file" ]; then
    cat "$profile_file"
  else
    log_warn "Profile not found: $profile_name (using generic)"
    echo "You are a development agent for kit-workspace. Follow the instructions in the project's CLAUDE.md."
  fi
}

# Build prompt for an agent from its profile + task context
build_agent_prompt() {
  local task_json="$1"
  local agent_json="$2"

  local role
  role=$(echo "$agent_json" | jq -r '.role')
  local profile_name
  profile_name=$(echo "$agent_json" | jq -r '.profile')
  local task_name
  task_name=$(task_field "$task_json" "name")
  local task_desc
  task_desc=$(task_field "$task_json" "description")

  # Get profile content
  local profile
  profile=$(get_agent_profile "$profile_name")

  # Get role boundaries from config
  local boundaries=""
  if [ -f "${CONFIG_FILE:-}" ]; then
    local dirs
    dirs=$(jq -r ".boundaries.${profile_name} // [] | .[]" "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$dirs" ]; then
      boundaries="Your file scope: $dirs"
    fi
  fi

  # Compose prompt
  cat << EOF
$profile

---
Current task: $task_name
Your role: $role
Description: $task_desc
${boundaries:+$boundaries}

Instructions:
1. Read the project CLAUDE.md for full context
2. Analyze the current state of the code within your scope
3. Execute the task described above
4. Make descriptive commits with prefix [$role]
EOF
}

# Generate a unique session ID (timestamp + random suffix to avoid collisions)
session_id() {
  local rand=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
  echo "$(date +%Y%m%d-%H%M%S)-${rand}"
}
