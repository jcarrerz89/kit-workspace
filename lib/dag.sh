#!/bin/bash
# =============================================================================
# dag.sh — Dependency graph for task management
# =============================================================================
#
# Provides DAG (Directed Acyclic Graph) operations for task dependencies:
#   - Parse tasks markdown into structured JSON
#   - Validate dependency graph (cycle detection, valid refs)
#   - Find next available tasks (all deps resolved)
#   - Compute parallelism groups automatically
#
# State: .kit-ws/dag-{feature}.json
#
# Requires: jq
# =============================================================================

set -euo pipefail

# Parse a tasks markdown file into a DAG JSON structure
# Input: path to {feature}-tasks.md
# Output: JSON to stdout
dag_parse_tasks() {
  local tasks_file="$1"

  if [ ! -f "$tasks_file" ]; then
    log_error "Tasks file not found: $tasks_file"
    return 1
  fi

  # Extract task blocks using awk — each ### Task N: line starts a block
  local json_nodes="[]"
  local task_id=""
  local task_name=""
  local depends_on=""
  local status="pending"

  while IFS= read -r line; do
    # Detect task header: ### Task N: description
    if echo "$line" | grep -qE '^### Task [0-9]+:'; then
      # Save previous task if any
      if [ -n "$task_id" ]; then
        local deps_json="[]"
        if [ -n "$depends_on" ] && [ "$depends_on" != "none" ] && [ "$depends_on" != "—" ] && [ "$depends_on" != "-" ]; then
          # Parse "Task 1, Task 3" into [1, 3]
          deps_json=$(echo "$depends_on" | tr ',' '\n' | sed 's/[^0-9]//g' | jq -R 'select(length > 0) | tonumber' | jq -s '.')
        fi
        json_nodes=$(echo "$json_nodes" | jq --argjson id "$task_id" --arg name "$task_name" --argjson deps "$deps_json" --arg status "$status" \
          '. + [{id: $id, name: $name, depends_on: $deps, status: $status}]')
      fi

      task_id=$(echo "$line" | grep -oE '[0-9]+' | head -1)
      task_name=$(echo "$line" | sed 's/^### Task [0-9]*: *//')
      depends_on=""
      status="pending"
    fi

    # Detect depends_on line
    if echo "$line" | grep -qiE '^\- \*\*Depends on:\*\*'; then
      depends_on=$(echo "$line" | sed 's/.*\*\*Depends on:\*\* *//')
    fi
  done < "$tasks_file"

  # Save last task
  if [ -n "$task_id" ]; then
    local deps_json="[]"
    if [ -n "$depends_on" ] && [ "$depends_on" != "none" ] && [ "$depends_on" != "—" ] && [ "$depends_on" != "-" ]; then
      deps_json=$(echo "$depends_on" | tr ',' '\n' | sed 's/[^0-9]//g' | jq -R 'select(length > 0) | tonumber' | jq -s '.')
    fi
    json_nodes=$(echo "$json_nodes" | jq --argjson id "$task_id" --arg name "$task_name" --argjson deps "$deps_json" --arg status "$status" \
      '. + [{id: $id, name: $name, depends_on: $deps, status: $status}]')
  fi

  echo "$json_nodes" | jq '{nodes: .}'
}

