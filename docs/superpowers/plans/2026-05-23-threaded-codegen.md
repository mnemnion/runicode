# Threaded Codegen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `runicode-gen` generate independent Unicode output groups concurrently while preserving deterministic output and Zig 0.16 `std.Io` style.

**Architecture:** Keep alias loading and UCD audit as sequential setup. Partition the manifest into independent generator jobs, each with its own arena and local state, then dispatch those jobs with `std.Io.concurrent`. Workers emit their own group trees; after every future is awaited, one root pass writes only top-level import roots.

**Tech Stack:** Zig 0.16.0, `std.process.Init`, `std.Io.concurrent`, `std.Io.Dir`/`File`, `std.heap.ArenaAllocator`, existing `runeset`, `unicoder`, and `ezcaper` imports.

---

## Non-Negotiable Constraints

- Keep `pub fn main(init: std.process.Init) !void`; use `init.io`, `init.arena`, and explicit `std.Io` plumbing.
- Use `std.Io.concurrent` futures for workers that return generator errors. Do not use `std.Io.Group.concurrent` for errorful workers because its worker return type is constrained to `std.Io.Cancelable!void`.
- Do not use `std.Thread.Pool`, `std.Thread.WaitGroup`, old `std.io.*`, `std.Options.debug_io`, or global I/O.
- Do not share mutable maps, writers, `Db`, or `ArenaAllocator` instances across workers.
- Do not wrap a shared master database in locks. The only shared generator data is the fully built, read-only `Aliases`.
- Do not reimplement existing functionality from Zig or imports: path manipulation, sorting, hash maps, UTF/WTF-8 conversion, escaping, RuneSet construction/serialization, or build graph imports.
- Preserve deterministic output by sorting inside each worker and writing final root indexes after all workers finish.

## Work Units

The unit of concurrency is an output namespace, not a raw UCD file.

- `Aliases`: sequential setup, loaded from `PropertyAliases.txt` and `PropertyValueAliases.txt`, then shared read-only.
- `ScriptsBundle`: one worker for both `Scripts` and `ScriptsExtended`; it loads `Scripts.txt`, copies those ranges, then applies `ScriptExtensions.txt`.
- `GeneralCategory`: one worker for `extracted/DerivedGeneralCategory.txt` plus local aggregate synthesis for `C`, `L`, `LC`, `M`, `N`, `P`, `S`, and `Z`.
- `CoreProperties`: In the current code, this is special-cased.  Do not follow this, treat this data as follows.
- Every other property namespace: one worker per emitted namespace, merging same-namespace manifest entries when needed.
- Special map/record namespaces: stay out of this first threaded pass unless the worker owns the full namespace and emits disjoint paths.

## File Structure

- Modify `src/gen/runicode-gen.zig`: orchestration only. Parse args, open dirs, clean output, audit UCD, load aliases, build jobs, dispatch futures, await all, write final root files, print status.
- Create `src/gen/ucd/jobs.zig`: manifest partitioning into deterministic `Job` records and root metadata.
- Create `src/gen/ucd/worker.zig`: worker entry points. Each worker owns an arena, parses its assigned files, finalizes RuneSets, and emits its group files.  It's better to have special purpose workers for special tasks (scripts and scx) rather than a maze of conditions which are mostly met.
- Modify `src/gen/ucd/emit.zig`: keep path/identifier/writer helpers; split current monolithic `emitRoots` into reusable group emitters and root-index emitters.
- The `src/gen/ucd/db.zig` must not survive.  Each job is responsible for maintaining its own information.
- Keep `src/gen/ucd/aliases.zig`, `parse.zig`, `manifest.zig`, and `audit.zig` as shared support modules with narrow additions only.

## Watchdog Sub-Agents

Use Watchdog agents as blocking review gates, not as implementers.

- `Watchdog.StdIo`: before scheduler code lands, verify the diff uses Zig 0.16 `std.Io.concurrent` correctly, keeps explicit `io`, awaits every future, and does not revive old `std.io` or `std.Thread.Pool` patterns.
- `Watchdog.Efficiency`: after worker code lands, scan for lock-wrapped shared state, unnecessary per-line heap churn, needless string copies, serialized work hidden inside workers, or slower replacements for existing imports.
- `Watchdog.NoReinvent`: after emitter splitting, forbid reimplementing standard library features, `RuneSet`, `unicoder`, `ezcaper`, or existing local identifier/path helpers.
- `Watchdog.Diff`: before final verification, review the whole diff for determinism, shared allocator hazards, and accidental API drift.

Any Watchdog blocker stops implementation until the relevant task is revised.

## Tasks

### Task 1: Partition Manifest Into Jobs

