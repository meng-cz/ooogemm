# Hierarchical ASAP7 hard macros

The entry point is `tools/run_hierarchical_openroad.py`. It uses the existing
`staticsrc/manifest.json` and `openroadenv.sh`; it does not regenerate or modify
RTL. It has no Python dependencies beyond the standard library. Runtime physical
hooks also require Tcl commands supplied by the installed OpenROAD/ORFS.

## Plan and run

```bash
# Generate configurations, packed wrappers/adapters, bit maps and commands only.
python3 tools/run_hierarchical_openroad.py --dry-run
python3 tools/run_hierarchical_openroad.py --dry-run -j 4

# These commands START REAL SYNTHESIS AND ROUTING. They were not run during
# implementation/acceptance of this script.
python3 tools/run_hierarchical_openroad.py
python3 tools/run_hierarchical_openroad.py -j 4
python3 tools/run_hierarchical_openroad.py --status
python3 tools/run_hierarchical_openroad.py --retry-failed
```

The default workspace is `build/hierarchical_openroad/`. Use `--work-dir PATH`
for another workspace and `--config PATH.json` for overrides to
`tools/hierarchical_openroad.json`. Makefile workspace paths must not contain
whitespace, `#` or `$`. `--status` only reads SQLite, so it also works while a run
holds the workspace lock or when the toolchain is unavailable.

Dry run writes `dry_run/plan.json` and per-task `inputs/` directories. Child views
in those configurations are explicitly unresolved placeholders. Macro dimensions
are read from OpenDB at runtime, never invented by dry run. Dry run does not start
OpenROAD, Yosys, KLayout or Make. It reads/hashes tool and ORFS files to record the
toolchain identity, and sources the project environment script.

There are 18 unique tasks:

| Tasks | Implementation |
| --- | --- |
| Six SRAM variants | Full behavioral storage mapped to standard cells and hardened |
| Three PEs | Instantiate the matching published 2R1W SRAM; other PE logic remains local |
| Three SAs | Instantiate 256/1024/4096 matching PE macros in a fixed grid |
| Six `staticsrc/top_*.sv` modules | Instantiate the SA and operand 1R1W SRAM banks; remaining logic stays local |

The scheduler builds the task DAG before execution and maintains a ready queue
and each node's remaining dependencies. Whenever any task finishes, its parents
are updated and free workers immediately take ready tasks, without waiting for
other tasks in the same batch or hierarchy level. A parent can start only after
every required child has been published. Failed children block their dependent
chain while independent branches continue.

`-j N` (or `--workers N`) selects the maximum number of concurrent module tasks;
it must be a positive integer. The default is the JSON `workers` value (2).
`-j 1` runs tasks sequentially. Each task's frequency attempts remain sequential;
the native tool defaults to one OpenROAD thread per task, independently controlled
by JSON `openroad_threads`. Changing only `-j`/`workers` preserves completed
implementations and stage checkpoints when resuming the same workspace.
Task logs include a stable dependency-order index, for example
`[任务 7/18] pe__... synth @ 1000.0 ps`. The index identifies the module across
concurrent workers and restarts; it is not the number of completed tasks.
Each backend stage log also records this label in its `TASK:` header.
Memory mocking is disabled and the inferred memory limit defaults to 1,048,576
bits. An oversized memory is an error, not an invitation to truncate storage.
Inputs are snapshotted at coordinator startup and copied into each attempt's
`inputs/rtl/`, so editing the source tree during a long run cannot silently change
an in-flight implementation. Restart takes a new snapshot and invalidates the
affected dependency chains. Only packages used by the node's inlined RTL are
included; reverse instance-usage metadata and Python caches do not invalidate
unchanged macro implementations.

## Physical interfaces and layout

Each module gets a packed physical wrapper named `<original>__hard`. Parents use
a wiring-only module with the original interface that instantiates the packed
black box. `inputs/port_map.json` identifies every packed bit's original port,
array index and packed-bit index. Array declaration order occupies low-to-high
element slices; packed element low bits follow the declared right bound.

