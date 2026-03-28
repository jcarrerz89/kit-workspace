#!/usr/bin/env bash
# =============================================================================
# merge.sh — Merge completed feature branches back into main
# =============================================================================
#
# Flow per agent branch:
#   1. git fetch origin
#   2. git rebase origin/main  (agent resolves conflicts if any)
#   3. git checkout main && git merge --no-ff <branch>
#   4. git push origin main
#   5. git worktree remove && git branch -d <branch>
#
# Non-git projects: worktree directory is removed, no git ops.
#
# Usage:
#   merge_job <job-id>
# =============================================================================

# ---------------------------------------------------------------------------
# merge_job — Entry point: merge all branches for a completed job
# ---------------------------------------------------------------------------
merge_job() {
  local job_id="$1"
  local job_state_dir="${HOME}/.kit-workspace/state/${job_id}"

  if [ ! -f "${job_state_dir}/job.json" ]; then
    log_error "merge_job: job not found: $job_id"
    return 1
  fi

  local job_json
  job_json=$(cat "${job_state_dir}/job.json")

  log_info "merge_job: merging job '$job_id' into main"

  local any_failed=0

  while IFS= read -r project_name; do
    [ -z "$project_name" ] && continue

    local project_dir
    project_dir=$(workspace_resolve_path "$project_name" 2>/dev/null || echo "")

    if [ -z "$project_dir" ] || [ ! -d "$project_dir" ]; then
      log_error "merge_job: cannot resolve path for '$project_name' — skipping"
      any_failed=1
      continue
    fi

    local repo_json
    repo_json=$(echo "$job_json" | jq -c --arg p "$project_name" '.repos[] | select(.project == $p)')

    while IFS= read -r branch; do
      [ -z "$branch" ] && continue
      _merge_branch "$project_dir" "$project_name" "$branch" "$job_id" || any_failed=1
    done < <(echo "$repo_json" | jq -r '.agents[].branch')

  done < <(echo "$job_json" | jq -r '.repos[].project')

  if [ "$any_failed" -eq 0 ]; then
    _history_record "$job_json" "$job_id"
    # Infer and record session type from commit messages
    local session_type
    session_type=$(session_infer_type "$job_id" 2>/dev/null || echo "")
    if [ -n "$session_type" ]; then
      echo "$session_type" > "${job_state_dir}/type"
      log_step "Session type: $session_type"
    fi
    log_ok "merge_job: all branches merged and pushed"
  else
    log_warn "merge_job: some branches failed — check output above"
  fi

  return $any_failed
}