**Files:**
- Create: `src/gen/ucd/jobs.zig`
- Modify: `src/gen/runicode-gen.zig`
- Test: `src/gen/ucd/jobs.zig`

- [ ] Add `JobKind`, `Job`, and `jobs()` so manifest entries are grouped by output namespace.
- [ ] Special-case `ScriptsBundle`, `GeneralCategory`, and `CoreProperties`.
- [ ] Add tests proving `Scripts.txt` and `ScriptExtensions.txt` are one job and unrelated namespaces remain separate.
- [ ] Run `zig test src/gen/ucd/jobs.zig`.

### Task 2: Split Root Emission From Group Emission

**Files:**
- Modify: `src/gen/ucd/emit.zig`
- Test: `src/gen/ucd/emit.zig`

- [ ] Extract group-level functions that emit `sets/<group>.zig`, `sets/<group>/<value>.zig`, `codepoints/...`, `strs/...`, `enums/<group>.zig`, and `maps/<group>.zig`.
- [ ] Extract root-index functions that write `sets.zig`, `codepoints.zig`, `strs.zig`, `enums.zig`, `maps.zig`, and `runicode.zig` from job metadata only.
- [ ] Keep sorting in the group emitter and root emitter, not in callers.
- [ ] Run `zig test src/gen/ucd/emit.zig`.

### Task 3: Build Worker-Local Generators

**Files:**
- Create: `src/gen/ucd/worker.zig`
- Modify: `src/gen/runicode-gen.zig`
- Test: `src/gen/ucd/worker.zig`

- [ ] Add `runJob(io, gpa, ucd_dir, out_dir, aliases, job) anyerror!WorkerStats`.
- [ ] Inside `runJob`, create `var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit();`.
- [ ] Parse assigned files into worker-local storage only. Existing `Db` may be reused inside the worker, but it must not escape or be shared.
- [ ] Implement local handling for `ScriptsBundle`, including `ScriptsExtended` inheritance in the same worker.
- [ ] Implement local handling for `GeneralCategory` aggregates in the same worker that loaded the leaf categories.
- [ ] Emit all files owned by the job before returning `WorkerStats`.
- [ ] Add temp-dir fixture tests for one simple property, `CoreProperties`, `GeneralCategory`, and `ScriptsBundle`.
- [ ] Run `zig test src/gen/ucd/worker.zig`.

### Task 4: Dispatch Workers With Zig 0.16 std.Io

**Files:**
- Modify: `src/gen/runicode-gen.zig`
- Test: `src/gen/runicode-gen.zig`

- [ ] Pre-create the top-level output directories once: `sets`, `codepoints`, `strs`, `enums`, and `maps`.
- [ ] Dispatch each job with `std.Io.concurrent(io, worker.runJob, .{ io, init.gpa, ucd_dir, out_dir, &aliases, job })`.
- [ ] Store futures in an arena-backed list and await all of them before root emission.
- [ ] If spawning a future returns `error.ConcurrencyUnavailable`, run that job inline and record the stats; do not silently drop work.
- [ ] Collect the first worker error but await every started worker before returning it.
- [ ] Print one final summary from the main thread only.
- [ ] Run `zig test src/gen/runicode-gen.zig`.

### Task 5: Root Pass And Determinism Check

**Files:**
- Modify: `src/gen/runicode-gen.zig`
- Modify: `src/gen/ucd/emit.zig`

- [ ] After all workers finish, call root-index emitters using deterministic job metadata.
- [ ] Ensure root imports match the public shape expected by `runicode.zig`.
- [ ] Generate once before the threaded change and once after it, then compare normalized file lists and contents.
- [ ] Run `zig build install-code`.
- [ ] Run `zig build test`.

### Task 6: Watchdog Gate And Cleanup

**Files:**
- Review-only across touched files

- [ ] Run `Watchdog.StdIo` on scheduler code.
- [ ] Run `Watchdog.Efficiency` on worker and allocation code.
- [ ] Run `Watchdog.NoReinvent` on emitter/path/helper changes.
- [ ] Run `Watchdog.Diff` on the final diff.
- [ ] Address blockers, then run `zig fmt` on touched Zig files.
- [ ] Re-run `zig build install-code` and `zig build test`.

## Acceptance Criteria

- `runicode-gen` loads aliases once, then runs independent namespace workers concurrently.
- No shared mutable master database exists.
- Every worker has its own arena and owns all parser/generator state it mutates.
- `Scripts` and `ScriptsExtended` are generated by the same worker.
- General-category aggregates are local to the `GeneralCategory` worker.
- Output is deterministic across repeated runs.
- Generated public imports match the existing generated API shape.
- `zig build install-code` and `zig build test` pass.