Parents import the actual child's Liberty, LEF and merged GDS. Child RTL is
excluded from the parent's source closure. The script checks macro view names,
all signal pins, VDD/VSS and the clock attribute. Runtime hooks additionally
check actual macro instance counts, overlap, core containment, VDD/VSS connections
and routed completion. Macro placements are fixed (`place_macro` locks them).

SRAMs have square floorplans. A PE centers its SRAM and gives its directional
data ports corresponding sides. SA row 0 is at the top and column 0 is at the
left. Top operand bank group A is on the left and B is above its SA. Bank groups
are distinguished by their original instance hierarchy prefixes (`ab`/`bb` or
`u_abuf`/`u_bbuf`). Default channels are 2 μm, halos 1 μm, and core margin 2 μm.
Core sizing satisfies geometry and macro footprint plus local standard-cell
area / 50%. Native placement snaps macro positions to routing tracks.

## Timing search and reports

PVT is fixed to ASAP7 BC/RVT. Each task starts at 1000 ps. Data I/O maximum
delays are 20% of the target; minimum delays are zero. Reset is held inactive.
The driver/load match ASAP7's RVT ABC defaults (BUFx2, 3.898 fF).
Reset exclusion uses Tcl list operations supported by OpenSTA, without requiring
vendor-specific collection commands.

Each search candidate runs synthesis through detailed routing, extraction and
final STA, with its own directory. The effective minimum period is the greater
of the final STA result and the published operating periods of its children.
The latter prevents internal paths hidden by abstract models from being ignored.

When `1.0 <= effective_period / target_period <= 1.1`, search converges. Otherwise
the next target is `effective_period / 1.05`, rounded to 0.1 ps. The default limit
is 12 attempts. Invalid metrics, stagnation and exhaustion are explicit failures.

A convergence point can violate setup. Therefore publication requires another
complete flow at 2% above the effective period, with up to three publication
attempts. Publication requires nonnegative setup/hold slack, zero setup/hold TNS,
zero detailed-route DRC, no unrouted nets, and a period not faster than any child.
Every attempt exports `HOLD_SLACK_MARGIN` to ORFS for CTS/global-route timing
repair. JSON `hold_slack_margin_ps` defaults to 5 ps (0 disables the extra
margin); `hold_retry_margin_step_ps` defaults to 5 ps and must be positive.
If final extracted timing still fails hold, the next full publication attempt
increases the repair margin by the greater of this step and the worst hold
shortfall. Hold-only failures keep the target period unchanged; setup failures
or a child period limit also relax the period. This adds buffer repair margin
before detailed routing, whose parasitics can otherwise reintroduce small hold
violations. Each retry reruns the complete implementation and extracted checks;
remaining hold failures are reported as failures after the configured attempt
limit. Negative slack is never rounded away or accepted.

The effective hold repair margin is saved in each attempt's configuration,
SQLite record, metrics and reports. Restart reconstructs the same per-attempt
margin before reusing stage checkpoints. A completed attempt means its flow
finished; the separate `timing_pass` field records whether timing passed.
The default 5 ps margin is a starting policy, not a guarantee of closure for
every module. These script/config changes invalidate existing fingerprints;
old records and published directories are retained, and the next execution
rebuilds the tasks under the corrected policy. To execute the retry:

```bash
python3 tools/run_hierarchical_openroad.py --retry-failed -j 2
```

Electrical violations are reported separately; this is not foundry signoff.
The estimated limit is specific to the chosen implementation, children, PVT and
I/O budget, not a proof of a globally optimal frequency.

After real execution, `reports/` contains per-node JSON/Markdown and a
`summary.json`, `summary.csv` and `summary.md`. The primary requested results are
the three PEs, three SAs and six Tops; SRAM reports are also retained. Reports
distinguish the convergence point, the published implementation's estimated
frequency and the actually verified operating frequency. All area/timing values
in a published row come from the same attempt.