# Validate a DAG: check for cycles, dangling references, self-references
# Input: DAG JSON (from dag_parse_tasks or file)
# Output: "valid" or error messages, exit code 0 or 1
dag_validate() {
  local dag_json="$1"

  # Validate input is valid JSON with nodes
  if ! echo "$dag_json" | jq -e '.nodes' &>/dev/null; then
    echo "Invalid DAG: missing 'nodes' field or invalid JSON"
    return 1
  fi

  local errors=""

  # Check self-references
  local self_refs
  self_refs=$(echo "$dag_json" | jq -r '.nodes[]? | select(.depends_on | index(.id)) | "Task \(.id) depends on itself"' 2>/dev/null)
  [ -n "$self_refs" ] && errors+="$self_refs"$'\n'

  # Check dangling references
  local all_ids
  all_ids=$(echo "$dag_json" | jq '[.nodes[].id]' 2>/dev/null) || all_ids="[]"
  local dangling
  dangling=$(echo "$dag_json" | jq -r --argjson ids "$all_ids" '
    .nodes[] | .id as $tid |
    .depends_on[] | select(. as $dep | $ids | index($dep) | not) |
    "Task \($tid) depends on Task \(.) which does not exist"
  ')
  [ -n "$dangling" ] && errors+="$dangling"$'\n'

  # Cycle detection via topological sort (Kahn's algorithm)
  local has_cycle
  has_cycle=$(echo "$dag_json" | jq '
    .nodes as $nodes |
    # Build in-degree map
    [range(0; $nodes | length)] |
    reduce .[] as $i (
      {};
      . + {($nodes[$i].id | tostring): ($nodes[$i].depends_on | length)}
    ) as $in_degree |
    # Find initial nodes with 0 in-degree
    [$nodes[] | select(.depends_on | length == 0) | .id] as $queue |
    # Process
    {queue: $queue, visited: 0, in_degree: $in_degree} |
    until(.queue | length == 0;
      .queue[0] as $current |
      .queue |= .[1:] |
      .visited += 1 |
      # Reduce in-degree of dependents
      reduce ($nodes[] | select(.depends_on | index($current)) | .id) as $dep (
        .;
        .in_degree[($dep | tostring)] -= 1 |
        if .in_degree[($dep | tostring)] == 0 then .queue += [$dep] else . end
      )
    ) |
    .visited != ($nodes | length)
  ')

  if [ "$has_cycle" = "true" ]; then
    errors+="Cycle detected in dependency graph"$'\n'
  fi

  if [ -n "$errors" ]; then
    echo "$errors"
    return 1
  fi

  echo "valid"
  return 0
}

# Find next available tasks (all dependencies resolved)
# Input: DAG JSON with status fields updated
# Output: JSON array of available task IDs
dag_next_available() {
  local dag_json="$1"

  echo "$dag_json" | jq '[
    .nodes as $all |
    .nodes[] |
    select(.status == "pending") |
    select(
      if (.depends_on | length) == 0 then true
      else
        (.depends_on | all(. as $dep | $all | map(select(.id == $dep and .status == "done")) | length > 0))
      end
    ) |
    .id
  ]'
}

# Compute parallelism groups from DAG
# Input: DAG JSON
# Output: JSON with groups [{level: 0, tasks: [1,2]}, {level: 1, tasks: [3,4]}]
dag_parallel_groups() {
  local dag_json="$1"
  local max_levels=50

  local result
  result=$(echo "$dag_json" | jq --argjson max "$max_levels" '
    .nodes as $nodes |
    [range(0; $max)] |
    reduce .[] as $level (
      {assigned: [], groups: []};

      ($nodes | map(select(
        (.id as $id | .assigned | index($id) | not) and
        (if (.depends_on | length) == 0 then true
         else [.depends_on[] | . as $dep | .assigned | index($dep)] | all end)
      )) | [.[].id]) as $ready |

      if ($ready | length) > 0 then
        .assigned += $ready |
        .groups += [{level: $level, tasks: $ready}]
      else . end
    ) |
    {
      groups: (.groups | map(select(.tasks | length > 0))),
      total_assigned: (.assigned | length),
      total_nodes: ($nodes | length)
    }
  ' 2>/dev/null)

  if [ -z "$result" ]; then
    log_warn "Error computing parallelism groups"
    echo "[]"
    return 1
  fi

  # Warn if not all nodes were assigned (DAG too deep or has issues)
  local assigned total
  assigned=$(echo "$result" | jq '.total_assigned // 0')
  total=$(echo "$result" | jq '.total_nodes // 0')
  if [ "$assigned" -lt "$total" ]; then
    log_warn "DAG: $assigned/$total tasks assigned (possible cycle or depth > $max_levels levels)"
  fi

  echo "$result" | jq '.groups'
}

# Update task status in DAG file (atomic write via tmp+mv)
# Input: dag file path, task ID, new status
dag_update_status() {
  local dag_file="$1"
  local task_id="$2"
  local new_status="$3"

  if [ ! -f "$dag_file" ]; then
    log_warn "DAG file not found: $dag_file"
    return 1
  fi

  # Validate status value
  case "$new_status" in
    pending|in_progress|done) ;;
    *) log_error "Invalid status: $new_status (use: pending|in_progress|done)"; return 1 ;;
  esac

  # Atomic write: write to temp file then mv (rename is atomic on same filesystem)
  local tmp_file="${dag_file}.tmp.$$"
  if jq --argjson id "$task_id" --arg status "$new_status" '
    .nodes |= map(if .id == $id then .status = $status else . end)
  ' "$dag_file" > "$tmp_file" 2>/dev/null && [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$dag_file"
  else
    rm -f "$tmp_file"
    log_error "Error updating DAG: task $task_id → $new_status"
    return 1
  fi
}
