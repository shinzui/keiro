# Outbox creation context comparison

The control is the accepted `6c1b59ed` runtime in a detached worktree. Apply
`control-harness.patch` there; it adds the same workload labels, source metadata and
context-bearing publisher rows. Its local policy type only labels old draft-only
enqueues: no new runtime policy exists in the control. The candidate implements the
policy. `candidate-harness.patch` retains its harness additions. Dependency versions
match; source and final binary hashes are in `source.json`. Machine/toolchain/database
settings reuse the adjacent EP-1 reference.

Build with `nix develop -c cabal build keiro:bench:keiro-bench`, then run serially with
no compiler or suite active. Benchmark options are `-p "/publish-backlog/||/publish-contexts/||/trace-policy/"
-j1 --time-mode wall --stdev 5 --timeout 10s --csv <absolute-output> +RTS -N2 -T -RTS`.
The candidate adds `--baseline <absolute-before.csv> --fail-if-slower 25`.
Publishing resets, enqueues and drains 2,000 rows, with or without distinct stored
creation contexts; SQL policy cases reset and assert 1,000 fresh inserts per invocation.
All historical cells and ceilings remain intact.

The initial eight-cell candidate passed timing but revealed bypass allocation from
lost enqueue specialization. An INLINE boundary plus shared producer configuration
removed that regression. `after-policy-specialized.*` refreshes the four affected
policy cells at the same ceiling; publisher code is unchanged and reuses `after.*`.
`comparison.md` combines those accepted rows. Exploratory allocation rows are retained.

No-tracer publisher allocation varies by less than 0.08%; legacy enqueue allocates
less than the old implementation. Pre-cutover and explicit cases add about 225 B per
row for policy comparison/wrapping while bypassing metadata. Eligible derivation adds
about 6.7 KB per row relative to the candidate legacy policy, covering lookup plus new
trace fields through normalization, SQL parameters and serialization. Traced context
publishing adds about 1.24 KB per row versus the old no-link send path, including W3C
decoding and link maps; link retention is bounded to 128 per batch.

Focused outbox (66) and telemetry (13) examples pass. All 25 retention/ownership
examples pass; the new traced context leg ends Bounded at 222 B/op and 0.21 MiB growth.
The actual mixed 200-row link builder releases payloads while uninspected exported
spans remain alive. The final identity suite rechecks cutover behavior after inlining.
The filled DSL producer consumer compiles/runs against the new required record field.
Strict affected documentation, extension and re-export checks pass. Full repository
verification remains the final integrated initiative gate under the accepted cadence.