Area fields distinguish local standard cells, direct macro footprints, core/die
area and recursively counted standard cells. Recursive area adds each immediate
child's recursive cell area times its instance count, so nested macro whitespace
is not mistaken for cell area and descendants are not counted twice.

## Errors and restart

SQLite uses WAL, synchronous FULL and transactional state changes. Stages are
committed only after successful exit and artifact validation. Restart hashes
completed artifacts before reuse. A changed RTL/config/tool/flow/child view
invalidates the affected node and its parents. A new frequency has independent
checkpoints; an interrupted frequency resumes at its first unverified stage.
Each task also has an independent, transactionally saved `progress` cursor in
SQLite. It records search/publication mode, iteration, target period, hold repair
margin, current stage and the converged search metrics needed for publication.
The next chosen constraint is saved before it starts, and the stage is saved
before execution. Restart goes directly to this cursor, without replaying prior
frequency points. Verified stages at the current point are checked and reused;
an interrupted backend stage itself restarts rather than resuming inside the EDA
process. Both workers keep their own cursors, including after Ctrl+C or SIGKILL.

`--status` shows each saved point, for example
`checkpoint search iteration= 2 period_ps= 857.1 phase= route hold_margin_ps= 5.0`.
Per-task JSON reports include the same `progress` field. Legacy records without
a cursor are reconstructed from their matching attempt records and metrics,
without executing the earlier frequency points. Input, script or child-view
fingerprint changes still invalidate affected checkpoints as described above;
the direct-resume behavior applies when fingerprints match. Existing run records
are retained even when a new fingerprint requires rebuilding.

Partial stage files are removed before invoking Make so timestamps cannot make
incomplete outputs appear successful. Verified earlier outputs are passed to
Make as `--assume-old` targets.

Published versions are checksum-verified directories. Publication is staged,
fsynced and renamed before the state points to it. Recovery handles interruption
before or after rename without duplicate publication. A damaged publication cache
is quarantined and reconstructed from verified stage outputs. Input stages are
rerun if their own checkpoints are damaged.

An inherited process lock prevents duplicate runs even if the coordinator dies
while Make remains alive. A conflicting restart returns a busy error; use
`--status` to inspect recorded backend PIDs/logs. Once old backends have exited,
the same command resumes. Ctrl+C stops scheduling, terminates backend process
groups, and preserves committed checkpoints. `stage_timeout_seconds=0` means no
automatic wall-clock timeout; a positive value enables one.

Failures include task, frequency, stage, command, exit code (when available) and
log location. Dependents are blocked while independent branches continue. A run
with any failed/blocked task returns nonzero. Interrupted tasks resume by default;
failed/blocked tasks require `--retry-failed`.

## Acceptance tests: no real backend

```bash
python3 -m unittest discover -s tools -p 'test_hierarchical_openroad.py' -v
```

Tests use separate `SIMULATED-*` workspaces and a synthetic subprocess backend.
They exercise real process groups, inherited locks, SQLite, checksums and
SIGKILL at stage-write/commit and publication boundaries, not just in-memory
exceptions. They also check configurable concurrency, starting a ready parent
while an unrelated SRAM is still running, and checkpoint reuse after changing
the worker count. Test artifacts and reports are explicitly marked synthetic and cannot
be mixed with a native workspace. No real macro performance results are provided
by these tests. A real physical end-to-end integration run remains to be performed
when the user chooses to launch the real command.

Regression coverage also executes reset filtering in Tcl, checks the generated
hold margin against the local ORFS timing helper when available, and simulates
hold-only repair, combined setup/hold failures, exhausted retries and restart
during an attempt with an increased hold margin. Full tests remain synthetic;
loading a generated SDC into the local OpenROAD is a separate integration check.
Reset-filter execution covers all 18 real manifest tasks. Increased-margin input
generation is checked for SRAM, PE, SA and Top, so the repair policy is not
restricted to the first failing SRAM or PE.
