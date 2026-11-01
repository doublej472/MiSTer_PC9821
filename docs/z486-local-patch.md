# z486: the vendored CPU and its diff map

`src/z486/` is a **plain copy** of a curated fork of
[nand2mario/z486](https://github.com/nand2mario/z486): a linear series of single-purpose
`fix(...)` / `pc98(...)` / `tests:` / `docs:` / `chore:` commits on upstream, each with its
reason. The fork's `docs/fork-rebase-policy.md` (inside `src/z486/docs/`) records how the
series is kept: a correction is folded into the commit it corrects, and a fork fix is dropped
when upstream's own implementation passes its fail-first test.

**Vendored commit:** the fork's `a7a863f`, a plain copy. The tree carries no local patch: the
diff map below is the explicit `(none)` row. What each fork commit changes, and why, is in the
fork's own log.

What the fork carries, in outline:

- **PC-98 memory-map template** (`z486_cache_map_pkg`): the compile-time classes of the PC-98
  windows (device apertures uncached and ordered, RAM cacheable), with stores to the template's
  RAM pages posted through the direct store port (`TEMPLATE_STORE_POST`) and device-window stores
  kept on the ordered demand path, so no device sees a merged or reordered store.
- **Correctness fixes** with fail-first programs under `src/z486/tests/programs/`, for example a
  faulting LFS/LGS keeping the old FS/GS selector (`seg_load_np_keeps_segreg`), and the 486 AC
  flag kept across protected-mode interrupt entry while real-mode delivery clears it
  (`ac_int_keep`, `ac_int_real`).
- **Zero-cycle timing and area cuts**, each proven value-identical by a yosys SAT file under
  `src/z486/tests/equiv/` and cycle-identical over the fork's test programs.

## The fork-first rule

CPU changes are made in the fork **first**, then re-vendored. Nothing lives only in this tree.

- `src/z486/` may change - area, timing and simplifying emulated hardware are in scope - but
  through the fork, so the next re-vendor never has to re-apply anything.
- **Emergency only:** a change that must land here before the fork is a marked
  `LOCAL PATCH (PC-9821 core)` block in the file plus a numbered entry in this document and a row
  in the diff map. It is owed to the fork, and the next re-vendor should leave the map empty
  again.
- The contract a change must keep or re-report with per-change attribution:
  `bash tests/pc9821/run_z486_suite.sh` (328/328 at this vendoring; the runner floor is 309), Dhrystone
  `242611 cy / 121837 instr / CPI 1.991` (`docs/dhrystone-numbers.md`) and the boot golden
  (`CYCLES used=930533`). A latency-visible change that costs cycles is raised in
  `docs/trade-candidates.md`.

## Re-vendoring

1. In the fork, run its release gate: `make -C tests test-release JOBS=4`.
2. Remove the tracked tree and unpack the fork commit:
   `git rm -r -q src/z486 && mkdir -p src/z486 && git -C <fork> archive <sha> | tar -x -C src/z486`.
3. `git add -f` every path the fork tracks (`git -C <fork> ls-tree -r --name-only <sha>`):
   `src/z486/.gitignore` would otherwise silently skip some tracked files.
4. Check the map against a checkout of the fork at that commit:
   `python3 tools/check_z486_patch_diff.py --upstream <fork checkout>` (or set
   `$Z486_UPSTREAM`). Without a baseline the check prints a loud SKIP (exit 2) - never a pass.
5. Run the gates in `AGENTS.md` (the z486 suite, Dhrystone, the boot golden, the bench
   battery, lint, the integrated build), update the vendored-commit line above and the map's
   heading, and report any moved number with its attribution. **Never relax the map** to make
   the checker pass.

`tools/check_z486_patch_diff.py --selftest` proves the checker can still fail (it plants an
undocumented delta and a stale row in temporary copies); it needs no external checkout.

## Local patches

None.

### Verified diff map (the fork at the vendored commit)

`tools/check_z486_patch_diff.py --upstream <fork checkout at the vendored commit>` reports
`Z486 PATCH MAP: PASS (0 documented files, 0 deliberately not carried, 0 tree-only, ...)`.

| file | entries |
|---|---|
| (none) | the tree is a plain copy of the fork: no LOCAL PATCH/ADD, nothing only in upstream, nothing only in the tree |