# ---------------------------------------------------------------------------
# _merge_branch — Merge a single feature branch into main
# ---------------------------------------------------------------------------
_merge_branch() {
  local project_dir="$1"
  local project_name="$2"
  local branch="$3"
  local job_id="$4"

  local worktree_root
  worktree_root="$(dirname "$project_dir")/kit-worktrees"
  local worktree_path="${worktree_root}/${branch}"

  log_info "  [$project_name] branch: $branch"

  # Non-git project: just remove the worktree directory
  if [ ! -d "${project_dir}/.git" ]; then
    log_step "  [$project_name] not a git repo — removing worktree directory"
    rm -rf "$worktree_path"
    log_ok "  [$project_name] done (no git)"
    return 0
  fi

  # Worktree must exist
  if [ ! -d "$worktree_path" ]; then
    log_warn "  [$project_name] worktree not found at $worktree_path — branch may already be merged"
    return 0
  fi

  # -------------------------------------------------------------------------
  # Step 1: Fetch latest from origin
  # -------------------------------------------------------------------------
  log_step "  [$project_name] fetching origin..."
  (cd "$project_dir" && git fetch origin 2>&1) || {
    log_warn "  [$project_name] fetch failed (no remote?) — continuing without fetch"
  }

  # -------------------------------------------------------------------------
  # Step 2: Rebase feature branch onto origin/main
  # -------------------------------------------------------------------------
  log_step "  [$project_name] rebasing $branch onto origin/main..."

  local has_remote=true
  git -C "$project_dir" remote 2>/dev/null | grep -q . || has_remote=false

  # Determine the rebase target: prefer origin/main, fall back to local main
  local rebase_target="main"
  if [ "$has_remote" = "true" ] && git -C "$project_dir" rev-parse origin/main &>/dev/null 2>&1; then
    rebase_target="origin/main"
  fi

  log_step "  [$project_name] rebasing $branch onto $rebase_target..."
  if ! (cd "$worktree_path" && git rebase "$rebase_target" 2>&1); then
    # Check if this is a real conflict vs a rebase-state issue
    if [ -d "${worktree_path}/.git/rebase-merge" ] || [ -d "${worktree_path}/.git/rebase-apply" ]; then
      log_warn "  [$project_name] rebase has conflicts — launching agent to resolve"
      _resolve_conflicts_with_agent "$worktree_path" "$project_name" "$branch" "$job_id" || {
        log_error "  [$project_name] agent could not resolve conflicts — aborting merge for this branch"
        (cd "$worktree_path" && git rebase --abort 2>/dev/null || true)
        return 1
      }
    else
      log_warn "  [$project_name] rebase failed (non-conflict) — attempting merge without rebase"
    fi
  fi

  # -------------------------------------------------------------------------
  # Step 3: Merge into main
  # -------------------------------------------------------------------------
  log_step "  [$project_name] merging $branch into main..."

  local commit_msg
  commit_msg=$(_merge_commit_message "$job_id" "$project_name" "$branch")

  (
    cd "$project_dir"
    git checkout main 2>&1
    [ "$has_remote" = "true" ] && git pull origin main --ff-only 2>&1 || true
    git merge --no-ff "$branch" -m "$commit_msg" 2>&1
  ) || {
    log_error "  [$project_name] merge into main failed"
    return 1
  }

  # -------------------------------------------------------------------------
  # Step 4: Push
  # -------------------------------------------------------------------------
  if [ "$has_remote" = "true" ]; then
    log_step "  [$project_name] pushing main to origin..."
    (cd "$project_dir" && git push origin main 2>&1) || {
      log_error "  [$project_name] push failed"
      return 1
    }
  else
    log_step "  [$project_name] no remote — skipping push"
  fi

  # -------------------------------------------------------------------------
  # Step 5: Remove worktree and delete branch (local + remote)
  # -------------------------------------------------------------------------
  log_step "  [$project_name] cleaning up worktree..."
  (cd "$project_dir" && git worktree remove "$worktree_path" --force 2>&1) || rm -rf "$worktree_path"
  (cd "$project_dir" && git branch -d "$branch" 2>&1) || \
    log_warn "  [$project_name] could not delete local branch $branch"

  if [ "$has_remote" = "true" ]; then
    log_step "  [$project_name] deleting remote branch $branch..."
    (cd "$project_dir" && git push origin --delete "$branch" 2>&1) || \
      log_warn "  [$project_name] could not delete remote branch $branch (may not exist on origin)"
  fi

  log_ok "  [$project_name] $branch → main ✓"
  return 0
}

# ---------------------------------------------------------------------------
# _resolve_conflicts_with_agent — Launch a Claude agent to resolve rebase conflicts
# The agent resolves and stages files; we then run git rebase --continue
# ---------------------------------------------------------------------------
_resolve_conflicts_with_agent() {
  local worktree_path="$1"
  local project_name="$2"
  local branch="$3"
  local job_id="$4"

  local log_file="${HOME}/.kit-workspace/state/${job_id}/merge-conflict-${project_name}-${branch//\//-}.log"

  local prompt
  prompt="You are resolving git rebase conflicts in the repository at: $worktree_path

The project is '$project_name', branch '$branch' is being rebased onto origin/main.

Your task:
1. Run 'git status' to identify conflicted files
2. For each conflicted file: read it, understand both sides, resolve the conflict by keeping the correct code (favour the incoming feature branch changes unless they clearly break main)
3. After resolving each file, run 'git add <file>'
4. Once ALL conflicts are staged, run 'git rebase --continue' — set GIT_EDITOR=true to skip the commit message prompt
5. If the rebase produces more conflict rounds, repeat from step 1
6. When 'git status' shows a clean working tree and the rebase is complete, exit

Do NOT run 'git rebase --abort'. Resolve every conflict."

  log_step "  [$project_name] running conflict-resolution agent (log: $log_file)"

  (
    cd "$worktree_path"
    GIT_EDITOR=true claude -p "$prompt" --dangerously-skip-permissions >"$log_file" 2>&1
  )
  local rc=$?

  if [ $rc -ne 0 ]; then
    log_error "  [$project_name] conflict-resolution agent exited with code $rc — see $log_file"
    return 1
  fi

  # Verify rebase is actually complete
  if [ -d "${worktree_path}/.git/rebase-merge" ] || [ -d "${worktree_path}/.git/rebase-apply" ]; then
    log_error "  [$project_name] rebase still in progress after agent run — see $log_file"
    return 1
  fi

  log_ok "  [$project_name] conflicts resolved by agent"
  return 0
}

