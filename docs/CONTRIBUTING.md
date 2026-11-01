# Contributing

The entry point for contributors. The full guide - evidence, gates, builds,
hardware testing - starts at [`AGENTS.md`](../AGENTS.md); this page states the one
design rule the core treats as non-negotiable.

## The project rule: Single-Cycle Event Discipline

> **An event is data.** A single-cycle pulse is a piece of data with exactly one
> owner of its consumption, and its next-state update is written exactly once per
> register per cycle.

This rule is **mandatory** for every pulse, strobe, and one-shot event in the
core — every new `always` block, handshake, and module boundary that carries
one. It has eight sub-rules:

- **R1 — One event, one consumer.**
- **R2 — No source-order semantics.**
- **R3 — Set vs. clear collisions need a named, local, asserted rule.**
- **R4 — Coincident dual events are merged, never arbitrated by luck.**
- **R5 — Never suppress an event to fix a coincidence; account for it.**
- **R6 — No level-bubble edge detection.**
- **R7 — Deferred consumption, not lost consumption.**
- **R8 — Assertions are the contract.**

A change that breaks one of these — a second sequential consumer of a pulse,
source-order-dependent assignments, an unreconciled set/clear coincidence, a
suppressed event, a level-bubble wait, or a cross-module pulse without its
assertion — is a **design-rule violation, not a style preference**, and is
grounds to reject the change.

Read the full rule before writing any such block. The complete statements of
R1–R8, an in-tree exemplar for each, and the 7-point audit checklist for a new
pulse are in
[`docs/single-cycle-event-discipline.md`](single-cycle-event-discipline.md).

## Everything else

The evidence rules, the build and test gates, and the containerised Quartus workflow are in
[`AGENTS.md`](../AGENTS.md).
