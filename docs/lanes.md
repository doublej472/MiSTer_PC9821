# Working with several agents (worktrees): the details

The workflow itself (worktrees, commits, who runs what, merging, memory bounds, keeping fit
outputs) is in [`AGENTS.md`](../AGENTS.md#working-with-several-agents-worktrees); these are the
working habits behind it. The hardware-test rules lanes follow are in
[`mister-testing.md`](mister-testing.md#rules-for-testing-on-a-mister).

- Exclude build trees from searches: `rg -g'!build' -g'!.build' <pattern>`.
- Verilator object directories are large: prune `tests/pc9821/build/` in finished worktrees.
- A queued message does not interrupt a running tool call; kill a runaway process by PID, and
  only one whose working directory is inside your own worktree (several lanes run the same binary
  names). A lane
  waiting on its own fit or bench is not hung. Never search `/` for documentation.
- Edit hygiene: DOS files are CRLF, docs are UTF-8, and an edit and its `git commit` are separate
  steps.
- **Explore cheaply, implement carefully.** A survey lane (a cheaper model) measures, ranks and
  writes an implementer-ready spec without changing design files; an implementation lane (a
  stronger model) builds, tests and gates one chosen item. Lanes run continuously on area, timing
  and correctness; the integrator verifies each lane's claims, gates, fits, hardware-tests and
  merges, then starts the next.
