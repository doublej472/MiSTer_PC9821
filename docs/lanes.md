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
- **A guest-visible lane boots the hard disk on a card before it is merged.** A change to a port,
  a DIP/SETUP value or other BIOS-visible state can stop the BIOS booting the disk on some boots
  only: 639674f3 showed "insert a system disk" on boots 1 and 2 after a load and then on every
  other boot, and no bench or boot golden saw it. Such a lane runs the regression's `boot-loop`
  item (`--boot-count 6`, [`mister-testing.md`](mister-testing.md#the-scripted-regression-runner))
  on its own fit, or hands the integrator that run as a merge condition.
- **The integrator runs the full battery on the merged head before cutting a release
  candidate.** A lane's focused benches pass on the lane alone; a later merge can leave another
  bench stale (the Floppy-mode default change left `tb_pc9821_setup_osd` failing).
- Edit hygiene: DOS files are CRLF, docs are UTF-8, and an edit and its `git commit` are separate
  steps.
- **Explore cheaply, implement carefully.** A survey lane (a cheaper model) measures, ranks and
  writes an implementer-ready spec without changing design files; an implementation lane (a
  stronger model) builds, tests and gates one chosen item. Lanes run continuously on area, timing
  and correctness; the integrator verifies each lane's claims, gates, fits, hardware-tests and
  merges, then starts the next.
