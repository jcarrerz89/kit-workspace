Sync the kit-workspace repository to its remote origin.

This command is ONLY for the kit-workspace orchestrator repo at the current working directory. Do NOT touch any registered app repositories (nogal, petfi, or any path referenced in ~/.kit-workspace/workspace.json).

Steps:
1. Run `git status` to see what has changed in the kit-workspace repo
2. If there is nothing to commit and the branch is up to date with origin, report that and stop
3. Stage only files that belong to kit-workspace (lib/, drivers/, ui/src, ui/src-tauri/src, ui/index.html, ui/vite.config.js, ui/package.json, kit-workspace, install.sh, templates/, history.json, .claude/). Do NOT stage node_modules, dist, src-tauri/target, or any app repo paths
4. Review the staged diff and write a concise commit message that describes what changed
5. Commit the changes
6. Run `git push origin master` (or the current branch if not master)
7. Report the result: what was committed and whether the push succeeded
