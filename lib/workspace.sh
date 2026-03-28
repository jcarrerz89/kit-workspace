#!/usr/bin/env bash
# workspace.sh — workspace config management

KWS_CONFIG="${HOME}/.kit-workspace/workspace.json"

# ---------------------------------------------------------------------------
# workspace_load — Load and validate workspace.json
# Returns 0 if valid, 1 if missing or malformed
# ---------------------------------------------------------------------------
workspace_load() {
  if [ ! -f "$KWS_CONFIG" ]; then
    log_warn "workspace.json not found at $KWS_CONFIG — run: kit-workspace init"
    return 1
  fi

  if ! jq empty "$KWS_CONFIG" 2>/dev/null; then
    log_error "workspace.json is malformed (invalid JSON): $KWS_CONFIG"
    return 1
  fi

  # Validate required top-level field
  local name
  name=$(jq -r '.name // empty' "$KWS_CONFIG" 2>/dev/null)
  if [ -z "$name" ]; then
    log_error "workspace.json missing required field: name"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# workspace_resolve_path — Resolve a project name to its absolute path on disk
# Usage: workspace_resolve_path "petfi"
# Returns absolute path or empty string if not found
# ---------------------------------------------------------------------------
workspace_resolve_path() {
  local project_name="$1"

  workspace_load || return 1

  local raw_path
  raw_path=$(jq -r --arg p "$project_name" '.projects[$p].path // empty' "$KWS_CONFIG" 2>/dev/null)

  if [ -z "$raw_path" ]; then
    echo ""
    return 0
  fi

  # Expand ~ if present
  raw_path="${raw_path/#\~/$HOME}"

  # If already absolute, return as-is
  if [[ "$raw_path" == /* ]]; then
    echo "$raw_path"
    return 0
  fi

  # Relative path — resolve against projects_root
  local projects_root
  projects_root=$(jq -r '.projects_root // empty' "$KWS_CONFIG" 2>/dev/null)
  projects_root="${projects_root/#\~/$HOME}"

  if [ -z "$projects_root" ]; then
    echo "$raw_path"
  else
    echo "${projects_root%/}/${raw_path}"
  fi
}

# ---------------------------------------------------------------------------
# workspace_list_projects — List all registered project names (one per line)
# ---------------------------------------------------------------------------
workspace_list_projects() {
  workspace_load || return 1
  jq -r '.projects | keys[]' "$KWS_CONFIG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# workspace_get_driver — Get the driver for a project ("petfi-kit" or "generic")
# Usage: workspace_get_driver "petfi"
# ---------------------------------------------------------------------------
workspace_get_driver() {
  local project_name="$1"

  workspace_load || return 1

  local driver
  driver=$(jq -r --arg p "$project_name" '.projects[$p].driver // "generic"' "$KWS_CONFIG" 2>/dev/null)
  echo "${driver:-generic}"
}

# ---------------------------------------------------------------------------
# workspace_get_app — Get the app a project belongs to (or empty if not in an app group)
# ---------------------------------------------------------------------------
workspace_get_app() {
  local project_name="$1"

  workspace_load || return 1

  # Search apps map for the project name
  jq -r --arg p "$project_name" '
    .apps // {} | to_entries[]
    | select(.value | map(. == $p) | any)
    | .key
  ' "$KWS_CONFIG" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# workspace_init — Initialize ~/.kit-workspace/ directory structure and blank workspace.json
# Called by `kit-workspace init`
# ---------------------------------------------------------------------------
workspace_init() {
  local kws_dir="${HOME}/.kit-workspace"

  mkdir -p "$kws_dir/state"
  mkdir -p "$kws_dir/logs"

  if [ -f "$KWS_CONFIG" ]; then
    log_warn "workspace.json already exists at $KWS_CONFIG — skipping creation"
    return 0
  fi

  jq -n \
    --arg name "my-workspace" \
    --arg root "${HOME}/Documents/sources" \
    '{
      name: $name,
      projects_root: $root,
      projects: {},
      apps: {}
    }' > "$KWS_CONFIG"

  log_ok "Initialized kit-workspace at $kws_dir"
  echo "  Edit $KWS_CONFIG to add projects."
}

# ---------------------------------------------------------------------------
# workspace_add_project — Add a project to workspace.json
# Usage: workspace_add_project "nogale-frontend" "~/sources/nogal" "generic"
# ---------------------------------------------------------------------------
workspace_add_project() {
  local name="$1"
  local path="$2"
  local driver="${3:-generic}"

  workspace_load || {
    log_error "Cannot add project: workspace not initialized. Run: kit-workspace init"
    return 1
  }

  # Validate driver value
  case "$driver" in
    petfi-kit|generic) ;;
    *)
      log_warn "Unknown driver '$driver' — valid values: petfi-kit, generic. Using generic."
      driver="generic"
      ;;
  esac

  local tmp="${KWS_CONFIG}.tmp.$$"
  if jq \
    --arg n "$name" \
    --arg p "$path" \
    --arg d "$driver" \
    '.projects[$n] = {path: $p, driver: $d}' \
    "$KWS_CONFIG" > "$tmp" \
    && [ -s "$tmp" ] \
    && jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$KWS_CONFIG"
    log_ok "Added project '$name' (driver: $driver, path: $path)"
  else
    rm -f "$tmp"
    log_error "Failed to add project '$name' to workspace.json"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# workspace_add_app — Group projects under a named app
# Usage: workspace_add_app "nogal" "nomades-webapp" "nomades-bff"
# ---------------------------------------------------------------------------
workspace_add_app() {
  local app_name="${1:-}"
  shift
  local projects=("$@")

  if [ -z "$app_name" ] || [ ${#projects[@]} -eq 0 ]; then
    log_error "Usage: workspace_add_app <app-name> <project> [project...]"
    return 1
  fi

  workspace_load || {
    log_error "Cannot add app: workspace not initialized. Run: kit-workspace init"
    return 1
  }

  local tmp="${KWS_CONFIG}.tmp.$$"
  local projects_json
  projects_json=$(printf '%s\n' "${projects[@]}" | jq -R . | jq -s .)

  if jq \
    --arg a "$app_name" \
    --argjson p "$projects_json" \
    '.apps[$a] = $p' \
    "$KWS_CONFIG" > "$tmp" \
    && [ -s "$tmp" ] \
    && jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$KWS_CONFIG"
    log_ok "App '$app_name' → ${projects[*]}"
  else
    rm -f "$tmp"
    log_error "Failed to add app '$app_name'"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# workspace_get_app_projects — Return project names for an app (one per line)
# Usage: workspace_get_app_projects "nogal"
# ---------------------------------------------------------------------------
workspace_get_app_projects() {
  local app_name="$1"
  workspace_load || return 1
  jq -r --arg a "$app_name" '.apps[$a]? // [] | .[]' "$KWS_CONFIG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# workspace_list_apps — Print all app groups (one per line: "name: proj1, proj2")
# ---------------------------------------------------------------------------
workspace_list_apps() {
  workspace_load || return 1
  local app_count
  app_count=$(jq '.apps | length' "$KWS_CONFIG" 2>/dev/null || echo 0)
  if [ "$app_count" -eq 0 ]; then
    log_info "No apps registered yet. Use: kit-workspace add-app <name> <project>..."
    return 0
  fi
  jq -r '.apps | to_entries[] | "\(.key): \(.value | join(", "))"' "$KWS_CONFIG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# workspace_summary — Print workspace summary (for status commands)
# ---------------------------------------------------------------------------
workspace_summary() {
  workspace_load || return 1

  local ws_name projects_root project_count
  ws_name=$(jq -r '.name // "unnamed"' "$KWS_CONFIG")
  projects_root=$(jq -r '.projects_root // "(not set)"' "$KWS_CONFIG")
  project_count=$(jq '.projects | length' "$KWS_CONFIG" 2>/dev/null || echo 0)

  echo "Workspace: $ws_name"
  echo "Root:      $projects_root"
  echo "Projects:  $project_count"
  echo ""

  if [ "$project_count" -gt 0 ]; then
    echo "  NAME                DRIVER       PATH"
    echo "  ─────────────────── ──────────── ──────────────────────────────"
    jq -r '
      .projects | to_entries[]
      | "  \(.key | .[0:19] | . + (" " * (19 - length)))  \(.value.driver | .[0:12] | . + (" " * (12 - length)))  \(.value.path)"
    ' "$KWS_CONFIG" 2>/dev/null
    echo ""
  fi

  # Show app groups if any
  local app_count
  app_count=$(jq '.apps | length' "$KWS_CONFIG" 2>/dev/null || echo 0)
  if [ "$app_count" -gt 0 ]; then
    echo "App groups:"
    jq -r '.apps | to_entries[] | "  \(.key): \(.value | join(", "))"' "$KWS_CONFIG" 2>/dev/null
    echo ""
  fi
}
