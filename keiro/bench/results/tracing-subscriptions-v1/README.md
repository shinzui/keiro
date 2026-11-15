# Subscription processing comparison

The control is accepted `3dfd6831` in a detached worktree with
`measurement-harness.patch` applied. Both binaries use identical benchmark source
and resolved dependency versions. Source/binary hashes are in `source.json`;
machine/compiler/database settings reuse the adjacent EP-1 environment reference.

Each invocation handles 100 inputs as 100 one-delivery worker drains, each running
one silent manager command and one eventful target command. Historical cells remain
unchanged. The additional adjacent pair supplies valid creation headers under
LinkOnly; the old worker ignores them. Budgets, history policy and actual work-count
checks are unchanged. Results include per-worker startup, so the name/policy setup
cost is not amortized over a long-lived worker in this workload.

Build inside Nix, then run serially without a compiler or suite active. Options:
`-p "/tracing/&&/process-manager/" -j1 --time-mode wall --stdev 5 --timeout 10s
--csv <absolute-output> +RTS -N2 -T -RTS`; the candidate adds
`--baseline <absolute-before.csv> --fail-if-slower 25`.

The first candidate run had a 44% untraced dispatch timing outlier while the contextual
untraced case was 4.8% faster. The unchanged binary's focused dispatch rerun passes
against the original baseline and unchanged 25% ceiling (31.69 ms vs 32.14 ms).
`comparison.md` uses that rerun for this one cell and the original passing rows for
all others. Both observations remain retained. A substring pattern mistaken for a
regular expression selected zero tests; its header-only output is retained as
`dispatch-pattern-no-match.*` and is never accepted as measurement evidence.
The accepted focused invocation uses the binary directly inside Nix with
`-p '$0=="All.tracing.process-manager.dispatch"'` and otherwise identical options.

No-tracer allocation estimates differ by −0.03% to +0.15%; the original handler is
selected once per worker without decoding envelope telemetry. Traced allocation adds
about 6.8 KB per input without creation headers and 8.7 KB with them: one processing
span, common/outcome attributes, context scope and one decoded link when present.
Command/event/query counts are unchanged. Accepted timing deltas are −4.8% to +16.0%.

Nine focused integration examples cover every worker kind, duplicate/poison/missing
context, source policy and the real Kiroku command/event/manager/command/event chain.
Existing PM (47), router (24), telemetry (14) and public consumer-link (1) checks pass.
The seven finite ownership probes and both affected retention legs pass (nine cases):
actual subscription helpers release large envelopes and lazy adapter scalar projections
while uninspected exported spans remain alive under both policies. The contextual
tracer leg ends Bounded at 1,056 B/op and 0.99 MiB growth; the unchanged untraced leg
is 1,116 B/op and 1.04 MiB. Unaffected legs reuse EP-5 evidence under the Master's cadence.
Strict affected docs, extension and re-export checks pass; the full integrated gate
remains at initiative completion.
