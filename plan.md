# Lieutenant Dashboard Improvements

Improve the Lieutenant dashboard to be a proper orchestration UI, not just a monitor.

## Acceptance Criteria

- [ ] Plan panel shows the mission and sub-tasks with live checkboxes
- [ ] Transcript tab allows direct interaction with subagents
- [ ] Artifacts tab shows PR links, test results, commits
- [ ] Left panel agents persist with updating status dots
- [ ] Jira is optional — plan.md is the primary input

## Sub-tasks

- [ ] task-1: Plan panel renders markdown with interactive checkboxes
- [ ] task-2: Transcript tab wired to send messages to agent's tmux pane
- [ ] task-3: Artifacts endpoint collects PR links via `gh pr list`
- [ ] task-4: Agent history persists across tmux window lifecycle
- [x] task-5: Rename SE Swarm to Lieutenant across all files
- [x] task-6: Move repo to ~/.lieutenant, decouple from micolash

## Notes

- Dashboard runs on http://localhost:7777
- Agents communicate via tmux send-keys
- Plan file is the source of truth, not Jira