# ---------------------------------------------------------------------------
# _merge_commit_message — Build a rich commit message from job state
# ---------------------------------------------------------------------------
_merge_commit_message() {
  local job_id="$1"
  local project_name="$2"
  local branch="$3"

  local job_state_dir="${HOME}/.kit-workspace/state/${job_id}"
  local job_json
  job_json=$(cat "${job_state_dir}/job.json" 2>/dev/null || echo "{}")

  local job_name job_desc
  job_name=$(echo "$job_json" | jq -r '.name // "unnamed"')
  job_desc=$(echo "$job_json" | jq -r '.description // ""')

  local agents_summary
  agents_summary=$(echo "$job_json" | jq -r --arg p "$project_name" '
    .repos[] | select(.project == $p) | .agents[] |
    "  - \(.role): \(.description // "")"
  ' 2>/dev/null || echo "")

  local msg="feat($project_name): $job_name

$job_desc

Job:    $job_id
Branch: $branch
Agents:
$agents_summary"

  echo "$msg"
}

# ---------------------------------------------------------------------------
# _history_record — Append job summary to history.json and commit it
# history.json lives in the kit-workspace repo root (KWS_DIR)
# ---------------------------------------------------------------------------
_history_record() {
  local job_json="$1"
  local job_id="$2"

  local history_file="${KWS_DIR}/history.json"
  local merged_at
  merged_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build the summary entry
  local entry
  entry=$(echo "$job_json" | jq -c \
    --arg job_id  "$job_id" \
    --arg merged  "$merged_at" \
    '{
      id:          $job_id,
      name:        (.name // "unnamed"),
      description: (.description // ""),
      merged_at:   $merged,
      repos: [.repos[] | {
        project: .project,
        branches: [.agents[].branch],
        agents: [.agents[] | {role: .role, description: (.description // "")}]
      }]
    }')

  # Init history.json if missing
  if [ ! -f "$history_file" ]; then
    echo "[]" > "$history_file"
  fi

  # Append entry
  local tmp="${history_file}.tmp.$$"
  jq --argjson entry "$entry" '. + [$entry]' "$history_file" > "$tmp" \
    && mv "$tmp" "$history_file" \
    || { rm -f "$tmp"; log_warn "history: could not update history.json"; return 0; }

  # Commit history.json into the kit-workspace repo
  if git -C "$KWS_DIR" rev-parse --git-dir &>/dev/null; then
    git -C "$KWS_DIR" add history.json
    git -C "$KWS_DIR" commit -m "history: record job $job_id — $(echo "$job_json" | jq -r '.name // "unnamed"')" \
      --no-verify 2>&1 | grep -v "^$" || true
    log_step "history.json committed to kit-workspace repo"
  fi

  log_ok "Job recorded in history.json"
}

# ---------------------------------------------------------------------------
# history_list — Print job history from history.json
# ---------------------------------------------------------------------------
history_list() {
  local history_file="${KWS_DIR}/history.json"

  if [ ! -f "$history_file" ] || [ "$(cat "$history_file")" = "[]" ]; then
    log_info "No history yet. Merge a job to start tracking."
    return 0
  fi

  echo ""
  echo "kit-workspace — Feature History"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  jq -r 'reverse | .[] | "
\(.merged_at | .[0:10])  \(.name)
  \(.description)
  Job: \(.id)
  Repos: \([.repos[].project] | join(", "))
"' "$history_file" 2>/dev/null

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}
