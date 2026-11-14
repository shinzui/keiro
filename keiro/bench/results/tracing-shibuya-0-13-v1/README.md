# Shibuya dependency migration comparison

The unchanged-runtime control is `f3048422` in a detached worktree; the candidate
adopts the three released Shibuya packages and the shared PGMQ process helper.
No benchmark logic changes: in-memory adapter records gain explicit telemetry defaults.
Both variants solve http2 5.4.14 (the control uses `--constraint='http2==5.4.14'`),
isolating the three intended dependency changes listed in `source.json`. All other
resolved versions match. Hackage index refresh was needed to discover adapter 0.19.
Machine, compiler and database settings reuse the adjacent EP-1 environment reference.

Run inside the Nix shell with `cabal bench keiro-bench`, options `-p tracing -j1
--time-mode wall --stdev 5 --timeout 10s --csv <absolute-output> +RTS -N2 -T -RTS`.
The candidate adds `--baseline <absolute-before.csv> --fail-if-slower 25`.
Runs were serial, without a compiler or test suite active during measurement.
All 12 fixed-workload cells pass; full comparison times are −10.6% to +6.4%.
Historical workloads, budgets, work counts and ceilings remain unchanged.

The full comparison's no-tracer history allocation moved 0.84%. An isolated pair
(`-p /append-one-stream/`, retained as `history-*.csv/log`) measured +8,070 B / 86.9 MB
(+0.009%); traced history measured −9,400 B. The original full observations remain
in `comparison.md`; no ceiling or accepted timing row was replaced. Core command and
publisher code has no new Shibuya runtime call. Native process-wide RTS estimates
include asynchronous store activity. Other no-tracer differences are below 0.23%;
adapter construction alone gains its explicit shared telemetry field.

`cabal build all --enable-tests --enable-benchmarks` passes. All affected consumer
coverage passes, including 898 DSL examples, all conformance consumers, 83 PGMQ
examples (the same two pre-existing pending provisioning cases), and 25 retention/
ownership examples. Actual decoded job payloads collect while exported spans remain
alive on both execution paths under both policies. Delayed/retried LinkOnly deliveries
are distinct linked roots. Context-publisher and PM retention legs finish Bounded
at 159 and 393 B/op respectively. These core benchmark workloads measure the
repository dependency migration; no standalone job timing or zero-overhead claim is made.

The parallel all-suite run has one core failure among 811 examples: the existing
100 ms cutover fault-injection deadline races PostgreSQL statement cancellation.
The unchanged example passes immediately in isolation (1.19 s). Both logs are
retained, assertions are unchanged, and the final sequential integrated repository
gate remains required. Strict affected docs, extension and re-export checks pass.
