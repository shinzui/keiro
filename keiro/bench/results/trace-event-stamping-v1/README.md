# Event creation context comparison

EP-2 compares the accepted `ac14f8de` runtime in a detached worktree against the event-stamping
implementation. Apply `measurement-harness.patch` to that worktree to give both variants the
same additional 100-event batch pair. Resolved dependency versions were compared and identical;
`source.json` records source/binary identity. Machine, compiler and database settings are those
of the adjacent EP-1 reference. Historical baselines and ceilings are unchanged.

Build both benchmark binaries inside the Nix shell, then run them serially while no compiler or
test suite is active. Arguments are `-p tracing -j1 --time-mode wall --stdev 5 --timeout 10s
--csv <absolute-output> +RTS -N2 -T -RTS`. The candidate additionally uses `--baseline <before.csv>
--fail-if-slower 25`. Tasty's native allocation columns report bytes per workload. Commands
append 100 events per invocation (100 commands to distinct streams, 100 commands to one fresh
stream, or one command emitting 100 events). Dispatch handles 100 inputs, each running a silent
manager command and one eventful target command. Publishing resets, enqueues and drains 2,000
rows. The new batch case uses the existing historical `commandBudget EmitLarge`: at most 10,000
calls / 1,000,000 events. Actual counts passed separately with `KEIRO_BENCH_WORK_COUNTS=1`.

The first batch control refused a too-small 1,000-call budget before sampling stabilized;
`before-growth-refused.*` preserves it. The corrected control passed all ten cells. The first
candidate comparison had one 27% traced-dispatch sample; three alternating isolated pairs
(`-p '/tracing/&&/dispatch/'`) ranged from −3.4% to +1.5%. With unchanged source the full rerun
passed all ten cells against the same ceiling. No observation was discarded or threshold moved.

A subsequent actual-domain ownership probe found that SDK attributes can retain lazy outcome
projections and therefore a large typed no-op reason. `outcome-ownership-before.log` fails the
collection assertion while eight uninspected spans remain alive; `outcome-ownership-after.log`
passes after forcing bounded scalar projections. Error text is materialized from a bounded
string prefix. The original complete core run passed 804 examples and retention passed 22;
final focused checks after this fix passed 51 command examples and six ownership/traced-worker
examples. Unaffected checks reuse that full evidence under the Master's cadence.

The final command/dispatch binary passed all eight affected cells (`after-final-commands.*`).
Publisher code was unaffected by the scalar fix and reuses the passing full comparison.
`comparison.md` combines those applicable rows and identifies this split explicitly here.
No-tracer allocation estimates fluctuate within measurement/background activity. Added traced
allocation is bounded context formatting, metadata construction/serialization and parsing of
stored metadata during existing history reads. The one-stream workload reads its accumulating
history, explaining its larger allocation delta; no new history scan or per-retry capture was
introduced. The batch amortizes one capture across 100 events. Retained-span probes establish
ownership independently of these allocation estimates.

The new ADR, capability, research and operations documentation passed strict validation;
extension and umbrella re-export policies passed. The final complete repository gate remains
at initiative integration; EP-1 retains the unchanged-check baseline.
